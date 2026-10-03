"""Wallet and ledger service: the single writer path for all coin changes (PRD 8.5).

Invariants kept by every function here:
  * sum(POSTED ledger amounts) == wallets.balance_cached
  * sum(open lot remaining) == balance_cached + deficit
  * no lot has negative remaining
Spendable coins are balance_cached; redemption is blocked while deficit > 0.
"""
import json
import uuid
from datetime import timedelta

from . import clock

EXCLUDED_FROM_CAPS = ("FIRST_WIN", "INVITE", "SURPRISE_BONUS", "HOUSEHOLD_GOAL")


def _months(n: int) -> timedelta:
    return timedelta(days=round(365 * n / 12))


def get_wallet(conn, owner_type: str, owner_id: int, lock: bool = False) -> dict:
    conn.execute(
        "INSERT INTO wallets (id, owner_type, owner_id) VALUES (%s,%s,%s) ON CONFLICT (owner_type, owner_id) DO NOTHING",
        (uuid.uuid4(), owner_type, owner_id))
    q = "SELECT * FROM wallets WHERE owner_type=%s AND owner_id=%s" + (" FOR UPDATE" if lock else "")
    return conn.execute(q, (owner_type, owner_id)).fetchone()


def lock_wallets(conn, wallet_ids) -> dict:
    """Lock wallet rows in id order to avoid deadlocks. Returns {id: row}."""
    out = {}
    for wid in sorted({str(w) for w in wallet_ids}):
        out[wid] = conn.execute("SELECT * FROM wallets WHERE id=%s FOR UPDATE", (wid,)).fetchone()
    return out


def _insert(conn, wallet_id, *, entry_type, amount, reason, key, cfg_version, status="POSTED", source_type=None,
            source_id=None, source_version=None, group_id=None, counterparty=None, reverses=None, metadata=None):
    return conn.execute(
        """INSERT INTO coin_ledger (id, wallet_id, entry_type, status, amount, reason_code, source_type, source_id,
               source_version, group_id, counterparty_user_id, reverses_entry_id, idempotency_key, config_version,
               metadata, created_at)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
           ON CONFLICT (idempotency_key) DO NOTHING RETURNING *""",
        (uuid.uuid4(), wallet_id, entry_type, status, amount, reason, source_type,
         None if source_id is None else str(source_id), source_version, group_id, counterparty, reverses, key,
         cfg_version, json.dumps(metadata or {}), clock.now())).fetchone()


def idem_key(rule: str, source_type: str, source_id, source_version, wallet_id) -> str:
    return f"{rule}:{source_type}:{source_id}:{source_version}:{wallet_id}"


def earn(conn, wallet: dict, *, amount: int, reason: str, source_type: str, source_id, source_version: int,
         cfg, rule: str | None = None, group_id=None, counterparty=None, metadata=None, pending=False):
    """Write an EARN. Returns the entry, or None if this idempotency key already exists."""
    if amount <= 0:
        return None
    key = idem_key(rule or reason.lower(), source_type, source_id, source_version, wallet["id"])
    entry = _insert(conn, wallet["id"], entry_type="EARN", amount=amount, reason=reason, key=key,
                    cfg_version=cfg.version, status="PENDING" if pending else "POSTED", source_type=source_type,
                    source_id=source_id, source_version=source_version, group_id=group_id,
                    counterparty=counterparty, metadata=metadata)
    if entry and not pending:
        _post_earn(conn, entry, cfg)
    return entry


def _post_earn(conn, entry: dict, cfg) -> None:
    w = conn.execute("SELECT * FROM wallets WHERE id=%s FOR UPDATE", (entry["wallet_id"],)).fetchone()
    pay = min(w["deficit"], entry["amount"])  # new earns first pay down the deficit
    conn.execute("UPDATE wallets SET balance_cached = balance_cached + %s, deficit = deficit - %s WHERE id=%s",
                 (entry["amount"], pay, w["id"]))
    earned_at = clock.now()
    conn.execute(
        """INSERT INTO coin_lots (id, wallet_id, earn_entry_id, earned_amount, remaining, earned_at, expires_at)
           VALUES (%s,%s,%s,%s,%s,%s,%s)""",
        (uuid.uuid4(), w["id"], entry["id"], entry["amount"], entry["amount"] - pay, earned_at,
         earned_at + _months(cfg["expiry_months"])))


