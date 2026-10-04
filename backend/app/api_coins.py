"""Confirmation service + coins API (PRD 8.6)."""
import base64
import hashlib
import hmac
import json
import uuid
from datetime import timedelta

from fastapi import APIRouter, Depends, Header, HTTPException, Request, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from . import analytics, clock, coin_config, db, domain, events, experiment, goals, ledger, notify, redemption, views
from .deps import current_user, require_member
from .settings import settings

router = APIRouter(prefix="/api/v1")

REASON_TEXT = {
    "EXPENSE_ADDER": "{desc}, confirmed by {who}",
    "EXPENSE_CONFIRMER": "Confirmed {desc} for {who}",
    "FIRST_WIN": "First confirmed expense bonus",
    "SETTLE_PAYER": "Paid {who}",
    "SETTLE_QUICK_BONUS": "Quick settle bonus",
    "SETTLE_RECEIVER": "Confirmed payment from {who}",
    "SURPRISE_BONUS": "Surprise {mult}x bonus",
    "INVITE": "Invite bonus with {who}",
    "HOUSEHOLD_GOAL": "Weekly goal met",
    "REDEMPTION": "Redeemed {brand} INR {face} voucher",
    "REDEMPTION_REFUND": "Refund: voucher didn't go through",
    "EXPIRED": "Coins expired",
}
REVERSAL_WHY = {"edited": "{desc} was edited", "deleted": "{desc} was deleted", "disputed": "{desc} was marked not right",
                "ops": "Corrected by support"}


def _cfg_guard(conn):
    cfg = coin_config.current(conn)
    if not cfg["enabled"] or cfg["kill_switch"]:
        raise HTTPException(503, "Coins unavailable right now")
    return cfg


# ---------------------------------------------------------------- expense confirmation (FR-2)

class ConfirmIn(BaseModel):
    status: str
    reason: str | None = None
    note: str | None = Field(default=None, max_length=200)
    source: str | None = None  # push, inbox, detail (analytics only)


@router.post("/expenses/{expense_id}/confirmations")
def confirm_expense(expense_id: int, body: ConfirmIn, user=Depends(current_user),
                    idempotency_key: str | None = Header(default=None)):
    if body.status not in ("CONFIRMED", "DISPUTED"):
        raise HTTPException(400, "status must be CONFIRMED or DISPUTED")
    if body.status == "DISPUTED" and body.reason not in ("WRONG_AMOUNT", "NOT_MINE", "OTHER"):
        raise HTTPException(400, "Pick a reason")
    with db.tx() as conn:
        e = domain.load_expense(conn, expense_id, lock=True)
        if not e or e["deleted_at"]:
            raise HTTPException(404, "Expense not found")
        require_member(conn, e["group_id"], user["id"])
        cfg = coin_config.current(conn)
        if not views.eligible(conn, e["group_id"], cfg):
            raise HTTPException(409, "Confirmation isn't available for this group")
        if user["id"] == e["created_by"]:
            raise HTTPException(403, "You added this expense, so someone else needs to confirm it")  # AB-1
        if user["id"] not in domain.participants(e):
            raise HTTPException(403, "Only people in this expense can confirm it")
        preview = views.safe(conn, views.reward_preview, conn, user["id"], e, cfg) if body.status == "CONFIRMED" else None
        existing = conn.execute(
            "SELECT * FROM expense_confirmations WHERE expense_id=%s AND expense_version=%s AND user_id=%s",
            (expense_id, e["version"], user["id"])).fetchone()
        if existing is None:
            conn.execute(
                """INSERT INTO expense_confirmations (expense_id, expense_version, user_id, status, dispute_reason, note, created_at)
                   VALUES (%s,%s,%s,%s,%s,%s,%s)""",
                (expense_id, e["version"], user["id"], body.status, body.reason, body.note, clock.now()))
            ev = "ExpenseConfirmed" if body.status == "CONFIRMED" else "ExpenseDisputed"
            events.emit(conn, ev, expense_id=expense_id, group_id=e["group_id"], version=e["version"], user_id=user["id"])
            arm = experiment.arm_of(conn, e["group_id"], cfg)
            analytics.track(conn, "expense_confirmed" if body.status == "CONFIRMED" else "expense_disputed",
                            user_id=user["id"], group_id=e["group_id"], arm=arm, config_version=cfg.version,
                            expense_id=expense_id, source=body.source or "detail", reason=body.reason,
                            seconds_since_created=int((clock.now() - e["created_at"]).total_seconds()))
        names = domain.user_names(conn, [e["paid_by"], e["created_by"]] + [s["user_id"] for s in e["splits"]])
        out = views.expense_json(conn, user["id"], e, names, cfg, True)
        out["reward_preview"] = preview if existing is None else None
        out["already_responded"] = existing is not None
        return out


