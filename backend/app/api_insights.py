"""Currency rates, spend insights and monthly reports."""
import csv
import io
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response

from . import categories, clock, db, domain, fx
from .deps import current_user, require_member

router = APIRouter(prefix="/api/v1")


# ---------------------------------------------------------------- currency

@router.get("/fx/currencies")
def currencies():
    return {"currencies": [{"code": c, "name": fx.NAMES[c], "symbol": fx.SYMBOLS.get(c), "digits": fx.digits(c)}
                           for c in fx.SUPPORTED]}


@router.get("/fx/rates")
def rates(base: str = "INR", user=Depends(current_user)):
    with db.tx() as conn:
        try:
            return fx.rates(conn, base)
        except fx.FxUnavailable as e:
            raise HTTPException(503, str(e))


# ---------------------------------------------------------------- helpers

def _month_bounds(month: str | None) -> tuple[date, datetime, datetime]:
    if month:
        try:
            y, m = (int(x) for x in month.split("-"))
            first = date(y, m, 1)
        except ValueError:
            raise HTTPException(400, "month must look like 2026-10")
    else:
        first = clock.ist().date().replace(day=1)
    start = datetime(first.year, first.month, 1, tzinfo=clock.IST)
    nxt = (start + timedelta(days=32)).replace(day=1)
    return first, start, nxt


def _prev_months(first: date, n: int) -> list[date]:
    out = [first]
    for _ in range(n - 1):
        p = (out[-1] - timedelta(days=1)).replace(day=1)
        out.append(p)
    return list(reversed(out))


def _month_expenses(conn, group_id, start, end):
    rows = conn.execute(
        """SELECT * FROM expenses WHERE group_id=%s AND deleted_at IS NULL AND created_at >= %s AND created_at < %s
           ORDER BY created_at""", (group_id, start, end)).fetchall()
    for r in rows:
        r["splits"] = conn.execute("SELECT user_id, share_paise FROM expense_splits WHERE expense_id=%s", (r["id"],)).fetchall()
    return rows


def group_insights(conn, group: dict, viewer_id: int, month: str | None) -> dict:
    gid, cur = group["id"], group["currency"]
    first, start, end = _month_bounds(month)
    exps = _month_expenses(conn, gid, start, end)
    member_ids = [r["user_id"] for r in conn.execute(
        "SELECT user_id FROM group_members WHERE group_id=%s ORDER BY joined_at", (gid,))]
    ids = set(member_ids)
    for e in exps:
        ids |= {e["paid_by"]} | {s["user_id"] for s in e["splits"]}
    names = domain.user_names(conn, ids)
    paid = {u: 0 for u in ids}
    share = {u: 0 for u in ids}
    count = {u: 0 for u in ids}
    cats: dict[str, int] = {}
    total = 0
    for e in exps:
        total += e["amount_paise"]
        paid[e["paid_by"]] += e["amount_paise"]
        count[e["paid_by"]] += 1
        for s in e["splits"]:
            share[s["user_id"]] += s["share_paise"]
        cats[e["category"]] = cats.get(e["category"], 0) + e["amount_paise"]
    pays = conn.execute(
        """SELECT * FROM payments WHERE group_id=%s AND deleted_at IS NULL AND created_at >= %s AND created_at < %s""",
        (gid, start, end)).fetchall()
    settled = {u: 0 for u in ids}
    for p in pays:
        settled[p["payer_id"]] = settled.get(p["payer_id"], 0) + p["amount_paise"]
    # 6-month trend: group total and the viewer's share
    trend = []
    for m in _prev_months(first, 6):
        ms = datetime(m.year, m.month, 1, tzinfo=clock.IST)
        me = (ms + timedelta(days=32)).replace(day=1)
        row = conn.execute(
            """SELECT COALESCE(SUM(e.amount_paise),0) total,
                      COALESCE(SUM((SELECT share_paise FROM expense_splits s WHERE s.expense_id=e.id AND s.user_id=%s)),0) mine
               FROM expenses e WHERE e.group_id=%s AND e.deleted_at IS NULL AND e.created_at >= %s AND e.created_at < %s""",
            (viewer_id, gid, ms, me)).fetchone()
        trend.append({"month": m.strftime("%Y-%m"), "label": m.strftime("%b"), "total": int(row["total"]),
                      "my_share": int(row["mine"])})
    today = clock.ist().date()
    days = today.day if (today.year, today.month) == (first.year, first.month) else (end - start).days
    top = sorted(exps, key=lambda e: -e["amount_paise"])[:5]
    members = []
    for u in member_ids + sorted(ids - set(member_ids)):
        members.append({"user_id": u, "name": names.get(u), "is_you": u == viewer_id, "paid": paid.get(u, 0),
                        "share": share.get(u, 0), "net": paid.get(u, 0) - share.get(u, 0),
                        "settled": settled.get(u, 0), "expenses_added": count.get(u, 0),
                        "share_pct": round(100 * share.get(u, 0) / total, 1) if total else 0})
    return {
        "group_id": gid, "group_name": group["name"], "currency": cur, "month": first.strftime("%Y-%m"),
        "month_label": first.strftime("%B %Y"), "total_spend": total, "expense_count": len(exps),
        "daily_average": total // days if total else 0,
        "members": members,
        "categories": [{"category": c, "label": categories.CATEGORIES.get(c, c.title()), "amount": a,
                        "pct": round(100 * a / total, 1) if total else 0}
                       for c, a in sorted(cats.items(), key=lambda kv: -kv[1])],
        "trend": trend,
        "top_expenses": [{"id": e["id"], "description": e["description"], "amount": e["amount_paise"],
                          "category": e["category"], "paid_by_name": names.get(e["paid_by"]),
                          "created_at": e["created_at"].isoformat()} for e in top],
        "you": next((m for m in members if m["is_you"]), None),
    }


