"""Core splitting reads: expenses, confirmation state, balances.

Confirmation is a reward gate only (I-6): nothing here lets it change balances.
"""
from datetime import timedelta

from . import clock


def load_expense(conn, expense_id: int, lock: bool = False) -> dict | None:
    e = conn.execute("SELECT * FROM expenses WHERE id=%s" + (" FOR UPDATE" if lock else ""), (expense_id,)).fetchone()
    if e:
        e["splits"] = conn.execute("SELECT user_id, share_paise FROM expense_splits WHERE expense_id=%s ORDER BY user_id",
                                   (expense_id,)).fetchall()
    return e


def is_inr(expense: dict) -> bool:
    """Rewards are INR-only in the MVP (PRD 8.13): both the group and the typed currency must be INR."""
    return expense["currency"] == "INR" and (expense.get("original_currency") or "INR") == "INR"


def participants(expense: dict) -> set[int]:
    return {s["user_id"] for s in expense["splits"] if s["share_paise"] > 0} | {expense["paid_by"]}


def confirmations(conn, expense_id: int, version: int) -> list[dict]:
    return conn.execute(
        "SELECT * FROM expense_confirmations WHERE expense_id=%s AND expense_version=%s ORDER BY created_at, user_id",
        (expense_id, version)).fetchall()


def first_confirmed_at(conn, expense_id: int, version: int):
    r = conn.execute(
        """SELECT MIN(created_at) t FROM expense_confirmations
           WHERE expense_id=%s AND expense_version=%s AND status='CONFIRMED'""", (expense_id, version)).fetchone()
    return r["t"]


def expense_state(conn, expense: dict, cfg) -> dict:
    """Derived from confirmations of the current version (PRD 8.4)."""
    confs = confirmations(conn, expense["id"], expense["version"])
    confirmed = [c["user_id"] for c in confs if c["status"] == "CONFIRMED"]
    disputed = [{"user_id": c["user_id"], "reason": c["dispute_reason"], "note": c["note"]}
                for c in confs if c["status"] == "DISPUTED"]
    responded = {c["user_id"] for c in confs}
    can_confirm = sorted(participants(expense) - {expense["created_by"]})
    waiting = [u for u in can_confirm if u not in responded]
    if disputed:
        status = "DISPUTED"
    elif confirmed:
        status = "CONFIRMED"
    elif clock.now() - expense["created_at"] > timedelta(days=cfg["confirmation"]["expense_unconfirmed_label_after_days"]):
        status = "UNCONFIRMED"
    else:
        status = "WAITING"
    return {"status": status, "version": expense["version"], "confirmed_by": confirmed, "disputed_by": disputed,
            "waiting_on": waiting, "can_confirm": can_confirm}


def payment_state(conn, payment_id: int) -> dict | None:
    return conn.execute("SELECT * FROM payment_confirmations WHERE payment_id=%s", (payment_id,)).fetchone()


def pair_debts(conn, group_id: int, exclude_payment_id: int | None = None) -> dict[tuple[int, int], int]:
    """{(debtor, creditor): paise} net, positive only. No simplification across members."""
    raw: dict[tuple[int, int], int] = {}
    rows = conn.execute(
        """SELECT e.paid_by, s.user_id, s.share_paise FROM expenses e JOIN expense_splits s ON s.expense_id = e.id
           WHERE e.group_id=%s AND e.deleted_at IS NULL AND s.user_id <> e.paid_by""", (group_id,)).fetchall()
    for r in rows:
        raw[(r["user_id"], r["paid_by"])] = raw.get((r["user_id"], r["paid_by"]), 0) + r["share_paise"]
    pays = conn.execute("SELECT id, payer_id, receiver_id, amount_paise FROM payments WHERE group_id=%s AND deleted_at IS NULL",
                        (group_id,)).fetchall()
    for p in pays:
        if p["id"] == exclude_payment_id:
            continue
        k = (p["payer_id"], p["receiver_id"])
        raw[k] = raw.get(k, 0) - p["amount_paise"]
    net: dict[tuple[int, int], int] = {}
    for (a, b), v in raw.items():
        if (b, a) in net or (a, b) in net:
            continue
        diff = v - raw.get((b, a), 0)
        if diff > 0:
            net[(a, b)] = diff
        elif diff < 0:
            net[(b, a)] = -diff
    return net