@router.post("/expenses/{expense_id}/remind")
def remind(expense_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        e = domain.load_expense(conn, expense_id)
        if not e or e["deleted_at"]:
            raise HTTPException(404, "Expense not found")
        require_member(conn, e["group_id"], user["id"])
        cfg = _cfg_guard(conn)
        if user["id"] != e["created_by"]:
            raise HTTPException(403, "Only the person who added this can send a reminder")
        st = domain.expense_state(conn, e, cfg)
        cutoff = clock.now() - timedelta(hours=cfg["push"]["remind_cooldown_hours"])
        reminded = []
        shares = {s["user_id"]: s["share_paise"] for s in e["splits"]}
        for u in st["waiting_on"]:
            last = conn.execute("SELECT max(reminded_at) t FROM expense_reminders WHERE expense_id=%s AND user_id=%s",
                                (expense_id, u)).fetchone()["t"]
            if last and last >= cutoff:
                continue
            conn.execute("INSERT INTO expense_reminders (expense_id, user_id, reminded_at) VALUES (%s,%s,%s)",
                         (expense_id, u, clock.now()))
            notify.enqueue(conn, cfg, user_id=u, nid="N1", group_id=e["group_id"], title="Looks right?",
                           body=f"{user['name']} added {e['description']} {domain.inr(e['amount_paise'])}. "
                                f"Your share {domain.inr(shares.get(u, 0))}. Looks right?",
                           dedupe_key=f"N1-remind:{expense_id}:{e['version']}:{u}:{clock.now().date()}",
                           payload={"expense_id": expense_id, "version": e["version"], "group_id": e["group_id"]})
            reminded.append(u)
        analytics.track(conn, "remind_tapped", user_id=user["id"], group_id=e["group_id"],
                        arm=experiment.arm_of(conn, e["group_id"], cfg), config_version=cfg.version,
                        expense_id=expense_id)
        names = domain.user_names(conn, reminded)
        return {"reminded": [{"user_id": u, "name": names.get(u)} for u in reminded]}


# ---------------------------------------------------------------- payment confirmation (FR-4)

class PaymentConfirmIn(BaseModel):
    status: str
    note: str | None = Field(default=None, max_length=200)


@router.post("/payments/{payment_id}/confirmation")
def confirm_payment(payment_id: int, body: PaymentConfirmIn, user=Depends(current_user)):
    if body.status not in ("CONFIRMED", "REJECTED"):
        raise HTTPException(400, "status must be CONFIRMED or REJECTED")
    with db.tx() as conn:
        p = conn.execute("SELECT * FROM payments WHERE id=%s", (payment_id,)).fetchone()
        if not p or p["deleted_at"]:
            raise HTTPException(404, "Payment not found")
        if p["receiver_id"] != user["id"]:
            raise HTTPException(403, "Only the person who received the money can confirm")
        pc = conn.execute("SELECT * FROM payment_confirmations WHERE payment_id=%s FOR UPDATE", (payment_id,)).fetchone()
        cfg = coin_config.current(conn)
        if pc["status"] == "PENDING" and pc["expires_at"] <= clock.now():
            conn.execute("UPDATE payment_confirmations SET status='UNVERIFIED' WHERE payment_id=%s", (payment_id,))
            pc["status"] = "UNVERIFIED"
        if pc["status"] != "PENDING":
            if pc["status"] == body.status:
                names = domain.user_names(conn, [p["payer_id"], p["receiver_id"]])
                return views.payment_json(conn, user["id"], p, names, views.eligible(conn, p["group_id"], cfg))
            raise HTTPException(409, f"This payment is already {pc['status'].lower()}")
        conn.execute("UPDATE payment_confirmations SET status=%s, confirmed_by=%s, confirmed_at=%s, note=%s WHERE payment_id=%s",
                     (body.status, user["id"], clock.now(), body.note, payment_id))
        events.emit(conn, "PaymentConfirmed" if body.status == "CONFIRMED" else "PaymentRejected",
                    payment_id=payment_id, group_id=p["group_id"], version=1)
        eligible = views.eligible(conn, p["group_id"], cfg)
        if eligible:
            start = domain.debt_age_start(conn, p["group_id"], p["payer_id"], p["receiver_id"], p)
            analytics.track(conn, "payment_receipt_confirmed" if body.status == "CONFIRMED" else "payment_receipt_rejected",
                            user_id=user["id"], group_id=p["group_id"], arm=experiment.arm_of(conn, p["group_id"], cfg),
                            config_version=cfg.version, payment_id=payment_id,
                            debt_age_hours=round((p["created_at"] - start).total_seconds() / 3600, 1) if start else None)
        names = domain.user_names(conn, [p["payer_id"], p["receiver_id"]])
        return views.payment_json(conn, user["id"], p, names, eligible)


# ---------------------------------------------------------------- wallet & ledger (FR-6)

@router.get("/coins/wallet")
def wallet(user=Depends(current_user)):
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        w = ledger.get_wallet(conn, "USER", user["id"])
        soon = clock.now() + timedelta(days=cfg["expiry_push_days"])
        exp = conn.execute(
            """SELECT COALESCE(SUM(remaining),0) s, MIN(expires_at) t FROM coin_lots
               WHERE wallet_id=%s AND remaining > 0 AND expires_at <= %s""", (w["id"], soon)).fetchone()
        pending = conn.execute(
            "SELECT COALESCE(SUM(amount),0) s FROM coin_ledger WHERE wallet_id=%s AND status='PENDING'", (w["id"],)).fetchone()["s"]
        groups = conn.execute(
            """SELECT g.* FROM groups g JOIN group_members m ON m.group_id=g.id
               WHERE m.user_id=%s AND m.left_at IS NULL""", (user["id"],)).fetchall()
        pots = []
        for g in groups:
            if views.eligible(conn, g["id"], cfg):
                pw = ledger.get_wallet(conn, "GROUP", g["id"])
                pots.append({"group_id": g["id"], "group_name": domain.display_name(conn, g, user["id"]), "coins": pw["balance_cached"]})
        notice = _latest_notice(conn, user["id"])
        bal = max(w["balance_cached"], 0)
        return {
            "balance": bal, "inr_value": round(bal * cfg["coin_value_inr"], 2),
            "coins_per_inr": round(1 / cfg["coin_value_inr"]),
            "expiring_soon": {"coins": int(exp["s"]), "date": exp["t"].isoformat() if exp["t"] else None},
            "pending": int(pending), "deficit": w["deficit"], "redemption_frozen": w["redemption_frozen"],
            "household_pots": pots, "cap_notice": notice, "config_version": cfg.version,
        }


def _latest_notice(conn, user_id):
    start, end = clock.ist_day_bounds()
    n = conn.execute("SELECT cap_key FROM reward_notices WHERE user_id=%s AND created_at >= %s ORDER BY created_at DESC LIMIT 1",
                     (user_id, start)).fetchone()
    if not n:
        return None
    month = "monthly" in n["cap_key"]
    return {"cap_key": n["cap_key"],
            "message": "Monthly coin limit reached, back next month" if month else "Daily coin limit reached, back tomorrow"}


@router.get("/coins/ledger")
def ledger_history(cursor: str | None = None, limit: int = 30, group_id: int | None = None, user=Depends(current_user)):
    limit = max(1, min(limit, 100))
    with db.tx() as conn:
        if group_id:
            require_member(conn, group_id, user["id"])
            w = ledger.get_wallet(conn, "GROUP", group_id)
        else:
            w = ledger.get_wallet(conn, "USER", user["id"])
        args = [w["id"]]
        q = "SELECT * FROM coin_ledger WHERE wallet_id=%s"
        if cursor:
            ts, eid = base64.urlsafe_b64decode(cursor.encode()).decode().split("|")
            q += " AND (created_at, id::text) < (%s::timestamptz, %s)"
            args += [ts, eid]
        q += " ORDER BY created_at DESC, id::text DESC LIMIT %s"
        args.append(limit + 1)
        rows = conn.execute(q, args).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        return {"entries": [describe_entry(conn, r) for r in rows],
                "next_cursor": base64.urlsafe_b64encode(f"{rows[-1]['created_at'].isoformat()}|{rows[-1]['id']}".encode()).decode()
                if more else None}


def describe_entry(conn, r) -> dict:
    """Plain-language reason with the roommate involved (FR-6)."""
    who = domain.user_names(conn, [r["counterparty_user_id"]]).get(r["counterparty_user_id"], "someone in the group")
    desc = "An expense"
    if r["source_type"] == "EXPENSE":
        e = conn.execute("SELECT description FROM expenses WHERE id=%s", (int(r["source_id"]),)).fetchone()
        desc = e["description"] if e else desc
    brand, face = "", ""
    if r["source_type"] == "REDEMPTION":
        it = conn.execute("""SELECT c.brand, c.face_value_inr FROM redemptions x JOIN catalog_items c ON c.id=x.catalog_item_id
                             WHERE x.id=%s""", (r["source_id"],)).fetchone()
        if it:
            brand, face = it["brand"], it["face_value_inr"]
    code = r["reason_code"]
    meta = r["metadata"] or {}
    if r["entry_type"] == "REVERSAL":
        why = REVERSAL_WHY.get(meta.get("why"), "Correction").format(desc=desc)
        text = f"Reversed: {why}"
    else:
        text = REASON_TEXT.get(code, code.replace("_", " ").title()).format(
            desc=desc, who=who, mult=meta.get("multiplier", ""), brand=brand, face=face)
    return {"id": str(r["id"]), "amount": r["amount"], "entry_type": r["entry_type"], "status": r["status"],
            "reason_code": code, "text": text, "counterparty": who if r["counterparty_user_id"] else None,
            "reverses_entry_id": str(r["reverses_entry_id"]) if r["reverses_entry_id"] else None,
            "created_at": r["created_at"].isoformat()}


@router.get("/coins/celebrations")
def celebrations(user=Depends(current_user)):
    with db.tx() as conn:
        rows = conn.execute("SELECT * FROM celebrations WHERE user_id=%s AND seen_at IS NULL ORDER BY created_at",
                            (user["id"],)).fetchall()
        return {"celebrations": [{"id": str(r["id"]), "kind": r["kind"], "coins": r["coins"], "title": r["title"],
                                  "bonus_multiplier": r["bonus_multiplier"], "bonus_coins": r["bonus_coins"]} for r in rows]}


@router.post("/coins/celebrations/{cid}/seen")
def celebration_seen(cid: str, user=Depends(current_user)):
    with db.tx() as conn:
        conn.execute("UPDATE celebrations SET seen_at=%s WHERE id=%s AND user_id=%s", (clock.now(), cid, user["id"]))
    return {"ok": True}


# ---------------------------------------------------------------- household (FR-7)

@router.get("/groups/{group_id}/household")
def household(group_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        require_member(conn, group_id, user["id"])
        cfg = coin_config.current(conn)
        if not views.eligible(conn, group_id, cfg):
            raise HTTPException(404, "No household card for this group")
        out = goals.summary(conn, group_id, user["id"], cfg)
        out["invite_suggested"] = bool(out["expected_members"] and len(out["members"]) < out["expected_members"])
        return out


# ---------------------------------------------------------------- catalogue & redemption (FR-8)

@router.get("/coins/catalog")
def catalog(scope: str | None = None, group_id: int | None = None, user=Depends(current_user)):
    with db.tx() as conn:
        cfg = _cfg_guard(conn)
        w = ledger.get_wallet(conn, "USER", user["id"])
        pot = None
        if group_id:
            require_member(conn, group_id, user["id"])
            if views.eligible(conn, group_id, cfg):
                pot = ledger.get_wallet(conn, "GROUP", group_id)
        q = "SELECT * FROM catalog_items WHERE active"
        args = []
        if scope in ("USER", "GROUP"):
            q += " AND scope=%s"
            args.append(scope)
        items = conn.execute(q + " ORDER BY scope DESC, coin_cost", args).fetchall()
        out = []
        for it in items:
            bal = w["balance_cached"] if it["scope"] == "USER" else (pot["balance_cached"] if pot else 0)
            out.append({"id": str(it["id"]), "scope": it["scope"], "brand": it["brand"], "category": it["category"],
                        "face_value_inr": it["face_value_inr"], "coin_cost": it["coin_cost"],
                        "affordable": bal >= it["coin_cost"], "coins_needed": max(0, it["coin_cost"] - bal)})
        return {"items": out, "balance": max(w["balance_cached"], 0), "pot_balance": pot["balance_cached"] if pot else None,
                "redemption_enabled": bool(cfg["redemption"].get("enabled"))}


class RedeemIn(BaseModel):
    catalog_item_id: str
    group_id: int | None = None


@router.post("/coins/redemptions")
def redeem(body: RedeemIn, user=Depends(current_user), idempotency_key: str | None = Header(default=None)):
    if not idempotency_key:
        raise HTTPException(400, "Idempotency-Key header required")
    try:
        red = redemption.start(user["id"], body.catalog_item_id, body.group_id, idempotency_key)
    except redemption.RedeemError as e:
        raise HTTPException(e.status, {"code": e.code, "message": e.message})
    if red["status"] == "REQUESTED":
        red = redemption.fulfil(red["id"])
    return _redemption_json(red, user["id"])


def _redemption_json(r, viewer_id) -> dict:
    with db.tx() as conn:
        it = conn.execute("SELECT * FROM catalog_items WHERE id=%s", (r["catalog_item_id"],)).fetchone()
    code = None
    if r["status"] == "FULFILLED" and r["code_encrypted"] and r["redeemed_by"] == viewer_id:
        code = redemption.decrypt_code(r["code_encrypted"])  # decrypted only for the redeemer
    return {"id": str(r["id"]), "status": r["status"], "coins": r["coins"], "brand": it["brand"],
            "face_value_inr": it["face_value_inr"], "scope": it["scope"], "group_id": r["group_id"], "code": code,
            "failure_code": r["failure_code"], "created_at": r["created_at"].isoformat()}


@router.get("/coins/redemptions")
def my_redemptions(user=Depends(current_user)):
    with db.tx() as conn:
        rows = conn.execute("SELECT * FROM redemptions WHERE redeemed_by=%s ORDER BY created_at DESC LIMIT 50",
                            (user["id"],)).fetchall()
    return {"redemptions": [_redemption_json(r, user["id"]) for r in rows]}


# ---------------------------------------------------------------- invites (FR-10)

def _sign(data: str) -> str:
    return hmac.new(settings.invite_secret.encode(), data.encode(), hashlib.sha256).hexdigest()[:24]


def make_token(referral_id: str, group_id: int, inviter_id: int) -> str:
    data = f"{referral_id}.{group_id}.{inviter_id}"
    return base64.urlsafe_b64encode(f"{data}.{_sign(data)}".encode()).decode().rstrip("=")


def read_token(token: str) -> tuple[str, int, int]:
    try:
        raw = base64.urlsafe_b64decode((token + "=" * (-len(token) % 4)).encode()).decode()
        rid, gid, inviter, sig = raw.split(".")
    except Exception:
        raise HTTPException(400, "This invite link isn't valid")
    if not hmac.compare_digest(sig, _sign(f"{rid}.{gid}.{inviter}")):
        raise HTTPException(400, "This invite link isn't valid")
    return rid, int(gid), int(inviter)


class InviteIn(BaseModel):
    group_id: int


@router.post("/invites")
def create_invite(body: InviteIn, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, body.group_id, user["id"])
        cfg = coin_config.current(conn)
        rid = str(uuid.uuid4())
        conn.execute("INSERT INTO referrals (id, inviter_id, group_id, status, created_at) VALUES (%s,%s,%s,'INVITED',%s)",
                     (rid, user["id"], body.group_id, clock.now()))
        token = make_token(rid, body.group_id, user["id"])
        link = f"{settings.public_base_url}/j/{token}"
        eligible = views.eligible(conn, body.group_id, cfg)
        if eligible:
            msg = (f"I'm splitting expenses on Squared. Join {_invite_target(g)} so we both earn coins for keeping things square: {link}")
            analytics.track(conn, "invite_shared", user_id=user["id"], group_id=body.group_id,
                            arm=experiment.arm_of(conn, body.group_id, cfg), config_version=cfg.version, channel="whatsapp")
        else:
            msg = f"I'm splitting expenses on Squared. Join {_invite_target(g)}: {link}"
        return {"referral_id": rid, "token": token, "link": link, "app_link": f"squared://join?token={token}",
                "message": msg, "whatsapp_url": "whatsapp://send?text=" + _urlencode(msg)}


def _invite_target(g) -> str:
    return "me" if g["group_type"] == "DIRECT" else g["name"]


def _urlencode(s: str) -> str:
    from urllib.parse import quote
    return quote(s, safe="")


@router.get("/invites")
def list_invites(group_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        require_member(conn, group_id, user["id"])
        rows = conn.execute(
            """SELECT * FROM referrals WHERE inviter_id=%s AND group_id=%s AND (invitee_id IS NOT NULL OR created_at > %s)
               ORDER BY created_at DESC""", (user["id"], group_id, clock.now() - timedelta(days=30))).fetchall()
        names = domain.user_names(conn, [r["invitee_id"] for r in rows])
        cfg = coin_config.current(conn)
        label = {"INVITED": "Invited", "JOINED": "Joined", "REWARDED": f"First expense confirmed (+{cfg['earn']['invite_each']} each)"}
        return {"invites": [{"id": str(r["id"]), "status": r["status"], "status_text": label[r["status"]],
                             "invitee_name": names.get(r["invitee_id"]), "created_at": r["created_at"].isoformat()}
                            for r in rows]}


class AcceptIn(BaseModel):
    token: str


@router.post("/invites/accept")
def accept_invite(body: AcceptIn, user=Depends(current_user)):
    rid, gid, inviter = read_token(body.token)
    with db.tx() as conn:
        ref = conn.execute("SELECT * FROM referrals WHERE id=%s FOR UPDATE", (rid,)).fetchone()
        g = conn.execute("SELECT * FROM groups WHERE id=%s", (gid,)).fetchone()
        if not ref or not g or ref["group_id"] != gid:
            raise HTTPException(400, "This invite link isn't valid")
        member = conn.execute("SELECT * FROM group_members WHERE group_id=%s AND user_id=%s", (gid, user["id"])).fetchone()
        if member and member["left_at"] is None:
            return {"group_id": gid, "already_member": True}
        if g["group_type"] == "DIRECT":
            # a friend link pairs exactly two people; reuse an existing pair instead of making a second one
            existing = domain.direct_group(conn, inviter, user["id"])
            if existing and existing["id"] != gid:
                return {"group_id": existing["id"], "already_member": True}
            if len(experiment.active_member_ids(conn, gid)) >= 2:
                raise HTTPException(400, "This friend invite was already used")
        if member:
            conn.execute("UPDATE group_members SET left_at=NULL, joined_at=%s WHERE group_id=%s AND user_id=%s",
                         (clock.now(), gid, user["id"]))
        else:
            conn.execute("INSERT INTO group_members (group_id, user_id, joined_at, referral_id) VALUES (%s,%s,%s,%s)",
                         (gid, user["id"], clock.now(), rid))
        new_invitee = ref["invitee_id"] is None and user["id"] != inviter and not member
        if new_invitee:
            # one link can bring several roommates: the first claims this referral, later ones get their own
            conn.execute("UPDATE referrals SET invitee_id=%s, status='JOINED' WHERE id=%s", (user["id"], rid))
        elif user["id"] != inviter and not member:
            rid = str(uuid.uuid4())
            conn.execute("""INSERT INTO referrals (id, inviter_id, invitee_id, group_id, status, created_at)
                            VALUES (%s,%s,%s,%s,'JOINED',%s)""", (rid, inviter, user["id"], gid, clock.now()))
        events.emit(conn, "MemberJoined", group_id=gid, user_id=user["id"], referral_id=rid if not member else None)
        return {"group_id": gid, "already_member": False, "group_name": domain.display_name(conn, g, user["id"])}


# ---------------------------------------------------------------- inbox & notifications (S4, FR-9)

@router.get("/me/inbox/needs-you")
def needs_you(user=Depends(current_user)):
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        items = []
        try:
            with conn.transaction():
                rows = conn.execute(
                    """SELECT e.id FROM expenses e
                       JOIN group_members m ON m.group_id=e.group_id AND m.user_id=%s AND m.left_at IS NULL
                       WHERE e.deleted_at IS NULL AND e.created_by <> %s AND e.created_at > %s
                         AND (EXISTS (SELECT 1 FROM expense_splits s WHERE s.expense_id=e.id AND s.user_id=%s AND s.share_paise>0)
                              OR e.paid_by=%s)
                         AND NOT EXISTS (SELECT 1 FROM expense_confirmations c WHERE c.expense_id=e.id
                                         AND c.expense_version=e.version AND c.user_id=%s)
                       ORDER BY e.created_at DESC LIMIT 30""",
                    (user["id"], user["id"],
                     clock.now() - timedelta(days=cfg["confirmation"]["expense_unconfirmed_label_after_days"]),
                     user["id"], user["id"], user["id"])).fetchall()
                elig_cache = {}
                for r in rows:
                    e = domain.load_expense(conn, r["id"])
                    if e["group_id"] not in elig_cache:
                        elig_cache[e["group_id"]] = views.eligible(conn, e["group_id"], cfg) and not user["hide_coins"]
                    if not elig_cache[e["group_id"]]:
                        continue
                    names = domain.user_names(conn, [e["paid_by"], e["created_by"]] + [s["user_id"] for s in e["splits"]])
                    g = conn.execute("SELECT * FROM groups WHERE id=%s", (e["group_id"],)).fetchone()
                    items.append({"kind": "EXPENSE", "group_name": domain.display_name(conn, g, user["id"]),
                                  "expense": views.expense_json(conn, user["id"], e, names, cfg, True)})
                pays = conn.execute(
                    """SELECT p.* FROM payments p JOIN payment_confirmations pc ON pc.payment_id=p.id
                       WHERE p.receiver_id=%s AND p.deleted_at IS NULL AND pc.status='PENDING' AND pc.expires_at > %s
                       ORDER BY p.created_at DESC""", (user["id"], clock.now())).fetchall()
                for p in pays:
                    if p["group_id"] not in elig_cache:
                        elig_cache[p["group_id"]] = views.eligible(conn, p["group_id"], cfg) and not user["hide_coins"]
                    if not elig_cache[p["group_id"]]:
                        continue
                    names = domain.user_names(conn, [p["payer_id"], p["receiver_id"]])
                    g = conn.execute("SELECT * FROM groups WHERE id=%s", (p["group_id"],)).fetchone()
                    items.append({"kind": "PAYMENT", "group_name": domain.display_name(conn, g, user["id"]),
                                  "payment": views.payment_json(conn, user["id"], p, names, True),
                                  "receiver_reward": cfg["earn"]["settle_receiver"]})
        except Exception:
            raise HTTPException(503, "Coins unavailable right now")
        return {"items": items}


@router.get("/me/notifications")
def inbox(user=Depends(current_user)):
    with db.tx() as conn:
        rows = conn.execute(
            """SELECT * FROM notifications WHERE user_id=%s AND status IN ('SENT','INBOX_ONLY','QUEUED')
               ORDER BY created_at DESC LIMIT 50""", (user["id"],)).fetchall()
        return {"notifications": [_notif_json(r) for r in rows],
                "unread": sum(1 for r in rows if r["read_at"] is None and r["status"] != "QUEUED")}


def _notif_json(r):
    return {"id": str(r["id"]), "notification_id": r["notification_id"], "title": r["title"], "body": r["body"],
            "payload": r["payload"], "status": r["status"], "read": r["read_at"] is not None,
            "created_at": r["created_at"].isoformat()}


@router.get("/me/notifications/deliver")
def deliver(user=Depends(current_user)):
    """Device pull for SENT pushes not yet shown (local stand-in for APNs)."""
    with db.tx() as conn:
        rows = conn.execute(
            """UPDATE notifications SET delivered_at=%s WHERE id IN (
                 SELECT id FROM notifications WHERE user_id=%s AND status='SENT' AND delivered_at IS NULL
                 ORDER BY sent_at LIMIT 10 FOR UPDATE SKIP LOCKED) RETURNING *""", (clock.now(), user["id"])).fetchall()
        return {"notifications": [_notif_json(r) for r in rows]}


class NotifEvent(BaseModel):
    event: str  # opened, actioned, read


@router.post("/me/notifications/{nid}/event")
def notif_event(nid: str, body: NotifEvent, user=Depends(current_user)):
    col = {"opened": "opened_at", "actioned": "actioned_at", "read": "read_at"}.get(body.event)
    if not col:
        raise HTTPException(400, "Unknown event")
    with db.tx() as conn:
        r = conn.execute(f"UPDATE notifications SET {col}=COALESCE({col}, %s), read_at=COALESCE(read_at, %s) "
                         "WHERE id=%s AND user_id=%s RETURNING *", (clock.now(), clock.now(), nid, user["id"])).fetchone()
        if r and body.event in ("opened", "actioned"):
            cfg = coin_config.current(conn)
            analytics.track(conn, f"push_{body.event}", user_id=user["id"], group_id=r["group_id"],
                            config_version=cfg.version, notification_id=r["notification_id"])
    return {"ok": True}


@router.post("/me/notifications/read-all")
def read_all(user=Depends(current_user)):
    with db.tx() as conn:
        conn.execute("UPDATE notifications SET read_at=%s WHERE user_id=%s AND read_at IS NULL", (clock.now(), user["id"]))
    return {"ok": True}


@router.get("/me/notification-prefs")
def get_prefs(user=Depends(current_user)):
    with db.tx() as conn:
        rows = {r["notification_id"]: r["enabled"] for r in conn.execute(
            "SELECT * FROM notification_prefs WHERE user_id=%s", (user["id"],))}
    labels = {"N1": "Expenses to confirm", "N2": "Payments to confirm", "N3": "Daily coin digest",
              "N4": "Settle-up nudges", "N5": "Monday household recap", "N6": "Redeem reminders",
              "N7": "Expiring coins", "N8": "Someone joined your group", "C1": "Recurring bills", "C2": "Comments",
              "C3": "Group chat", "C4": "Budget alerts",
              "C5": "Reminders to pay"}
    return {"prefs": [{"id": k, "label": v, "enabled": rows.get(k, True)} for k, v in labels.items()],
            "hide_coins": user["hide_coins"]}


class PrefIn(BaseModel):
    prefs: dict[str, bool]


@router.put("/me/notification-prefs")
def put_prefs(body: PrefIn, user=Depends(current_user)):
    with db.tx() as conn:
        for k, v in body.prefs.items():
            if k not in notify.ALL_IDS:
                continue
            conn.execute("""INSERT INTO notification_prefs (user_id, notification_id, enabled) VALUES (%s,%s,%s)
                            ON CONFLICT (user_id, notification_id) DO UPDATE SET enabled=EXCLUDED.enabled""",
                         (user["id"], k, v))
    return get_prefs(user)


# ---------------------------------------------------------------- config & analytics

@router.get("/config/coins")
def client_config(request: Request, response: Response):
    cfg = coin_config.current()
    body = coin_config.client_view(cfg)
    etag = '"' + hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16] + '"'
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers={"ETag": etag})
    response.headers["ETag"] = etag
    response.headers["Cache-Control"] = "max-age=30"
    return body


class AnalyticsIn(BaseModel):
    name: str
    group_id: int | None = None
    props: dict = {}
    app_version: str | None = None


@router.post("/analytics/events")
def client_event(body: AnalyticsIn, user=Depends(current_user)):
    if body.name not in analytics.KNOWN_CLIENT_EVENTS:
        raise HTTPException(400, "Unknown event")
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        arm = experiment.arm_of(conn, body.group_id, cfg) if body.group_id else None
        analytics.track(conn, body.name, user_id=user["id"], group_id=body.group_id, arm=arm,
                        config_version=cfg.version, platform="ios", app_version=body.app_version, **body.props)
    return {"ok": True}


# ---------------------------------------------------------------- invite landing page

landing = APIRouter()


@landing.get("/j/{token}", response_class=HTMLResponse)
def invite_landing(token: str):
    read_token(token)
    app = f"squared://join?token={token}"
    return f"""<!doctype html><meta name=viewport content="width=device-width"><title>Join on Squared</title>
<body style="background:#0d0d0d;color:#fff;font-family:-apple-system;padding:32px">
<h2>You're invited to split on Squared</h2><p>Open the app to join and start earning coins together.</p>
<a href="{app}" style="display:inline-block;background:#fff;color:#000;padding:14px 22px;font-weight:700;text-decoration:none">OPEN APP</a>
<script>location.href="{app}"</script></body>"""
