"""Core splitting API (stands in for the existing Splitwise endpoints) plus auth.

Writes emit domain events via the outbox in the same transaction. Nothing here calls
the reward engine, so expenses, balances and payments work even if rewards are down (I-1).
"""
import json
import logging
import re
import secrets
from datetime import timedelta
from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import analytics, categories, clock, coin_config, db, domain, events, experiment, fx, splits, views
from .deps import current_user, require_member
from .settings import settings

router = APIRouter(prefix="/api/v1")
log = logging.getLogger("core")
PHONE_RE = re.compile(r"^\+?[0-9]{10,15}$")


# ---------------------------------------------------------------- auth

class OtpRequest(BaseModel):
    phone: str


class OtpVerify(BaseModel):
    phone: str
    otp: str
    device_id: str | None = None


def _norm_phone(p: str) -> str:
    p = p.replace(" ", "").replace("-", "")
    if not PHONE_RE.match(p):
        raise HTTPException(400, "Enter a valid phone number")
    if len(p) == 10 and not p.startswith("+"):
        p = "+91" + p
    return p if p.startswith("+") else "+" + p


@router.post("/auth/otp/request")
def otp_request(body: OtpRequest):
    phone = _norm_phone(body.phone)
    code = settings.dev_otp if settings.is_dev and settings.dev_otp else f"{secrets.randbelow(10**6):06d}"
    with db.tx() as conn:
        conn.execute("""INSERT INTO otp_codes (phone, code, expires_at) VALUES (%s,%s,%s)
                        ON CONFLICT (phone) DO UPDATE SET code=EXCLUDED.code, expires_at=EXCLUDED.expires_at""",
                     (phone, code, clock.now() + timedelta(minutes=10)))
    from . import sms
    if not (settings.is_dev and settings.dev_otp):
        sms.send_otp(phone, code)
    out = {"phone": phone, "sent": True}
    if settings.is_dev:
        out["dev_hint"] = "Local dev: use the DEV_OTP from backend/.env.dev"
    return out


@router.post("/auth/otp/verify")
def otp_verify(body: OtpVerify):
    phone = _norm_phone(body.phone)
    with db.tx() as conn:
        row = conn.execute("SELECT * FROM otp_codes WHERE phone=%s", (phone,)).fetchone()
        if not row or row["code"] != body.otp or row["expires_at"] < clock.now():
            raise HTTPException(400, "That code didn't work. Try again.")
        conn.execute("DELETE FROM otp_codes WHERE phone=%s", (phone,))
        user = conn.execute("SELECT * FROM users WHERE phone=%s", (phone,)).fetchone()
        is_new = user is None
        if is_new:
            user = conn.execute(
                "INSERT INTO users (phone, phone_verified, device_fingerprint, created_at) VALUES (%s, true, %s, %s) RETURNING *",
                (phone, body.device_id, clock.now())).fetchone()
            analytics.track(conn, "signup_completed", user_id=user["id"], platform="server")
        else:
            conn.execute("UPDATE users SET phone_verified=true, device_fingerprint=COALESCE(%s, device_fingerprint) WHERE id=%s",
                         (body.device_id, user["id"]))
        token = secrets.token_urlsafe(32)
        conn.execute("INSERT INTO sessions (token, user_id, device_id, created_at) VALUES (%s,%s,%s,%s)",
                     (token, user["id"], body.device_id, clock.now()))
    return {"token": token, "is_new": is_new or not user["name"], "user": user_json(user)}


def user_json(u: dict) -> dict:
    return {"id": u["id"], "phone": u["phone"], "name": u["name"], "email": u["email"], "upi_id": u["upi_id"],
            "role": u["role"], "hide_coins": u["hide_coins"], "intro_seen": u["intro_seen"], "locale": u["locale"],
            "created_at": u["created_at"].isoformat()}


@router.post("/auth/logout")
def logout(user=Depends(current_user)):
    with db.tx() as conn:
        conn.execute("DELETE FROM sessions WHERE user_id=%s", (user["id"],))
    return {"ok": True}


class MePatch(BaseModel):
    name: str | None = Field(default=None, max_length=60)
    email: str | None = Field(default=None, max_length=120)
    upi_id: str | None = Field(default=None, max_length=80)
    hide_coins: bool | None = None
    intro_seen: bool | None = None
    locale: str | None = Field(default=None, pattern="^(en|hi)$")


@router.get("/me")
def me(user=Depends(current_user)):
    return user_json(user)