def reverse(conn, entry: dict, *, reason: str, cfg, metadata=None):
    """Reverse an EARN/REFUND entry in full. Idempotent. Spent coins become wallet deficit."""
    if entry["status"] == "REJECTED":
        return None
    if entry["status"] == "PENDING":
        conn.execute("UPDATE coin_ledger SET status='REJECTED' WHERE id=%s AND status='PENDING'", (entry["id"],))
        return None
    rev = _insert(conn, entry["wallet_id"], entry_type="REVERSAL", amount=-entry["amount"],
                  reason=f"REVERSAL_{entry['reason_code']}", key=f"reversal:{entry['id']}", cfg_version=cfg.version,
                  source_type=entry["source_type"], source_id=entry["source_id"],
                  source_version=entry["source_version"], group_id=entry["group_id"],
                  counterparty=entry["counterparty_user_id"], reverses=entry["id"],
                  metadata={"why": reason, **(metadata or {})})
    if rev is None:
        return None
    conn.execute("SELECT id FROM wallets WHERE id=%s FOR UPDATE", (entry["wallet_id"],))
    lot = conn.execute("SELECT * FROM coin_lots WHERE earn_entry_id=%s FOR UPDATE", (entry["id"],)).fetchone()
    take = min(lot["remaining"], entry["amount"]) if lot else 0
    if lot and take:
        conn.execute("UPDATE coin_lots SET remaining = remaining - %s WHERE id=%s", (take, lot["id"]))
    shortfall = entry["amount"] - take
    conn.execute("UPDATE wallets SET balance_cached = balance_cached - %s, deficit = deficit + %s WHERE id=%s",
                 (entry["amount"], shortfall, entry["wallet_id"]))
    return rev


def reverse_source(conn, *, source_type: str, source_id, cfg, reason: str, max_version: int | None = None,
                   reason_codes: tuple | None = None, only_version: int | None = None) -> list:
    """Reverse every un-reversed EARN for a source (optionally only versions < max_version)."""
    q = ["""SELECT l.* FROM coin_ledger l WHERE l.source_type=%s AND l.source_id=%s AND l.entry_type='EARN'
            AND l.status IN ('POSTED','PENDING')
            AND NOT EXISTS (SELECT 1 FROM coin_ledger r WHERE r.reverses_entry_id = l.id)"""]
    args = [source_type, str(source_id)]
    if max_version is not None:
        q.append("AND l.source_version < %s")
        args.append(max_version)
    if only_version is not None:
        q.append("AND l.source_version = %s")
        args.append(only_version)
    if reason_codes:
        q.append("AND l.reason_code = ANY(%s)")
        args.append(list(reason_codes))
    q.append("ORDER BY l.wallet_id, l.created_at")
    out = []
    for e in conn.execute(" ".join(q), args).fetchall():
        r = reverse(conn, e, reason=reason, cfg=cfg)
        out.append((e, r))
    return out


def spend(conn, wallet_id, cost: int, *, redemption_id, cfg, reason="REDEMPTION") -> list:
    """Consume lots FIFO by expiry. Caller must hold the wallet lock and have checked the balance."""
    left = cost
    entries = []
    lots = conn.execute(
        "SELECT * FROM coin_lots WHERE wallet_id=%s AND remaining > 0 ORDER BY expires_at, earned_at FOR UPDATE",
        (wallet_id,)).fetchall()
    for lot in lots:
        if left == 0:
            break
        take = min(lot["remaining"], left)
        e = _insert(conn, wallet_id, entry_type="SPEND", amount=-take, reason=reason,
                    key=f"spend:{redemption_id}:{lot['id']}", cfg_version=cfg.version, source_type="REDEMPTION",
                    source_id=redemption_id, source_version=1, metadata={"lot_id": str(lot["id"])})
        if e is None:
            continue
        conn.execute("UPDATE coin_lots SET remaining = remaining - %s WHERE id=%s", (take, lot["id"]))
        left -= take
        entries.append(e)
    if left:
        raise ValueError("insufficient lots for spend")
    conn.execute("UPDATE wallets SET balance_cached = balance_cached - %s WHERE id=%s", (cost, wallet_id))
    return entries