@router.get("/groups/{group_id}/insights")
def insights(group_id: int, month: str | None = None, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        return group_insights(conn, g, user["id"], month)


@router.get("/me/insights")
def my_insights(month: str | None = None, currency: str = "INR", user=Depends(current_user)):
    """My share of spending across all groups, converted to one display currency at live rates."""
    currency = currency.upper()
    if currency not in fx.SUPPORTED:
        raise HTTPException(400, "Unsupported currency")
    with db.tx() as conn:
        first, start, end = _month_bounds(month)
        groups = conn.execute(
            """SELECT g.* FROM groups g JOIN group_members m ON m.group_id=g.id WHERE m.user_id=%s""",
            (user["id"],)).fetchall()
        try:
            live = {g["currency"]: fx.rate(conn, g["currency"], currency) for g in groups}
        except fx.FxUnavailable as e:
            raise HTTPException(503, str(e))
        by_group, by_cat = [], {}
        total = paid_total = 0
        trend = {m.strftime("%Y-%m"): 0 for m in _prev_months(first, 6)}
        for g in groups:
            r = live[g["currency"]]
            rows = conn.execute(
                """SELECT e.category, e.amount_paise, e.paid_by, s.share_paise FROM expenses e
                   JOIN expense_splits s ON s.expense_id=e.id AND s.user_id=%s
                   WHERE e.group_id=%s AND e.deleted_at IS NULL AND e.created_at >= %s AND e.created_at < %s""",
                (user["id"], g["id"], start, end)).fetchall()
            g_share = sum(x["share_paise"] for x in rows)
            g_paid = conn.execute(
                """SELECT COALESCE(SUM(amount_paise),0) s FROM expenses WHERE group_id=%s AND paid_by=%s
                   AND deleted_at IS NULL AND created_at >= %s AND created_at < %s""",
                (g["id"], user["id"], start, end)).fetchone()["s"]
            conv_share = fx.convert_minor(g_share, g["currency"], currency, r)
            conv_paid = fx.convert_minor(int(g_paid), g["currency"], currency, r)
            total += conv_share
            paid_total += conv_paid
            for x in rows:
                c = fx.convert_minor(x["share_paise"], g["currency"], currency, r)
                by_cat[x["category"]] = by_cat.get(x["category"], 0) + c
            if g_share or g_paid:
                by_group.append({"group_id": g["id"], "group_name": g["name"], "group_currency": g["currency"],
                                 "share": conv_share, "share_in_group_currency": g_share, "paid": conv_paid})
            for m in trend:
                y, mo = (int(v) for v in m.split("-"))
                ms = datetime(y, mo, 1, tzinfo=clock.IST)
                me = (ms + timedelta(days=32)).replace(day=1)
                s = conn.execute(
                    """SELECT COALESCE(SUM(s.share_paise),0) v FROM expenses e JOIN expense_splits s
                       ON s.expense_id=e.id AND s.user_id=%s WHERE e.group_id=%s AND e.deleted_at IS NULL
                       AND e.created_at >= %s AND e.created_at < %s""", (user["id"], g["id"], ms, me)).fetchone()["v"]
                trend[m] += fx.convert_minor(int(s), g["currency"], currency, r)
        return {"currency": currency, "month": first.strftime("%Y-%m"), "month_label": first.strftime("%B %Y"),
                "total_share": total, "total_paid": paid_total,
                "by_group": sorted(by_group, key=lambda x: -x["share"]),
                "categories": [{"category": c, "label": categories.CATEGORIES.get(c, c.title()), "amount": a,
                                "pct": round(100 * a / total, 1) if total else 0}
                               for c, a in sorted(by_cat.items(), key=lambda kv: -kv[1])],
                "trend": [{"month": m, "label": date(int(m[:4]), int(m[5:]), 1).strftime("%b"), "my_share": v}
                          for m, v in trend.items()]}


# ---------------------------------------------------------------- reports

def _major(minor: int, cur: str) -> str:
    d = fx.digits(cur)
    return f"{minor / 10 ** d:.{d}f}"


@router.get("/groups/{group_id}/report")
def report(group_id: int, month: str | None = None, user=Depends(current_user)):
    """Monthly statement as CSV: every expense with each member's share, payments, and a summary."""
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        cur = g["currency"]
        first, start, end = _month_bounds(month)
        ins = group_insights(conn, g, user["id"], month)
        exps = _month_expenses(conn, group_id, start, end)
        member_ids = [m["user_id"] for m in ins["members"]]
        names = {m["user_id"]: m["name"] for m in ins["members"]}
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow([f"{g['name']} statement", ins["month_label"], f"Amounts in {cur}"])
        w.writerow([])
        w.writerow(["Date", "Description", "Category", "Paid by", f"Amount ({cur})", "Original amount", "Split"]
                   + [f"{names[u]} share" for u in member_ids])
        for e in exps:
            shares = {s["user_id"]: s["share_paise"] for s in e["splits"]}
            orig = (f"{e['original_currency']} {_major(e['original_amount_minor'], e['original_currency'])} "
                    f"@ {float(e['fx_rate']):.4f}") if e["original_currency"] else ""
            w.writerow([clock.ist(e["created_at"]).strftime("%Y-%m-%d"), e["description"],
                        categories.CATEGORIES.get(e["category"], e["category"]), names.get(e["paid_by"], ""),
                        _major(e["amount_paise"], cur), orig, e["split_type"].title()]
                       + [_major(shares.get(u, 0), cur) for u in member_ids])
        w.writerow([])
        w.writerow(["Payments"])
        w.writerow(["Date", "From", "To", f"Amount ({cur})", "Receipt"])
        for p in conn.execute(
                """SELECT p.*, pc.status FROM payments p LEFT JOIN payment_confirmations pc ON pc.payment_id=p.id
                   WHERE p.group_id=%s AND p.deleted_at IS NULL AND p.created_at >= %s AND p.created_at < %s
                   ORDER BY p.created_at""", (group_id, start, end)):
            w.writerow([clock.ist(p["created_at"]).strftime("%Y-%m-%d"), names.get(p["payer_id"], ""),
                        names.get(p["receiver_id"], ""), _major(p["amount_paise"], cur), (p["status"] or "").title()])
        w.writerow([])
        w.writerow(["Summary", "Paid", "Share", "Net for the month", "Share %"])
        for m in ins["members"]:
            w.writerow([m["name"], _major(m["paid"], cur), _major(m["share"], cur), _major(m["net"], cur),
                        f"{m['share_pct']}%"])
        w.writerow(["Total", _major(ins["total_spend"], cur)])
        w.writerow([])
        w.writerow(["Outstanding balances today"])
        for (a, b), v in domain.pair_debts(conn, group_id).items():
            w.writerow([f"{domain.user_names(conn, [a]).get(a)} owes {domain.user_names(conn, [b]).get(b)}",
                        _major(v, cur)])
        fname = f"{g['name'].replace(' ', '_')}_{ins['month']}.csv"
        return Response(content=buf.getvalue(), media_type="text/csv",
                        headers={"Content-Disposition": f'attachment; filename="{fname}"'})