@router.patch("/me")
def patch_me(body: MePatch, user=Depends(current_user)):
    fields = body.model_dump(exclude_none=True)
    if "name" in fields and not fields["name"].strip():
        raise HTTPException(400, "Name can't be empty")
    with db.tx() as conn:
        for k, v in fields.items():
            conn.execute(f"UPDATE users SET {k}=%s WHERE id=%s", (v.strip() if isinstance(v, str) else v, user["id"]))
        u = conn.execute("SELECT * FROM users WHERE id=%s", (user["id"],)).fetchone()
    return user_json(u)


# ---------------------------------------------------------------- groups

class GroupCreate(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    group_type: str = "HOME"
    expected_members: int | None = Field(default=None, ge=1, le=12)
    currency: str = "INR"


def _group_summary(conn, g, user_id, cfg):
    members = experiment.active_member_ids(conn, g["id"])
    net = domain.user_net(conn, g["id"]).get(user_id, 0)
    return {"id": g["id"], "name": g["name"], "group_type": g["group_type"], "currency": g["currency"], "member_count": len(members),
            "my_net_paise": net, "coins_enabled": views.eligible(conn, g["id"], cfg)}


@router.get("/groups")
def list_groups(user=Depends(current_user)):
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        gs = conn.execute(
            """SELECT g.* FROM groups g JOIN group_members m ON m.group_id=g.id
               WHERE m.user_id=%s AND m.left_at IS NULL ORDER BY g.created_at DESC""", (user["id"],)).fetchall()
        return {"groups": [_group_summary(conn, g, user["id"], cfg) for g in gs]}


@router.post("/groups")
def create_group(body: GroupCreate, user=Depends(current_user)):
    if body.group_type not in ("HOME", "TRIP", "COUPLE", "OTHER"):
        raise HTTPException(400, "Unknown group type")
    if body.currency.upper() not in fx.SUPPORTED:
        raise HTTPException(400, "Unsupported currency")
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        g = conn.execute(
            "INSERT INTO groups (name, group_type, expected_members, currency, created_by, created_at) VALUES (%s,%s,%s,%s,%s,%s) RETURNING *",
            (body.name.strip(), body.group_type, body.expected_members, body.currency.upper(), user["id"], clock.now())).fetchone()
        conn.execute("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (%s,%s,%s)",
                     (g["id"], user["id"], clock.now()))
        views.safe(conn, experiment.assign, conn, g, cfg)
        events.emit(conn, "MemberJoined", group_id=g["id"], user_id=user["id"])
        return _group_summary(conn, g, user["id"], cfg)


@router.get("/groups/{group_id}")
def group_detail(group_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        cfg = coin_config.current(conn)
        eligible = views.eligible(conn, group_id, cfg) and not user["hide_coins"]
        members = conn.execute(
            """SELECT u.id, u.name, u.phone, u.upi_id FROM group_members m JOIN users u ON u.id=m.user_id
               WHERE m.group_id=%s AND m.left_at IS NULL ORDER BY m.joined_at""", (group_id,)).fetchall()
        exps = conn.execute(
            "SELECT id FROM expenses WHERE group_id=%s AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 100",
            (group_id,)).fetchall()
        exps = [domain.load_expense(conn, r["id"]) for r in exps]
        pays = conn.execute(
            "SELECT * FROM payments WHERE group_id=%s AND deleted_at IS NULL ORDER BY created_at DESC LIMIT 100",
            (group_id,)).fetchall()
        ids = {m["id"] for m in members}
        for e in exps:
            ids |= {e["paid_by"], e["created_by"]} | {s["user_id"] for s in e["splits"]}
        for p in pays:
            ids |= {p["payer_id"], p["receiver_id"]}
        names = domain.user_names(conn, ids)
        debts = domain.group_debts(conn, g)
        my_debts = []
        for (a, b), v in sorted(debts.items(), key=lambda kv: -kv[1]):
            if user["id"] not in (a, b):
                continue
            item = {"debtor_id": a, "debtor_name": names.get(a), "creditor_id": b, "creditor_name": names.get(b),
                    "amount_paise": v, "you_owe": a == user["id"]}
            if a == user["id"]:
                cred = next((m for m in members if m["id"] == b), None)
                item["creditor_upi"] = cred["upi_id"] if cred else None
                if eligible:
                    item["pay_reward_hint"] = views.safe(conn, views.settle_hint, conn, group_id, a, b, cfg)
            my_debts.append(item)
        return {
            "id": g["id"], "name": g["name"], "group_type": g["group_type"], "expected_members": g["expected_members"],
            "currency": g["currency"], "simplify_debts": g["simplify_debts"], "default_split": g["default_split"],
            "created_by": g["created_by"],
            "arm": views.safe(conn, experiment.arm_of, conn, group_id, cfg),
            "coins_enabled": eligible,
            "members": [{"id": m["id"], "name": names.get(m["id"]), "is_you": m["id"] == user["id"]} for m in members],
            "my_net_paise": domain.user_net(conn, group_id).get(user["id"], 0),
            "debts": my_debts,
            "all_debts": [{"debtor_id": a, "creditor_id": b, "amount_paise": v} for (a, b), v in debts.items()],
            "expenses": [views.expense_json(conn, user["id"], e, names, cfg, eligible) for e in exps],
            "payments": [views.payment_json(conn, user["id"], p, names, eligible) for p in pays],
        }


@router.post("/groups/{group_id}/leave")
def leave_group(group_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        net = domain.user_net(conn, group_id).get(user["id"], 0)
        if net != 0:
            raise HTTPException(409, f"You have an open balance of {fx.fmt(abs(net), g['currency'])}. Settle up first.")
        conn.execute("UPDATE group_members SET left_at=%s WHERE group_id=%s AND user_id=%s",
                     (clock.now(), group_id, user["id"]))
        events.emit(conn, "MemberLeft", group_id=group_id, user_id=user["id"])
    return {"ok": True}


# ---------------------------------------------------------------- expenses

class ExpenseIn(BaseModel):
    description: str = Field(min_length=1, max_length=80)
    amount_paise: int = Field(gt=0, le=10**12)    # minor units of `currency`
    currency: str | None = None                   # defaults to the group currency
    paid_by: int | None = None
    split_type: str | None = None                 # EQUAL (default), EXACT, PERCENT, SHARES
    participants: list[int] | None = None         # EQUAL: split among these
    exact: dict[int, int] | None = None           # EXACT: minor units per person, in `currency`
    percents: dict[int, float] | None = None      # PERCENT: must add up to 100
    shares: dict[int, float] | None = None        # SHARES: weights (legacy clients: exact paise)
    category: str | None = None


class ExpensePatch(BaseModel):
    description: str | None = Field(default=None, min_length=1, max_length=80)
    amount_paise: int | None = Field(default=None, gt=0, le=10**12)
    currency: str | None = None
    paid_by: int | None = None
    split_type: str | None = None
    participants: list[int] | None = None
    exact: dict[int, int] | None = None
    percents: dict[int, float] | None = None
    shares: dict[int, float] | None = None
    category: str | None = None


def _resolve_split(body, amount: int, members: set[int]) -> tuple[str, dict[int, int], dict]:
    split_type = (body.split_type or "").upper()
    exact = body.exact
    if not split_type:
        if body.shares and not body.exact:   # legacy: `shares` used to mean exact paise
            split_type, exact = "EXACT", {k: int(v) for k, v in body.shares.items()}
        elif exact:
            split_type = "EXACT"
        else:
            split_type = "EQUAL"
    try:
        shares, meta = splits.compute(amount, split_type, members, participants=body.participants, exact=exact,
                                      percents=body.percents, shares=body.shares if split_type == "SHARES" else None)
    except splits.SplitError as e:
        raise HTTPException(400, str(e))
    return split_type, shares, meta


def _money(conn, group: dict, amount: int, currency: str | None, keep_rate=None) -> tuple[int, str | None, int | None, Decimal | None]:
    """(amount in group currency, original currency, original minor, rate). Same currency → no originals."""
    gcur = group["currency"]
    cur = (currency or gcur).upper()
    if cur == gcur:
        return amount, None, None, None
    if cur not in fx.SUPPORTED:
        raise HTTPException(400, f"{cur} isn't supported yet")
    try:
        rate = keep_rate if keep_rate is not None else fx.rate(conn, cur, gcur)
    except fx.FxUnavailable as e:
        raise HTTPException(503, str(e))
    converted = fx.convert_minor(amount, cur, gcur, rate)
    if converted <= 0:
        raise HTTPException(400, "That amount is too small to convert")
    return converted, cur, amount, rate


def _write_splits(conn, expense_id, shares):
    conn.execute("DELETE FROM expense_splits WHERE expense_id=%s", (expense_id,))
    for u, v in shares.items():
        conn.execute("INSERT INTO expense_splits (expense_id, user_id, share_paise) VALUES (%s,%s,%s)", (expense_id, u, v))


def create_expense(conn, g: dict, actor_id: int, body: "ExpenseIn", recurring_id=None) -> dict:
    """Shared by the API and recurring bills, so both go through identical validation and events."""
    members = set(experiment.active_member_ids(conn, g["id"]))
    paid_by = body.paid_by or actor_id
    if paid_by not in members:
        raise HTTPException(400, "Payer must be in the group")
    split_type, shares_orig, meta = _resolve_split(body, body.amount_paise, members)
    amount_g, ocur, ominor, rate = _money(conn, g, body.amount_paise, body.currency)
    shares = splits.reallocate(amount_g, shares_orig) if ocur else shares_orig
    now = clock.now()
    e = conn.execute(
        """INSERT INTO expenses (group_id, description, amount_paise, currency, paid_by, created_by, created_at,
               updated_at, split_type, split_meta, category, original_currency, original_amount_minor, fx_rate, recurring_id)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
        (g["id"], body.description.strip(), amount_g, g["currency"], paid_by, actor_id, now, now, split_type,
         json.dumps(meta), categories.normalize(body.category, body.description), ocur, ominor, rate,
         recurring_id)).fetchone()
    _write_splits(conn, e["id"], shares)
    events.emit(conn, "ExpenseCreated", expense_id=e["id"], group_id=g["id"], version=1, user_id=actor_id)
    if conn.execute("SELECT 1 FROM group_budgets WHERE group_id=%s AND category=%s", (g["id"], e["category"])).fetchone():
        from .api_features import check_budgets
        views.safe(conn, check_budgets, conn, g["id"])
    return e


@router.post("/groups/{group_id}/expenses")
def add_expense(group_id: int, body: ExpenseIn, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        e = create_expense(conn, g, user["id"], body)
        e = domain.load_expense(conn, e["id"])
        members = set(experiment.active_member_ids(conn, group_id))
        cfg = coin_config.current(conn)
        eligible = views.eligible(conn, group_id, cfg) and not user["hide_coins"]
        names = domain.user_names(conn, members | {s["user_id"] for s in e["splits"]})
        out = views.expense_json(conn, user["id"], e, names, cfg, eligible)
        if eligible:  # S3 success sheet
            others = sorted(domain.participants(e) - {user["id"]})
            out["success_hint"] = {"adder_coins": out["confirmation"]["adder_reward"] if out.get("confirmation") else 0,
                                   "notified": [names.get(u) for u in others]}
        return out


@router.get("/expenses/{expense_id}")
def get_expense(expense_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        e = domain.load_expense(conn, expense_id)
        if not e or e["deleted_at"]:
            raise HTTPException(404, "Expense not found")
        require_member(conn, e["group_id"], user["id"])
        cfg = coin_config.current(conn)
        eligible = views.eligible(conn, e["group_id"], cfg) and not user["hide_coins"]
        names = domain.user_names(conn, [e["paid_by"], e["created_by"]] + [s["user_id"] for s in e["splits"]])
        return views.expense_json(conn, user["id"], e, names, cfg, eligible)


@router.patch("/expenses/{expense_id}")
def edit_expense(expense_id: int, body: ExpensePatch, user=Depends(current_user)):
    with db.tx() as conn:
        e = domain.load_expense(conn, expense_id, lock=True)
        if not e or e["deleted_at"]:
            raise HTTPException(404, "Expense not found")
        g = require_member(conn, e["group_id"], user["id"])
        members = set(experiment.active_member_ids(conn, e["group_id"])) | {s["user_id"] for s in e["splits"]}
        old_cur = e["original_currency"] or e["currency"]
        old_amount = e["original_amount_minor"] if e["original_currency"] else e["amount_paise"]
        cur = (body.currency or old_cur).upper()
        amount = body.amount_paise or old_amount
        paid_by = body.paid_by or e["paid_by"]
        old_splits = {s["user_id"]: s["share_paise"] for s in e["splits"]}
        split_changed = any(x is not None for x in (body.split_type, body.participants, body.exact, body.percents, body.shares))
        money_input_changed = amount != old_amount or cur != old_cur
        if split_changed or money_input_changed:
            if not split_changed:
                # re-run the stored split with the new amount
                meta = e["split_meta"] or {}
                body.split_type = e["split_type"]
                body.participants = meta.get("participants") or (list(old_splits) if e["split_type"] == "EQUAL" else None)
                body.percents = {int(k): v for k, v in meta.get("percents", {}).items()} or None
                body.shares = {int(k): v for k, v in meta.get("shares", {}).items()} or None
                if e["split_type"] == "EXACT":
                    raise HTTPException(400, "This expense uses exact amounts. Update each person's amount too.")
            split_type, shares_orig, meta = _resolve_split(body, amount, members)
            # keep the original rate snapshot unless the currency changed
            keep = Decimal(str(e["fx_rate"])) if (cur == old_cur and e["fx_rate"] is not None) else None
            amount_g, ocur, ominor, rate = _money(conn, g, amount, cur, keep_rate=keep)
            new_splits = splits.reallocate(amount_g, shares_orig) if ocur else shares_orig
        else:
            split_type, meta = e["split_type"], e["split_meta"]
            amount_g, ocur, ominor, rate = e["amount_paise"], e["original_currency"], e["original_amount_minor"], e["fx_rate"]
            new_splits = old_splits
        money_changed = amount_g != e["amount_paise"] or paid_by != e["paid_by"] or new_splits != old_splits
        version = e["version"] + (1 if money_changed else 0)
        desc = (body.description or e["description"]).strip()
        category = categories.normalize(body.category, desc) if body.category or body.description else e["category"]
        conn.execute(
            """UPDATE expenses SET description=%s, amount_paise=%s, paid_by=%s, version=%s, updated_at=%s, split_type=%s,
                   split_meta=%s, category=%s, original_currency=%s, original_amount_minor=%s, fx_rate=%s WHERE id=%s""",
            (desc, amount_g, paid_by, version, clock.now(), split_type, json.dumps(meta), category, ocur, ominor,
             rate, expense_id))
        if new_splits != old_splits:
            _write_splits(conn, expense_id, new_splits)
        events.emit(conn, "ExpenseUpdated", expense_id=expense_id, group_id=e["group_id"], version=version,
                    money_changed=money_changed, user_id=user["id"])
    return get_expense(expense_id, user)


@router.delete("/expenses/{expense_id}")
def delete_expense(expense_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        e = domain.load_expense(conn, expense_id, lock=True)
        if not e or e["deleted_at"]:
            raise HTTPException(404, "Expense not found")
        require_member(conn, e["group_id"], user["id"])
        conn.execute("UPDATE expenses SET deleted_at=%s WHERE id=%s", (clock.now(), expense_id))
        events.emit(conn, "ExpenseDeleted", expense_id=expense_id, group_id=e["group_id"], version=e["version"])
    return {"ok": True}


# ---------------------------------------------------------------- payments

class PaymentIn(BaseModel):
    receiver_id: int
    amount_paise: int = Field(gt=0, le=10**10)
    note: str | None = Field(default=None, max_length=120)


@router.post("/groups/{group_id}/payments")
def record_payment(group_id: int, body: PaymentIn, user=Depends(current_user)):
    with db.tx() as conn:
        require_member(conn, group_id, user["id"])
        if body.receiver_id == user["id"] or body.receiver_id not in experiment.active_member_ids(conn, group_id):
            raise HTTPException(400, "Pick a roommate to pay")
        p = conn.execute(
            """INSERT INTO payments (group_id, payer_id, receiver_id, amount_paise, note, created_at)
               VALUES (%s,%s,%s,%s,%s,%s) RETURNING *""",
            (group_id, user["id"], body.receiver_id, body.amount_paise, body.note, clock.now())).fetchone()
        cfg = coin_config.current(conn)
        conn.execute("INSERT INTO payment_confirmations (payment_id, status, expires_at) VALUES (%s,'PENDING',%s)",
                     (p["id"], clock.now() + timedelta(days=cfg["confirmation"]["payment_unverified_after_days"])))
        events.emit(conn, "PaymentRecorded", payment_id=p["id"], group_id=group_id, version=1)
        eligible = views.eligible(conn, group_id, cfg)
        if eligible:
            analytics.track(conn, "payment_marked_paid", user_id=user["id"], group_id=group_id,
                            arm=experiment.arm_of(conn, group_id, cfg), config_version=cfg.version, payment_id=p["id"],
                            amount_bucket=_bucket(p["amount_paise"]))
        names = domain.user_names(conn, [p["payer_id"], p["receiver_id"]])
        return views.payment_json(conn, user["id"], p, names, eligible)


def _bucket(paise: int) -> str:
    r = paise / 100
    return "<100" if r < 100 else "<500" if r < 500 else "<2000" if r < 2000 else "2000+"


@router.delete("/payments/{payment_id}")
def delete_payment(payment_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        p = conn.execute("SELECT * FROM payments WHERE id=%s FOR UPDATE", (payment_id,)).fetchone()
        if not p or p["deleted_at"]:
            raise HTTPException(404, "Payment not found")
        require_member(conn, p["group_id"], user["id"])
        conn.execute("UPDATE payments SET deleted_at=%s WHERE id=%s", (clock.now(), payment_id))
        events.emit(conn, "PaymentDeleted", payment_id=payment_id, group_id=p["group_id"], version=1)
    return {"ok": True}
