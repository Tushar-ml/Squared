"""Read models that attach the additive `confirmation` / coin objects to core payloads.

Failures here must never break the core payload (FR-14): callers wrap them in safe().
"""
import logging
from datetime import timedelta

from . import clock, domain, experiment, ledger

log = logging.getLogger("views")


def safe(conn, fn, *args, default=None, **kw):
    """Run a coin read inside a savepoint so a failure cannot abort the core transaction."""
    try:
        with conn.transaction():
            return fn(*args, **kw)
    except Exception:  # noqa: BLE001 - fail open
        log.exception("coin view failed")
        return default


def reward_preview(conn, viewer_id: int, expense: dict, cfg) -> dict:
    """What the viewer earns by confirming. Server-computed; clients never send amounts (I-2)."""
    gid = expense["group_id"]
    out = {"coins": cfg["earn"]["expense_confirmer"], "first_win_bonus": 0, "capped_reason": None}
    w = ledger.get_wallet(conn, "USER", viewer_id)
    if not conn.execute("SELECT 1 FROM coin_ledger WHERE wallet_id=%s AND reason_code='FIRST_WIN'", (w["id"],)).fetchone():
        out["first_win_bonus"] = cfg["earn"]["first_win"]
    if expense["amount_paise"] < cfg["min_expense_inr"] * 100 or expense["currency"] != "INR":
        out.update(coins=0, first_win_bonus=0, capped_reason="below_min")
        return out
    confirmed = conn.execute(
        "SELECT count(*) c FROM expense_confirmations WHERE expense_id=%s AND expense_version=%s AND status='CONFIRMED'",
        (expense["id"], expense["version"])).fetchone()["c"]
    if confirmed >= cfg["earn"]["max_confirmers_per_expense"]:
        out.update(coins=0, capped_reason="max_confirmers")
        return out
    day = clock.ist_day_bounds()
    month = clock.ist_month_bounds()
    if ledger.cap_sum(conn, w["id"], *day) >= cfg["caps"]["user_daily"]:
        out.update(coins=0, capped_reason="cap_user_daily")
    elif ledger.cap_sum(conn, w["id"], *month) >= cfg["caps"]["user_monthly"]:
        out.update(coins=0, capped_reason="cap_user_monthly")
    else:
        pair = conn.execute(
            """SELECT count(*) c FROM coin_ledger WHERE wallet_id=%s AND reason_code='EXPENSE_CONFIRMER'
               AND counterparty_user_id=%s AND status IN ('POSTED','PENDING') AND created_at >= %s AND created_at < %s""",
            (w["id"], expense["created_by"], *day)).fetchone()["c"]
        group = conn.execute(
            """SELECT count(DISTINCT source_id) c FROM coin_ledger WHERE group_id=%s AND reason_code='EXPENSE_ADDER'
               AND status IN ('POSTED','PENDING') AND created_at >= %s AND created_at < %s""", (gid, *day)).fetchone()["c"]
        if pair >= cfg["caps"]["pair_daily_confirmations"]:
            out.update(coins=0, capped_reason="cap_pair_daily_confirmations")
        elif group >= cfg["caps"]["group_daily_rewarded_expenses"]:
            out.update(coins=0, capped_reason="cap_group_daily_rewarded_expenses")
    return out


def confirmation_object(conn, viewer_id: int, expense: dict, cfg, names: dict) -> dict:
    st = domain.expense_state(conn, expense, cfg)
    can_remind = []
    if viewer_id == expense["created_by"]:
        cutoff = clock.now() - timedelta(hours=cfg["push"]["remind_cooldown_hours"])
        for u in st["waiting_on"]:
            last = conn.execute("SELECT max(reminded_at) t FROM expense_reminders WHERE expense_id=%s AND user_id=%s",
                                (expense["id"], u)).fetchone()["t"]
            if last is None or last < cutoff:
                can_remind.append(u)
    mine = next((c for c in domain.confirmations(conn, expense["id"], expense["version"]) if c["user_id"] == viewer_id), None)
    obj = {
        "status": st["status"],
        "version": st["version"],
        "confirmed_by": [{"user_id": u, "name": names.get(u)} for u in st["confirmed_by"]],
        "disputed_by": [{**d, "name": names.get(d["user_id"])} for d in st["disputed_by"]],
        "waiting_on": [{"user_id": u, "name": names.get(u)} for u in st["waiting_on"]],
        "my_response": mine["status"] if mine else None,
        "can_confirm": viewer_id in st["waiting_on"],
        "can_remind": [{"user_id": u, "name": names.get(u)} for u in can_remind],
        "adder_reward": cfg["earn"]["expense_adder"] if expense["amount_paise"] >= cfg["min_expense_inr"] * 100 else 0,
    }
    if obj["can_confirm"]:
        obj["reward_preview"] = reward_preview(conn, viewer_id, expense, cfg)
    return obj


def expense_json(conn, viewer_id: int, e: dict, names: dict, cfg=None, eligible=False) -> dict:
    shares = {s["user_id"]: s["share_paise"] for s in e["splits"]}
    out = {
        "id": e["id"], "group_id": e["group_id"], "description": e["description"],
        "amount_paise": e["amount_paise"], "currency": e["currency"], "paid_by": e["paid_by"],
        "paid_by_name": names.get(e["paid_by"]), "created_by": e["created_by"],
        "created_by_name": names.get(e["created_by"]), "version": e["version"],
        "splits": [{"user_id": s["user_id"], "name": names.get(s["user_id"]), "share_paise": s["share_paise"]}
                   for s in e["splits"]],
        "my_share_paise": shares.get(viewer_id, 0),
        "created_at": e["created_at"].isoformat(), "updated_at": e["updated_at"].isoformat(),
    }
    if eligible and cfg is not None:
        out["confirmation"] = safe(conn, confirmation_object, conn, viewer_id, e, cfg, names)
    return out


def payment_json(conn, viewer_id: int, p: dict, names: dict, eligible=False) -> dict:
    out = {"id": p["id"], "group_id": p["group_id"], "payer_id": p["payer_id"], "payer_name": names.get(p["payer_id"]),
           "receiver_id": p["receiver_id"], "receiver_name": names.get(p["receiver_id"]),
           "amount_paise": p["amount_paise"], "note": p["note"], "created_at": p["created_at"].isoformat()}
    pc = domain.payment_state(conn, p["id"])
    if pc:
        status = pc["status"]
        if status == "PENDING" and pc["expires_at"] <= clock.now():
            status = "UNVERIFIED"
        out["confirmation"] = {"status": status, "confirmed_at": pc["confirmed_at"].isoformat() if pc["confirmed_at"] else None,
                               "note": pc["note"], "can_confirm": viewer_id == p["receiver_id"] and status == "PENDING",
                               "coins_eligible": eligible}
    return out


def settle_hint(conn, group_id: int, debtor: int, creditor: int, cfg) -> int:
    """Coins the payer would earn by settling now (for "Pay today for +30 coins")."""
    fake = {"id": -1, "created_at": clock.now()}
    start = domain.debt_age_start(conn, group_id, debtor, creditor, fake)
    coins = cfg["earn"]["settle_payer"]
    if start is not None and clock.now() - start <= timedelta(hours=cfg["earn"]["quick_window_hours"]):
        coins += cfg["earn"]["settle_quick_bonus"]
    return coins


def eligible(conn, group_id, cfg) -> bool:
    return safe(conn, lambda: experiment.eligibility(conn, group_id, cfg)[0], default=False)
