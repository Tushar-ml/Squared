"""Core splitting API (stands in for the existing Splitwise endpoints) plus auth.

Writes emit domain events via the outbox in the same transaction. Nothing here calls
the reward engine, so expenses, balances and payments work even if rewards are down (I-1).
"""
import logging
import re
import secrets
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import analytics, clock, coin_config, db, domain, events, experiment, views
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
    log.info("OTP issued for %s", phone[-4:])  # an SMS provider would deliver it in production
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
            "role": u["role"], "hide_coins": u["hide_coins"], "intro_seen": u["intro_seen"],
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


def _group_summary(conn, g, user_id, cfg):
    members = experiment.active_member_ids(conn, g["id"])
    net = domain.user_net(conn, g["id"]).get(user_id, 0)
    return {"id": g["id"], "name": g["name"], "group_type": g["group_type"], "member_count": len(members),
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
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        g = conn.execute(
            "INSERT INTO groups (name, group_type, expected_members, created_by, created_at) VALUES (%s,%s,%s,%s,%s) RETURNING *",
            (body.name.strip(), body.group_type, body.expected_members, user["id"], clock.now())).fetchone()
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
        debts = domain.pair_debts(conn, group_id)
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
        require_member(conn, group_id, user["id"])
        conn.execute("UPDATE group_members SET left_at=%s WHERE group_id=%s AND user_id=%s",
                     (clock.now(), group_id, user["id"]))
        events.emit(conn, "MemberLeft", group_id=group_id, user_id=user["id"])
    return {"ok": True}


# ---------------------------------------------------------------- expenses

class ExpenseIn(BaseModel):
    description: str = Field(min_length=1, max_length=80)
    amount_paise: int = Field(gt=0, le=10**10)
    paid_by: int | None = None
    participants: list[int] | None = None  # equal split among these
    shares: dict[int, int] | None = None     # or exact shares in paise
    currency: str = "INR"


class ExpensePatch(BaseModel):
    description: str | None = Field(default=None, min_length=1, max_length=80)
    amount_paise: int | None = Field(default=None, gt=0, le=10**10)
    paid_by: int | None = None
    participants: list[int] | None = None
    shares: dict[int, int] | None = None


def _splits(amount: int, participants: list[int] | None, shares: dict[int, int] | None, members: set[int]) -> dict[int, int]:
    if shares:
        shares = {int(k): int(v) for k, v in shares.items()}
        if sum(shares.values()) != amount or any(v < 0 for v in shares.values()):
            raise HTTPException(400, "Shares must add up to the amount")
        if not set(shares) <= members:
            raise HTTPException(400, "Everyone in the split must be in the group")
        return shares
    parts = sorted(set(participants or members))
    if not parts or not set(parts) <= members:
        raise HTTPException(400, "Everyone in the split must be in the group")
    base, rem = divmod(amount, len(parts))
    return {u: base + (1 if i < rem else 0) for i, u in enumerate(parts)}


def _write_splits(conn, expense_id, splits):
    conn.execute("DELETE FROM expense_splits WHERE expense_id=%s", (expense_id,))
    for u, v in splits.items():
        conn.execute("INSERT INTO expense_splits (expense_id, user_id, share_paise) VALUES (%s,%s,%s)", (expense_id, u, v))


@router.post("/groups/{group_id}/expenses")
def add_expense(group_id: int, body: ExpenseIn, user=Depends(current_user)):
    with db.tx() as conn:
        require_member(conn, group_id, user["id"])
        members = set(experiment.active_member_ids(conn, group_id))
        paid_by = body.paid_by or user["id"]
        if paid_by not in members:
            raise HTTPException(400, "Payer must be in the group")
        splits = _splits(body.amount_paise, body.participants, body.shares, members)
        now = clock.now()
        e = conn.execute(
            """INSERT INTO expenses (group_id, description, amount_paise, currency, paid_by, created_by, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (group_id, body.description.strip(), body.amount_paise, body.currency, paid_by, user["id"], now, now)).fetchone()
        _write_splits(conn, e["id"], splits)
        events.emit(conn, "ExpenseCreated", expense_id=e["id"], group_id=group_id, version=1, user_id=user["id"])
        e = domain.load_expense(conn, e["id"])
        cfg = coin_config.current(conn)
        eligible = views.eligible(conn, group_id, cfg) and not user["hide_coins"]
        names = domain.user_names(conn, members)
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
        require_member(conn, e["group_id"], user["id"])
        members = set(experiment.active_member_ids(conn, e["group_id"])) | {s["user_id"] for s in e["splits"]}
        amount = body.amount_paise or e["amount_paise"]
        paid_by = body.paid_by or e["paid_by"]
        old_splits = {s["user_id"]: s["share_paise"] for s in e["splits"]}
        if body.participants is not None or body.shares is not None or amount != e["amount_paise"]:
            parts = body.participants if body.participants is not None else (None if body.shares else list(old_splits))
            splits = _splits(amount, parts, body.shares, members)
        else:
            splits = old_splits
        money_changed = amount != e["amount_paise"] or paid_by != e["paid_by"] or splits != old_splits
        version = e["version"] + (1 if money_changed else 0)
        conn.execute("UPDATE expenses SET description=%s, amount_paise=%s, paid_by=%s, version=%s, updated_at=%s WHERE id=%s",
                     ((body.description or e["description"]).strip(), amount, paid_by, version, clock.now(), expense_id))
        if splits != old_splits:
            _write_splits(conn, expense_id, splits)
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
