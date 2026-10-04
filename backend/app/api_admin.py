"""Ops console backend (FR-12). Role-based; every write needs a reason and is audit-logged."""
import uuid
from datetime import date, timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import clock, coin_config, db, jobs, ledger, redemption
from .api_coins import describe_entry
from .deps import ops_user
from .settings import settings

router = APIRouter(prefix="/api/v1/admin")


class Reason(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


def audit(conn, actor, action, target_type, target_id, reason):
    conn.execute(
        "INSERT INTO ops_audit_log (id, actor_id, action, target_type, target_id, reason, created_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (uuid.uuid4(), actor["id"], action, target_type, str(target_id), reason, clock.now()))


def _wallet_json(conn, w):
    if w["owner_type"] == "USER":
        u = conn.execute("SELECT name, email FROM users WHERE id=%s", (w["owner_id"],)).fetchone()
        label = f"{u['name'] or 'User'} ({u['email'] or 'no email'})" if u else f"user {w['owner_id']}"
    else:
        g = conn.execute("SELECT name FROM groups WHERE id=%s", (w["owner_id"],)).fetchone()
        label = f"Pot: {g['name']}" if g else f"group {w['owner_id']}"
    pending = conn.execute("SELECT count(*) c FROM coin_ledger WHERE wallet_id=%s AND status='PENDING'", (w["id"],)).fetchone()["c"]
    return {"id": str(w["id"]), "owner_type": w["owner_type"], "owner_id": w["owner_id"], "label": label,
            "balance": w["balance_cached"], "deficit": w["deficit"], "redemption_frozen": w["redemption_frozen"],
            "pending_entries": pending}


@router.get("/wallets")
def search_wallets(query: str = "", ops=Depends(ops_user)):
    q = f"%{query.strip()}%"
    with db.tx() as conn:
        users = [r["id"] for r in conn.execute(
            "SELECT id FROM users WHERE email ILIKE %s OR name ILIKE %s OR id::text = %s LIMIT 20", (q, q, query.strip()))]
        groups = [r["id"] for r in conn.execute(
            "SELECT id FROM groups WHERE name ILIKE %s OR id::text = %s LIMIT 20", (q, query.strip()))]
        # a group search also returns its members' wallets
        if groups:
            users += [r["user_id"] for r in conn.execute("SELECT user_id FROM group_members WHERE group_id = ANY(%s)", (groups,))]
        out = []
        for uid in dict.fromkeys(users):
            out.append(_wallet_json(conn, ledger.get_wallet(conn, "USER", uid)))
        for gid in groups:
            out.append(_wallet_json(conn, ledger.get_wallet(conn, "GROUP", gid)))
        return {"wallets": out}


@router.get("/wallets/{wallet_id}/ledger")
def wallet_ledger(wallet_id: str, ops=Depends(ops_user)):
    with db.tx() as conn:
        w = conn.execute("SELECT * FROM wallets WHERE id=%s", (wallet_id,)).fetchone()
        if not w:
            raise HTTPException(404, "Wallet not found")
        entries = conn.execute("SELECT * FROM coin_ledger WHERE wallet_id=%s ORDER BY created_at DESC LIMIT 200",
                               (wallet_id,)).fetchall()
        lots = conn.execute("SELECT * FROM coin_lots WHERE wallet_id=%s ORDER BY expires_at", (wallet_id,)).fetchall()
        reversed_ids = {str(r["reverses_entry_id"]) for r in entries if r["reverses_entry_id"]}
        return {
            "wallet": _wallet_json(conn, w),
            "integrity": ledger.integrity(conn, wallet_id),
            "entries": [{**describe_entry(conn, e), "idempotency_key": e["idempotency_key"],
                         "config_version": e["config_version"], "metadata": e["metadata"],
                         "reversed": str(e["id"]) in reversed_ids} for e in entries],
            "lots": [{"id": str(l["id"]), "earned_amount": l["earned_amount"], "remaining": l["remaining"],
                      "earned_at": l["earned_at"].isoformat(), "expires_at": l["expires_at"].isoformat()} for l in lots],
        }


@router.post("/ledger/{entry_id}/reverse")
def reverse_entry(entry_id: str, body: Reason, ops=Depends(ops_user)):
    with db.tx() as conn:
        e = conn.execute("SELECT * FROM coin_ledger WHERE id=%s", (entry_id,)).fetchone()
        if not e or e["entry_type"] not in ("EARN", "REFUND"):
            raise HTTPException(400, "Only earn or refund entries can be reversed")
        cfg = coin_config.current(conn, fresh=True)
        r = ledger.reverse(conn, e, reason="ops", cfg=cfg, metadata={"ops_reason": body.reason})
        audit(conn, ops, "REVERSE_ENTRY", "LEDGER_ENTRY", entry_id, body.reason)
        return {"reversal_id": str(r["id"]) if r else None}


class BulkReverseIn(Reason):
    entry_ids: list[str] = Field(min_length=1, max_length=500)


@router.post("/ledger/bulk-reverse")
def bulk_reverse(body: BulkReverseIn, ops=Depends(ops_user)):
    """FR-19: reverse many entries in one audited action (e.g. after confirming a ring)."""
    done, skipped = [], []
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        for eid in body.entry_ids:
            e = conn.execute("SELECT * FROM coin_ledger WHERE id=%s", (eid,)).fetchone()
            if not e or e["entry_type"] not in ("EARN", "REFUND"):
                skipped.append(eid)
                continue
            ledger.reverse(conn, e, reason="ops", cfg=cfg, metadata={"ops_reason": body.reason, "bulk": True})
            done.append(eid)
        audit(conn, ops, "BULK_REVERSE", "LEDGER_ENTRY", f"{len(done)} entries", body.reason)
    return {"reversed": len(done), "skipped": skipped}


@router.get("/rings")
def ring_report(days: int = 7, min_confirmations: int = 6, ops=Depends(ops_user)):
    """FR-19: pairs who keep confirming each other's expenses, flagged with shared devices or new accounts."""
    since = clock.now() - timedelta(days=days)
    with db.tx() as conn:
        rows = conn.execute(
            """SELECT LEAST(e.created_by, c.user_id) a, GREATEST(e.created_by, c.user_id) b, count(*) n,
                      COALESCE(SUM(e.amount_paise),0) volume, min(e.group_id) group_id
               FROM expense_confirmations c JOIN expenses e ON e.id=c.expense_id
               WHERE c.status='CONFIRMED' AND c.created_at >= %s
               GROUP BY 1, 2 HAVING count(*) >= %s ORDER BY n DESC LIMIT 100""", (since, min_confirmations)).fetchall()
        out = []
        for r in rows:
            ua = conn.execute("SELECT * FROM users WHERE id=%s", (r["a"],)).fetchone()
            ub = conn.execute("SELECT * FROM users WHERE id=%s", (r["b"],)).fetchone()
            earns = conn.execute(
                """SELECT l.id, l.amount FROM coin_ledger l JOIN wallets w ON w.id=l.wallet_id
                   WHERE w.owner_type='USER' AND w.owner_id = ANY(%s) AND l.entry_type='EARN' AND l.created_at >= %s
                   AND l.counterparty_user_id = ANY(%s) AND l.status <> 'REJECTED'
                   AND NOT EXISTS (SELECT 1 FROM coin_ledger x WHERE x.reverses_entry_id = l.id)""",
                ([r["a"], r["b"]], since, [r["a"], r["b"]])).fetchall()
            coins = sum(e["amount"] for e in earns)
            flags = []
            if ua["device_fingerprint"] and ua["device_fingerprint"] == ub["device_fingerprint"]:
                flags.append("shared device")
            for u in (ua, ub):
                if clock.now() - u["created_at"] < timedelta(days=7):
                    flags.append(f"{u['name'] or 'Someone'} is a new account")
            if r["volume"] / max(r["n"], 1) < 5000:
                flags.append("many small expenses")
            out.append({"users": [{"id": ua["id"], "name": ua["name"], "email": ua["email"]},
                                  {"id": ub["id"], "name": ub["name"], "email": ub["email"]}],
                        "confirmations": r["n"], "volume": int(r["volume"]), "coins_between": int(coins),
                        "entry_ids": [str(e["id"]) for e in earns],
                        "group_id": r["group_id"], "flags": flags, "risk": "high" if len(flags) >= 2 else "medium" if flags else "low"})
        return {"days": days, "pairs": out}


class FreezeIn(Reason):
    frozen: bool


@router.post("/wallets/{wallet_id}/freeze")
def freeze(wallet_id: str, body: FreezeIn, ops=Depends(ops_user)):
    with db.tx() as conn:
        conn.execute("UPDATE wallets SET redemption_frozen=%s WHERE id=%s", (body.frozen, wallet_id))
        audit(conn, ops, "FREEZE" if body.frozen else "UNFREEZE", "WALLET", wallet_id, body.reason)
    return {"ok": True, "frozen": body.frozen}


@router.get("/pending")
def pending(ops=Depends(ops_user)):
    with db.tx() as conn:
        rows = conn.execute("SELECT * FROM coin_ledger WHERE status='PENDING' ORDER BY created_at LIMIT 200").fetchall()
        out = []
        for r in rows:
            w = conn.execute("SELECT * FROM wallets WHERE id=%s", (r["wallet_id"],)).fetchone()
            out.append({**describe_entry(conn, r), "wallet": _wallet_json(conn, w), "metadata": r["metadata"],
                        "age_hours": round((clock.now() - r["created_at"]).total_seconds() / 3600, 1)})
        return {"pending": out}


@router.post("/pending/{entry_id}/release")
def release(entry_id: str, body: Reason, ops=Depends(ops_user)):
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        e = ledger.release_pending(conn, entry_id, cfg)
        if not e:
            raise HTTPException(409, "Entry is not pending")
        audit(conn, ops, "RELEASE_PENDING", "LEDGER_ENTRY", entry_id, body.reason)
    return {"ok": True}


@router.post("/pending/{entry_id}/reject")
def reject(entry_id: str, body: Reason, ops=Depends(ops_user)):
    with db.tx() as conn:
        if not ledger.reject_pending(conn, entry_id):
            raise HTTPException(409, "Entry is not pending")
        audit(conn, ops, "REJECT_PENDING", "LEDGER_ENTRY", entry_id, body.reason)
    return {"ok": True}


@router.get("/redemptions")
def redemptions(ops=Depends(ops_user)):
    with db.tx() as conn:
        rows = conn.execute(
            """SELECT r.id, r.status, r.coins, r.created_at, r.failure_code, c.brand, c.face_value_inr, u.name, u.email
               FROM redemptions r JOIN catalog_items c ON c.id=r.catalog_item_id JOIN users u ON u.id=r.redeemed_by
               ORDER BY r.created_at DESC LIMIT 100""").fetchall()
    return {"redemptions": [{**r, "id": str(r["id"]), "created_at": r["created_at"].isoformat()} for r in rows]}


@router.post("/redemptions/{rid}/release")
def release_redemption(rid: str, body: Reason, ops=Depends(ops_user)):
    with db.tx() as conn:
        r = conn.execute("SELECT status FROM redemptions WHERE id=%s", (rid,)).fetchone()
        if not r or r["status"] != "HELD":
            raise HTTPException(409, "Redemption is not held")
        audit(conn, ops, "RELEASE_REDEMPTION", "REDEMPTION", rid, body.reason)
    out = redemption.fulfil(rid)
    return {"status": out["status"]}


@router.get("/audit")
def audit_log(ops=Depends(ops_user)):
    with db.tx() as conn:
        rows = conn.execute(
            """SELECT a.*, u.name actor_name FROM ops_audit_log a LEFT JOIN users u ON u.id=a.actor_id
               ORDER BY a.created_at DESC LIMIT 200""").fetchall()
    return {"audit": [{**r, "id": str(r["id"]), "created_at": r["created_at"].isoformat()} for r in rows]}


@router.get("/config")
def get_config(ops=Depends(ops_user)):
    cfg = coin_config.current(fresh=True)
    return {"version": cfg.version, "body": dict(cfg)}


class ConfigPatch(Reason):
    patch: dict


@router.post("/config")
def put_config(body: ConfigPatch, ops=Depends(ops_user)):
    with db.tx() as conn:
        try:
            cfg = coin_config.publish(conn, body.patch, ops["id"])
        except coin_config.ConfigError as e:
            raise HTTPException(400, str(e))
        audit(conn, ops, "CONFIG_PUBLISH", "CONFIG", cfg.version, body.reason)
    return {"version": cfg.version, "body": dict(cfg)}


class ArmIn(Reason):
    arm: str


@router.post("/groups/{group_id}/arm")
def set_arm(group_id: int, body: ArmIn, ops=Depends(ops_user)):
    """Dogfood/QA override of a group's experiment arm. Audited."""
    if body.arm not in ("TREATMENT", "CONTROL"):
        raise HTTPException(400, "arm must be TREATMENT or CONTROL")
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        conn.execute("""INSERT INTO experiment_assignments (experiment_key, group_id, arm) VALUES (%s,%s,%s)
                        ON CONFLICT (experiment_key, group_id) DO UPDATE SET arm=EXCLUDED.arm""",
                     (cfg["experiment"]["key"], group_id, body.arm))
        audit(conn, ops, "SET_ARM", "GROUP", group_id, body.reason)
    return {"ok": True}


@router.get("/integrity")
def integrity(ops=Depends(ops_user)):
    with db.tx() as conn:
        rows = conn.execute("SELECT * FROM integrity_reports ORDER BY created_at DESC LIMIT 50").fetchall()
    return {"reports": [{**r, "wallet_id": str(r["wallet_id"]), "created_at": r["created_at"].isoformat()} for r in rows]}


@router.get("/metrics")
def metrics(ops=Depends(ops_user)):
    """Economy + funnel snapshot for the console (dashboards in 9.5 are built from analytics_events)."""
    with db.tx() as conn:
        start, _ = clock.ist_day_bounds()
        issued = conn.execute("SELECT COALESCE(SUM(amount),0) s FROM coin_ledger WHERE entry_type='EARN' AND status='POSTED' AND created_at >= %s",
                              (start,)).fetchone()["s"]
        spent = conn.execute("SELECT COALESCE(-SUM(amount),0) s FROM coin_ledger WHERE entry_type='SPEND' AND created_at >= %s",
                             (start,)).fetchone()["s"]
        pend = conn.execute("SELECT count(*) c FROM coin_ledger WHERE status='PENDING'").fetchone()["c"]
        outbox = conn.execute("SELECT count(*) c FROM outbox_events WHERE processed_at IS NULL").fetchone()["c"]
        deficits = conn.execute("SELECT count(*) c FROM wallets WHERE deficit > 0").fetchone()["c"]
        events = conn.execute("SELECT name, count(*) c FROM analytics_events WHERE created_at >= %s GROUP BY name ORDER BY c DESC",
                              (start,)).fetchall()
    return {"coins_issued_today": int(issued), "coins_redeemed_today": int(spent), "pending_entries": pend,
            "outbox_pending": outbox, "deficit_wallets": deficits, "events_today": events}


JOBS = {"recurring": lambda: __import__("app.api_features", fromlist=["x"]).run_recurring(), "close-weeks": jobs.close_weeks, "expire": jobs.expire_lots, "unverify": jobs.mark_unverified,
        "digest": jobs.daily_digest, "nudges": jobs.settle_nudges, "expiry-warn": jobs.expiry_warnings,
        "integrity": jobs.integrity_check, "release-redemptions": jobs.release_redemptions}


class JobIn(BaseModel):
    week_start: date | None = None


@router.post("/jobs/{name}")
def run_job(name: str, body: JobIn | None = None, ops=Depends(ops_user)):
    """Run a scheduled job now (local dev and on-call)."""
    if name not in JOBS:
        raise HTTPException(404, "Unknown job")
    if name == "close-weeks" and body and body.week_start:
        if not settings.is_dev:
            raise HTTPException(403, "Week override is dev-only")
        result = jobs.close_weeks(force_week=body.week_start)
    else:
        result = JOBS[name]()
    return {"job": name, "result": result}