def user_net(conn, group_id: int) -> dict[int, int]:
    """Per-user net in paise: positive = is owed, negative = owes."""
    out: dict[int, int] = {}
    for (a, b), v in pair_debts(conn, group_id).items():
        out[a] = out.get(a, 0) - v
        out[b] = out.get(b, 0) + v
    return out


def simplified_debts(conn, group_id: int) -> dict[tuple[int, int], int]:
    """Fewest payments that settle everyone: match the biggest debtor with the biggest creditor.

    Uses per-user nets, so totals are identical to pair_debts; only who-pays-whom changes.
    """
    net = {u: v for u, v in user_net(conn, group_id).items() if v}
    debtors = sorted(((u, -v) for u, v in net.items() if v < 0), key=lambda x: (-x[1], x[0]))
    creditors = sorted(((u, v) for u, v in net.items() if v > 0), key=lambda x: (-x[1], x[0]))
    out: dict[tuple[int, int], int] = {}
    i = j = 0
    debtors = [list(d) for d in debtors]
    creditors = [list(c) for c in creditors]
    while i < len(debtors) and j < len(creditors):
        pay = min(debtors[i][1], creditors[j][1])
        if pay > 0:
            out[(debtors[i][0], creditors[j][0])] = out.get((debtors[i][0], creditors[j][0]), 0) + pay
        debtors[i][1] -= pay
        creditors[j][1] -= pay
        if debtors[i][1] == 0:
            i += 1
        if creditors[j][1] == 0:
            j += 1
    return out


def group_debts(conn, group: dict) -> dict[tuple[int, int], int]:
    """What the app shows as "who owes whom": simplified if the group turned it on."""
    return simplified_debts(conn, group["id"]) if group.get("simplify_debts") else pair_debts(conn, group["id"])


def debt_age_start(conn, group_id: int, payer: int, receiver: int, before_payment: dict):
    """confirmed_at of the oldest unsettled confirmed expense where payer owes receiver (FIFO)."""
    exps = conn.execute(
        """SELECT e.id, e.version, s.share_paise FROM expenses e JOIN expense_splits s ON s.expense_id=e.id
           WHERE e.group_id=%s AND e.deleted_at IS NULL AND e.paid_by=%s AND s.user_id=%s AND s.share_paise > 0
             AND e.created_at <= %s
           ORDER BY e.created_at, e.id""", (group_id, receiver, payer, before_payment["created_at"])).fetchall()
    paid = conn.execute(
        """SELECT COALESCE(SUM(amount_paise),0) s FROM payments WHERE group_id=%s AND payer_id=%s AND receiver_id=%s
           AND deleted_at IS NULL AND id <> %s AND created_at <= %s""",
        (group_id, payer, receiver, before_payment["id"], before_payment["created_at"])).fetchone()["s"]
    for e in exps:
        if paid >= e["share_paise"]:
            paid -= e["share_paise"]
            continue
        paid = 0
        t = first_confirmed_at(conn, e["id"], e["version"])
        if t is not None:
            return t
    return None


def user_names(conn, ids) -> dict[int, str]:
    ids = list({i for i in ids if i is not None})
    if not ids:
        return {}
    return {r["id"]: (r["name"] or r["phone"][-4:]) for r in
            conn.execute("SELECT id, name, phone FROM users WHERE id = ANY(%s)", (ids,))}


def inr(paise: int) -> str:
    """en-IN formatting: INR 1,00,000 or INR 266.50."""
    neg = paise < 0
    rupees, p = divmod(abs(paise), 100)
    digits = str(rupees)
    head, tail = digits[:-3], digits[-3:]
    groups = []
    while len(head) > 2:
        groups.insert(0, head[-2:])
        head = head[:-2]
    if head:
        groups.insert(0, head)
    body = ",".join(groups + [tail]) if groups else tail
    return f"{'-' if neg else ''}INR {body}" + (f".{p:02d}" if p else "")


def last_pay_reminder(conn, group_id: int, creditor: int, debtor: int):
    """When the creditor last reminded the debtor to pay in this group (C5), or None."""
    r = conn.execute(
        """SELECT max(created_at) t FROM notifications WHERE notification_id='C5' AND group_id=%s AND user_id=%s
           AND payload->>'creditor_id' = %s""", (group_id, debtor, str(creditor))).fetchone()
    return r["t"] if r else None