def refund(conn, wallet_id, *, redemption_id, cfg) -> int:
    conn.execute("SELECT id FROM wallets WHERE id=%s FOR UPDATE", (wallet_id,))
    total = 0
    spends = conn.execute(
        "SELECT * FROM coin_ledger WHERE source_type='REDEMPTION' AND source_id=%s AND entry_type='SPEND' AND wallet_id=%s",
        (str(redemption_id), wallet_id)).fetchall()
    for s in spends:
        amt = -s["amount"]
        e = _insert(conn, wallet_id, entry_type="REFUND", amount=amt, reason="REDEMPTION_REFUND",
                    key=f"refund:{s['id']}", cfg_version=cfg.version, source_type="REDEMPTION",
                    source_id=redemption_id, source_version=1, metadata={"lot_id": s["metadata"].get("lot_id")})
        if e is None:
            continue
        conn.execute("UPDATE coin_lots SET remaining = remaining + %s WHERE id=%s", (amt, s["metadata"]["lot_id"]))
        total += amt
    conn.execute("UPDATE wallets SET balance_cached = balance_cached + %s WHERE id=%s", (total, wallet_id))
    return total


def expire_due(conn, cfg) -> int:
    n = 0
    lots = conn.execute(
        "SELECT * FROM coin_lots WHERE remaining > 0 AND expires_at <= %s ORDER BY wallet_id FOR UPDATE SKIP LOCKED",
        (clock.now(),)).fetchall()
    for lot in lots:
        conn.execute("SELECT id FROM wallets WHERE id=%s FOR UPDATE", (lot["wallet_id"],))
        e = _insert(conn, lot["wallet_id"], entry_type="EXPIRE", amount=-lot["remaining"], reason="EXPIRED",
                    key=f"expire:{lot['id']}", cfg_version=cfg.version, source_type="LOT", source_id=lot["id"],
                    source_version=1)
        if e is None:
            continue
        conn.execute("UPDATE coin_lots SET remaining = 0 WHERE id=%s", (lot["id"],))
        conn.execute("UPDATE wallets SET balance_cached = balance_cached - %s WHERE id=%s",
                     (lot["remaining"], lot["wallet_id"]))
        n += 1
    return n


def release_pending(conn, entry_id, cfg) -> dict | None:
    e = conn.execute("SELECT * FROM coin_ledger WHERE id=%s FOR UPDATE", (entry_id,)).fetchone()
    if not e or e["status"] != "PENDING":
        return None
    conn.execute("UPDATE coin_ledger SET status='POSTED' WHERE id=%s", (entry_id,))
    e["status"] = "POSTED"
    _post_earn(conn, e, cfg)
    return e


def reject_pending(conn, entry_id) -> bool:
    r = conn.execute("UPDATE coin_ledger SET status='REJECTED' WHERE id=%s AND status='PENDING' RETURNING id",
                     (entry_id,)).fetchone()
    return r is not None


def integrity(conn, wallet_id) -> dict | None:
    w = conn.execute("SELECT * FROM wallets WHERE id=%s", (wallet_id,)).fetchone()
    posted = conn.execute("SELECT COALESCE(SUM(amount),0) s FROM coin_ledger WHERE wallet_id=%s AND status='POSTED'",
                          (wallet_id,)).fetchone()["s"]
    lots = conn.execute("SELECT COALESCE(SUM(remaining),0) s, COALESCE(MIN(remaining),0) m FROM coin_lots WHERE wallet_id=%s",
                        (wallet_id,)).fetchone()
    problems = {}
    if posted != w["balance_cached"]:
        problems["balance"] = {"cached": w["balance_cached"], "ledger": int(posted)}
    if lots["s"] != w["balance_cached"] + w["deficit"]:
        problems["lots"] = {"lots": int(lots["s"]), "balance_plus_deficit": w["balance_cached"] + w["deficit"]}
    if lots["m"] < 0:
        problems["negative_lot"] = int(lots["m"])
    return problems or None


def rebuild_balance(conn, wallet_id) -> None:
    conn.execute("""UPDATE wallets SET balance_cached =
                    (SELECT COALESCE(SUM(amount),0) FROM coin_ledger WHERE wallet_id=%s AND status='POSTED')
                    WHERE id=%s""", (wallet_id, wallet_id))


def cap_sum(conn, wallet_id, start, end) -> int:
    """Coins counted toward user caps in a window (POSTED and PENDING earns; reversals do not free up cap room)."""
    r = conn.execute(
        """SELECT COALESCE(SUM(amount),0) s FROM coin_ledger
           WHERE wallet_id=%s AND entry_type='EARN' AND status IN ('POSTED','PENDING')
             AND NOT (reason_code = ANY(%s)) AND created_at >= %s AND created_at < %s""",
        (wallet_id, list(EXCLUDED_FROM_CAPS), start, end)).fetchone()
    return int(r["s"])
