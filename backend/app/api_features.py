"""Everyday Splitwise features: recurring bills, group settings and members, comments, receipts,
search, budgets, activity feed, group chat and device registration."""
import json
import pathlib
import uuid
from datetime import date, datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from . import analytics, categories, clock, coin_config, db, domain, events, experiment, fx, i18n, notify, views
from .api_core import ExpenseIn, _norm_phone, create_expense
from .deps import current_user, require_member

router = APIRouter(prefix="/api/v1")
UPLOADS = pathlib.Path(__file__).resolve().parent.parent / "uploads"
MAX_UPLOAD = 6 * 1024 * 1024
IMAGE_TYPES = {"image/jpeg": ".jpg", "image/png": ".png", "image/heic": ".heic", "application/pdf": ".pdf"}


def _user_locale(conn, uid) -> str:
    r = conn.execute("SELECT locale FROM users WHERE id=%s", (uid,)).fetchone()
    return r["locale"] if r else "en"


# ---------------------------------------------------------------- recurring bills (FR-16)

class RecurringIn(BaseModel):
    expense: ExpenseIn
    frequency: str = "MONTHLY"           # MONTHLY or WEEKLY
    day: int | None = None               # 1-28 for monthly, 0 (Mon) - 6 for weekly
    start: date | None = None            # first date to add it; defaults to the next matching day


def next_date(frequency: str, day: int, after: date) -> date:
    """First date >= `after` that matches the schedule."""
    if frequency == "WEEKLY":
        return after + timedelta(days=(day - after.weekday()) % 7)
    d = after.replace(day=day) if after.day <= day else (after.replace(day=1) + timedelta(days=32)).replace(day=day)
    return d


def _recurring_json(conn, r) -> dict:
    names = domain.user_names(conn, [r["paid_by"], r["created_by"]])
    return {"id": str(r["id"]), "group_id": r["group_id"], "description": r["description"],
            "amount_minor": r["amount_minor"], "currency": r["currency"], "paid_by": r["paid_by"],
            "paid_by_name": names.get(r["paid_by"]), "split_type": r["split_type"], "category": r["category"],
            "frequency": r["frequency"], "day": r["day"], "next_run": r["next_run"].isoformat(),
            "last_run": r["last_run"].isoformat() if r["last_run"] else None, "active": r["active"],
            "created_by_name": names.get(r["created_by"])}


@router.post("/groups/{group_id}/recurring")
def create_recurring(group_id: int, body: RecurringIn, user=Depends(current_user)):
    freq = body.frequency.upper()
    if freq not in ("MONTHLY", "WEEKLY"):
        raise HTTPException(400, "frequency must be MONTHLY or WEEKLY")
    today = clock.ist().date()
    day = body.day if body.day is not None else ((body.start or today).day if freq == "MONTHLY" else (body.start or today).weekday())
    if freq == "MONTHLY" and not 1 <= day <= 28:
        raise HTTPException(400, "Pick a day between 1 and 28 so it works every month")
    if freq == "WEEKLY" and not 0 <= day <= 6:
        raise HTTPException(400, "Weekday must be 0 (Mon) to 6 (Sun)")
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        e = body.expense
        # validate the template once by computing its split now
        from .api_core import _resolve_split
        members = set(experiment.active_member_ids(conn, group_id))
        if (e.paid_by or user["id"]) not in members:
            raise HTTPException(400, "Payer must be in the group")
        split_type, _, _ = _resolve_split(e, e.amount_paise, members)
        nxt = next_date(freq, day, body.start or today)
        r = conn.execute(
            """INSERT INTO recurring_expenses (id, group_id, created_by, description, amount_minor, currency, paid_by,
                   split_type, split_input, category, frequency, day, next_run, created_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (uuid.uuid4(), group_id, user["id"], e.description.strip(), e.amount_paise,
             (e.currency or g["currency"]).upper(), e.paid_by or user["id"], split_type,
             json.dumps(e.model_dump(exclude={"description", "amount_paise", "currency", "paid_by", "category"},
                                     exclude_none=True)),
             categories.normalize(e.category, e.description), freq, day, nxt, clock.now())).fetchone()
        return _recurring_json(conn, r)


@router.get("/groups/{group_id}/recurring")
def list_recurring(group_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        require_member(conn, group_id, user["id"])
        rows = conn.execute("SELECT * FROM recurring_expenses WHERE group_id=%s AND active ORDER BY next_run",
                            (group_id,)).fetchall()
        return {"recurring": [_recurring_json(conn, r) for r in rows]}


class RecurringPatch(BaseModel):
    active: bool | None = None
    amount_minor: int | None = Field(default=None, gt=0)
    day: int | None = None


@router.patch("/recurring/{rid}")
def update_recurring(rid: str, body: RecurringPatch, user=Depends(current_user)):
    with db.tx() as conn:
        r = conn.execute("SELECT * FROM recurring_expenses WHERE id=%s FOR UPDATE", (rid,)).fetchone()
        if not r:
            raise HTTPException(404, "Not found")
        require_member(conn, r["group_id"], user["id"])
        if body.active is not None:
            conn.execute("UPDATE recurring_expenses SET active=%s WHERE id=%s", (body.active, rid))
        if body.amount_minor:
            conn.execute("UPDATE recurring_expenses SET amount_minor=%s WHERE id=%s", (body.amount_minor, rid))
        if body.day is not None:
            ok = 1 <= body.day <= 28 if r["frequency"] == "MONTHLY" else 0 <= body.day <= 6
            if not ok:
                raise HTTPException(400, "Invalid day")
            conn.execute("UPDATE recurring_expenses SET day=%s, next_run=%s WHERE id=%s",
                         (body.day, next_date(r["frequency"], body.day, clock.ist().date()), rid))
        return _recurring_json(conn, conn.execute("SELECT * FROM recurring_expenses WHERE id=%s", (rid,)).fetchone())


def run_recurring() -> int:
    """Worker job: add due recurring bills (IST dates) and remind the day before."""
    made = 0
    today = clock.ist().date()
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        due = conn.execute("SELECT * FROM recurring_expenses WHERE active AND next_run <= %s FOR UPDATE SKIP LOCKED",
                           (today,)).fetchall()
        for r in due:
            g = conn.execute("SELECT * FROM groups WHERE id=%s", (r["group_id"],)).fetchone()
            body = ExpenseIn(description=r["description"], amount_paise=r["amount_minor"], currency=r["currency"],
                             paid_by=r["paid_by"], category=r["category"], **r["split_input"])
            try:
                with conn.transaction():
                    create_expense(conn, g, r["created_by"], body, recurring_id=r["id"])
                made += 1
            except HTTPException as e:   # e.g. someone left the group: tell the creator, keep the schedule
                notify.enqueue(conn, cfg, user_id=r["created_by"], nid="C1", group_id=g["id"],
                               title=i18n.t(_user_locale(conn, r["created_by"]), "recurring_failed_title"),
                               body=i18n.t(_user_locale(conn, r["created_by"]), "recurring_failed",
                                           desc=r["description"], reason=e.detail),
                               dedupe_key=f"C1-fail:{r['id']}:{r['next_run']}", payload={"group_id": g["id"]})
            conn.execute("UPDATE recurring_expenses SET last_run=%s, next_run=%s WHERE id=%s",
                         (r["next_run"], next_date(r["frequency"], r["day"], r["next_run"] + timedelta(days=1)), r["id"]))
        # heads-up the day before, so whoever owes can plan the payment
        tomorrow = today + timedelta(days=1)
        for r in conn.execute("SELECT * FROM recurring_expenses WHERE active AND next_run = %s", (tomorrow,)).fetchall():
            members = experiment.active_member_ids(conn, r["group_id"])
            for uid in members:
                loc = _user_locale(conn, uid)
                notify.enqueue(conn, cfg, user_id=uid, nid="C1", group_id=r["group_id"],
                               title=i18n.t(loc, "recurring_soon_title"),
                               body=i18n.t(loc, "recurring_soon", desc=r["description"],
                                           amount=fx.fmt(r["amount_minor"], r["currency"])),
                               dedupe_key=f"C1-soon:{r['id']}:{tomorrow}:{uid}",
                               payload={"group_id": r["group_id"]},
                               deliver_after=max(clock.now(), datetime(today.year, today.month, today.day, 10, tzinfo=clock.IST)))
    return made


# ---------------------------------------------------------------- group settings & members

class GroupPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=60)
    simplify_debts: bool | None = None
    currency: str | None = None
    default_split: dict | None = None     # {"split_type": "PERCENT", "percents": {...}} or {} to clear
    expected_members: int | None = Field(default=None, ge=1, le=12)


@router.patch("/groups/{group_id}")
def update_group(group_id: int, body: GroupPatch, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        if body.name:
            conn.execute("UPDATE groups SET name=%s WHERE id=%s", (body.name.strip(), group_id))
        if body.simplify_debts is not None:
            conn.execute("UPDATE groups SET simplify_debts=%s WHERE id=%s", (body.simplify_debts, group_id))
        if body.expected_members is not None:
            conn.execute("UPDATE groups SET expected_members=%s WHERE id=%s", (body.expected_members, group_id))
        if body.currency and body.currency.upper() != g["currency"]:
            if body.currency.upper() not in fx.SUPPORTED:
                raise HTTPException(400, "Unsupported currency")
            has = conn.execute("SELECT 1 FROM expenses WHERE group_id=%s AND deleted_at IS NULL LIMIT 1", (group_id,)).fetchone() \
                or conn.execute("SELECT 1 FROM payments WHERE group_id=%s AND deleted_at IS NULL LIMIT 1", (group_id,)).fetchone()
            if has:
                raise HTTPException(409, "Currency can only change before the first expense")
            conn.execute("UPDATE groups SET currency=%s WHERE id=%s", (body.currency.upper(), group_id))
        if body.default_split is not None:
            ds = body.default_split or None
            if ds and ds.get("split_type", "").upper() not in ("EQUAL", "PERCENT", "SHARES"):
                raise HTTPException(400, "Default split must be equal, percent or shares")
            conn.execute("UPDATE groups SET default_split=%s WHERE id=%s", (json.dumps(ds) if ds else None, group_id))
        g = conn.execute("SELECT * FROM groups WHERE id=%s", (group_id,)).fetchone()
        return {"id": g["id"], "name": domain.display_name(conn, g, user["id"]), "currency": g["currency"], "simplify_debts": g["simplify_debts"],
                "default_split": g["default_split"], "expected_members": g["expected_members"]}


@router.delete("/groups/{group_id}/members/{member_id}")
def remove_member(group_id: int, member_id: int, user=Depends(current_user)):
    """Leave (yourself) or remove someone (group creator). Only once their balance is settled."""
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        if member_id != user["id"] and g["created_by"] != user["id"]:
            raise HTTPException(403, "Only the person who created the group can remove members")
        if member_id == g["created_by"] and member_id != user["id"]:
            raise HTTPException(403, "The group creator can't be removed")
        m = conn.execute("SELECT 1 FROM group_members WHERE group_id=%s AND user_id=%s AND left_at IS NULL",
                         (group_id, member_id)).fetchone()
        if not m:
            raise HTTPException(404, "Not a member")
        net = domain.user_net(conn, group_id).get(member_id, 0)
        if net != 0:
            who = "You have" if member_id == user["id"] else "They have"
            raise HTTPException(409, f"{who} an open balance of {fx.fmt(abs(net), g['currency'])}. Settle up first.")
        conn.execute("UPDATE group_members SET left_at=%s WHERE group_id=%s AND user_id=%s", (clock.now(), group_id, member_id))
        conn.execute("UPDATE recurring_expenses SET active=false WHERE group_id=%s AND paid_by=%s", (group_id, member_id))
        events.emit(conn, "MemberLeft", group_id=group_id, user_id=member_id)
    return {"ok": True}


# ---------------------------------------------------------------- comments

class CommentIn(BaseModel):
    body: str = Field(min_length=1, max_length=500)


def _expense_for(conn, expense_id, uid):
    e = domain.load_expense(conn, expense_id)
    if not e or e["deleted_at"]:
        raise HTTPException(404, "Expense not found")
    require_member(conn, e["group_id"], uid)
    return e


@router.get("/expenses/{expense_id}/comments")
def list_comments(expense_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        _expense_for(conn, expense_id, user["id"])
        rows = conn.execute("SELECT * FROM expense_comments WHERE expense_id=%s AND deleted_at IS NULL ORDER BY created_at",
                            (expense_id,)).fetchall()
        names = domain.user_names(conn, [r["user_id"] for r in rows])
        return {"comments": [{"id": str(r["id"]), "user_id": r["user_id"], "name": names.get(r["user_id"]),
                              "is_you": r["user_id"] == user["id"], "body": r["body"],
                              "created_at": r["created_at"].isoformat()} for r in rows]}


@router.post("/expenses/{expense_id}/comments")
def add_comment(expense_id: int, body: CommentIn, user=Depends(current_user)):
    with db.tx() as conn:
        e = _expense_for(conn, expense_id, user["id"])
        cid = uuid.uuid4()
        conn.execute("INSERT INTO expense_comments (id, expense_id, user_id, body, created_at) VALUES (%s,%s,%s,%s,%s)",
                     (cid, expense_id, user["id"], body.body.strip(), clock.now()))
        cfg = coin_config.current(conn)
        for uid in (domain.participants(e) | {e["created_by"]}) - {user["id"]}:
            notify.enqueue(conn, cfg, user_id=uid, nid="C2", group_id=e["group_id"],
                           title=e["description"], body=f"{user['name']}: {body.body.strip()[:120]}",
                           dedupe_key=f"C2:{cid}:{uid}", payload={"expense_id": expense_id, "group_id": e["group_id"]})
    return list_comments(expense_id, user)


@router.delete("/comments/{cid}")
def delete_comment(cid: str, user=Depends(current_user)):
    with db.tx() as conn:
        r = conn.execute("UPDATE expense_comments SET deleted_at=%s WHERE id=%s AND user_id=%s AND deleted_at IS NULL RETURNING id",
                         (clock.now(), cid, user["id"])).fetchone()
        if not r:
            raise HTTPException(404, "Comment not found")
    return {"ok": True}


# ---------------------------------------------------------------- receipts

@router.post("/expenses/{expense_id}/attachments")
async def upload_attachment(expense_id: int, request: Request, user=Depends(current_user)):
    ctype = (request.headers.get("content-type") or "").split(";")[0].strip().lower()
    if ctype not in IMAGE_TYPES:
        raise HTTPException(415, "Upload a JPEG, PNG, HEIC or PDF")
    data = await request.body()
    if not data:
        raise HTTPException(400, "Empty file")
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "File is larger than 6 MB")
    with db.tx() as conn:
        e = _expense_for(conn, expense_id, user["id"])
        aid = uuid.uuid4()
        UPLOADS.mkdir(parents=True, exist_ok=True)
        rel = f"{e['group_id']}/{aid}{IMAGE_TYPES[ctype]}"
        (UPLOADS / str(e["group_id"])).mkdir(parents=True, exist_ok=True)
        (UPLOADS / rel).write_bytes(data)
        conn.execute("""INSERT INTO expense_attachments (id, expense_id, user_id, path, content_type, bytes, created_at)
                        VALUES (%s,%s,%s,%s,%s,%s,%s)""", (aid, expense_id, user["id"], rel, ctype, len(data), clock.now()))
    return {"id": str(aid), "content_type": ctype, "bytes": len(data)}


@router.get("/expenses/{expense_id}/attachments")
def list_attachments(expense_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        _expense_for(conn, expense_id, user["id"])
        rows = conn.execute("SELECT * FROM expense_attachments WHERE expense_id=%s ORDER BY created_at", (expense_id,)).fetchall()
        return {"attachments": [{"id": str(r["id"]), "content_type": r["content_type"], "bytes": r["bytes"],
                                 "created_at": r["created_at"].isoformat()} for r in rows]}


@router.get("/attachments/{aid}")
def get_attachment(aid: str, user=Depends(current_user)):
    with db.tx() as conn:
        r = conn.execute("SELECT a.*, e.group_id FROM expense_attachments a JOIN expenses e ON e.id=a.expense_id WHERE a.id=%s",
                         (aid,)).fetchone()
        if not r:
            raise HTTPException(404, "Not found")
        require_member(conn, r["group_id"], user["id"])
    return FileResponse(UPLOADS / r["path"], media_type=r["content_type"])


@router.delete("/attachments/{aid}")
def delete_attachment(aid: str, user=Depends(current_user)):
    with db.tx() as conn:
        r = conn.execute("DELETE FROM expense_attachments WHERE id=%s AND user_id=%s RETURNING path", (aid, user["id"])).fetchone()
        if not r:
            raise HTTPException(404, "Not found")
    (UPLOADS / r["path"]).unlink(missing_ok=True)
    return {"ok": True}


# ---------------------------------------------------------------- search

@router.get("/groups/{group_id}/search")
def search(group_id: int, q: str = "", category: str | None = None, member: int | None = None,
           month: str | None = None, min_amount: int | None = None, max_amount: int | None = None,
           user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        where = ["e.group_id=%s", "e.deleted_at IS NULL"]
        args: list = [group_id]
        if q.strip():
            where.append("(e.description ILIKE %s OR EXISTS (SELECT 1 FROM expense_comments c WHERE c.expense_id=e.id AND c.body ILIKE %s AND c.deleted_at IS NULL))")
            args += [f"%{q.strip()}%", f"%{q.strip()}%"]
        if category:
            where.append("e.category=%s"); args.append(category)
        if member:
            where.append("(e.paid_by=%s OR EXISTS (SELECT 1 FROM expense_splits s WHERE s.expense_id=e.id AND s.user_id=%s AND s.share_paise>0))")
            args += [member, member]
        if month:
            y, m = (int(x) for x in month.split("-"))
            start = datetime(y, m, 1, tzinfo=clock.IST)
            where.append("e.created_at >= %s AND e.created_at < %s"); args += [start, (start + timedelta(days=32)).replace(day=1)]
        if min_amount is not None:
            where.append("e.amount_paise >= %s"); args.append(min_amount)
        if max_amount is not None:
            where.append("e.amount_paise <= %s"); args.append(max_amount)
        rows = conn.execute(f"SELECT e.id FROM expenses e WHERE {' AND '.join(where)} ORDER BY e.created_at DESC LIMIT 100",
                            args).fetchall()
        exps = [domain.load_expense(conn, r["id"]) for r in rows]
        ids = set()
        for e in exps:
            ids |= {e["paid_by"], e["created_by"]} | {s["user_id"] for s in e["splits"]}
        names = domain.user_names(conn, ids)
        cfg = coin_config.current(conn)
        eligible = views.eligible(conn, group_id, cfg) and not user["hide_coins"]
        return {"total": sum(e["amount_paise"] for e in exps), "currency": g["currency"],
                "expenses": [views.expense_json(conn, user["id"], e, names, cfg, eligible) for e in exps]}


# ---------------------------------------------------------------- budgets

class BudgetsIn(BaseModel):
    budgets: dict[str, int]   # category -> monthly limit in minor units (0 removes)


def budget_status(conn, group: dict) -> list[dict]:
    start = datetime(clock.ist().year, clock.ist().month, 1, tzinfo=clock.IST)
    end = (start + timedelta(days=32)).replace(day=1)
    out = []
    for b in conn.execute("SELECT * FROM group_budgets WHERE group_id=%s ORDER BY category", (group["id"],)):
        spent = conn.execute(
            """SELECT COALESCE(SUM(amount_paise),0) s FROM expenses WHERE group_id=%s AND category=%s AND deleted_at IS NULL
               AND created_at >= %s AND created_at < %s""", (group["id"], b["category"], start, end)).fetchone()["s"]
        out.append({"category": b["category"], "label": categories.CATEGORIES.get(b["category"], b["category"]),
                    "limit": b["monthly_limit"], "spent": int(spent),
                    "pct": round(100 * int(spent) / b["monthly_limit"], 1)})
    return out


@router.get("/groups/{group_id}/budgets")
def get_budgets(group_id: int, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        return {"currency": g["currency"], "budgets": budget_status(conn, g)}


@router.put("/groups/{group_id}/budgets")
def put_budgets(group_id: int, body: BudgetsIn, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        for cat, limit in body.budgets.items():
            if cat not in categories.CATEGORIES:
                raise HTTPException(400, f"Unknown category {cat}")
            if limit <= 0:
                conn.execute("DELETE FROM group_budgets WHERE group_id=%s AND category=%s", (group_id, cat))
            else:
                conn.execute("""INSERT INTO group_budgets (group_id, category, monthly_limit, updated_by, updated_at)
                                VALUES (%s,%s,%s,%s,%s) ON CONFLICT (group_id, category)
                                DO UPDATE SET monthly_limit=EXCLUDED.monthly_limit, updated_by=EXCLUDED.updated_by,
                                updated_at=EXCLUDED.updated_at""", (group_id, cat, limit, user["id"], clock.now()))
        return {"currency": g["currency"], "budgets": budget_status(conn, g)}


def check_budgets(conn, group_id: int) -> None:
    """Notify the group once at 80% and once at 100% of a category budget each month."""
    g = conn.execute("SELECT * FROM groups WHERE id=%s", (group_id,)).fetchone()
    cfg = coin_config.current(conn)
    month = clock.ist().strftime("%Y-%m")
    for b in budget_status(conn, g):
        for threshold in (80, 100):
            if b["pct"] >= threshold:
                for uid in experiment.active_member_ids(conn, group_id):
                    loc = _user_locale(conn, uid)
                    notify.enqueue(conn, cfg, user_id=uid, nid="C4", group_id=group_id,
                                   title=i18n.t(loc, "budget_title", label=b["label"]),
                                   body=i18n.t(loc, "budget_over" if threshold == 100 else "budget_near", label=b["label"],
                                               spent=fx.fmt(b["spent"], g["currency"]), limit=fx.fmt(b["limit"], g["currency"])),
                                   dedupe_key=f"C4:{group_id}:{b['category']}:{month}:{threshold}:{uid}",
                                   payload={"group_id": group_id, "route": "insights"})


def check_all_budgets() -> None:
    with db.tx() as conn:
        for r in conn.execute("SELECT DISTINCT group_id FROM group_budgets").fetchall():
            check_budgets(conn, r["group_id"])


# ---------------------------------------------------------------- activity feed

@router.get("/me/activity")
def activity(limit: int = 60, user=Depends(current_user)):
    uid = user["id"]
    with db.tx() as conn:
        since = clock.now() - timedelta(days=60)
        gids = [r["group_id"] for r in conn.execute("SELECT group_id FROM group_members WHERE user_id=%s", (uid,))]
        if not gids:
            return {"items": []}
        groups = {r["id"]: r for r in conn.execute("SELECT * FROM groups WHERE id = ANY(%s)", (gids,))}
        items = []
        for e in conn.execute(
                """SELECT e.*, (SELECT share_paise FROM expense_splits s WHERE s.expense_id=e.id AND s.user_id=%s) my_share
                   FROM expenses e WHERE e.group_id = ANY(%s) AND e.created_at > %s ORDER BY e.created_at DESC LIMIT 200""",
                (uid, gids, since)):
            items.append({"kind": "EXPENSE_DELETED" if e["deleted_at"] else "EXPENSE", "at": e["created_at"],
                          "actor_id": e["created_by"], "group_id": e["group_id"], "expense_id": e["id"],
                          "title": e["description"], "amount": e["amount_paise"], "my_share": e["my_share"] or 0,
                          "paid_by": e["paid_by"], "recurring": e["recurring_id"] is not None})
        for p in conn.execute("""SELECT p.*, pc.status FROM payments p LEFT JOIN payment_confirmations pc ON pc.payment_id=p.id
                                 WHERE p.group_id = ANY(%s) AND p.created_at > %s AND p.deleted_at IS NULL""", (gids, since)):
            items.append({"kind": "PAYMENT", "at": p["created_at"], "actor_id": p["payer_id"], "group_id": p["group_id"],
                          "receiver_id": p["receiver_id"], "amount": p["amount_paise"], "status": p["status"]})
        for c in conn.execute("""SELECT c.*, e.group_id, e.description FROM expense_confirmations c JOIN expenses e ON e.id=c.expense_id
                                 WHERE e.group_id = ANY(%s) AND c.created_at > %s""", (gids, since)):
            items.append({"kind": "CONFIRMED" if c["status"] == "CONFIRMED" else "DISPUTED", "at": c["created_at"],
                          "actor_id": c["user_id"], "group_id": c["group_id"], "expense_id": c["expense_id"],
                          "title": c["description"]})
        for c in conn.execute("""SELECT c.*, e.group_id, e.description FROM expense_comments c JOIN expenses e ON e.id=c.expense_id
                                 WHERE e.group_id = ANY(%s) AND c.created_at > %s AND c.deleted_at IS NULL""", (gids, since)):
            items.append({"kind": "COMMENT", "at": c["created_at"], "actor_id": c["user_id"], "group_id": c["group_id"],
                          "expense_id": c["expense_id"], "title": c["description"], "body": c["body"][:140]})
        for m in conn.execute("SELECT * FROM group_members WHERE group_id = ANY(%s) AND joined_at > %s", (gids, since)):
            items.append({"kind": "JOINED", "at": m["joined_at"], "actor_id": m["user_id"], "group_id": m["group_id"]})
        items.sort(key=lambda x: x["at"], reverse=True)
        items = items[: max(1, min(limit, 200))]
        names = domain.user_names(conn, {i["actor_id"] for i in items} | {i.get("receiver_id") for i in items} |
                                  {i.get("paid_by") for i in items})
        for i in items:
            g = groups[i["group_id"]]
            i["at"] = i["at"].isoformat()
            i["group_name"] = domain.display_name(conn, g, user["id"])
            i["currency"] = g["currency"]
            i["actor_name"] = "You" if i["actor_id"] == uid else names.get(i["actor_id"])
            i["is_you"] = i["actor_id"] == uid
            if i.get("receiver_id"):
                i["receiver_name"] = "you" if i["receiver_id"] == uid else names.get(i["receiver_id"])
        return {"items": items}


# ---------------------------------------------------------------- group chat

class MessageIn(BaseModel):
    body: str = Field(min_length=1, max_length=1000)


@router.get("/groups/{group_id}/messages")
def list_messages(group_id: int, after: str | None = None, user=Depends(current_user)):
    with db.tx() as conn:
        require_member(conn, group_id, user["id"])
        if after:
            after = after.replace(" ", "+")   # tolerate an unencoded "+" in the timezone offset
            rows = conn.execute("SELECT * FROM group_messages WHERE group_id=%s AND created_at > %s ORDER BY created_at",
                                (group_id, after)).fetchall()
        else:
            rows = list(reversed(conn.execute(
                "SELECT * FROM group_messages WHERE group_id=%s ORDER BY created_at DESC LIMIT 100", (group_id,)).fetchall()))
        names = domain.user_names(conn, [r["user_id"] for r in rows])
        return {"messages": [{"id": str(r["id"]), "user_id": r["user_id"], "name": names.get(r["user_id"]),
                              "is_you": r["user_id"] == user["id"], "body": r["body"],
                              "created_at": r["created_at"].isoformat()} for r in rows]}


@router.post("/groups/{group_id}/messages")
def send_message(group_id: int, body: MessageIn, user=Depends(current_user)):
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        mid = uuid.uuid4()
        conn.execute("INSERT INTO group_messages (id, group_id, user_id, body, created_at) VALUES (%s,%s,%s,%s,%s)",
                     (mid, group_id, user["id"], body.body.strip(), clock.now()))
        cfg = coin_config.current(conn)
        for uid in set(experiment.active_member_ids(conn, group_id)) - {user["id"]}:
            notify.enqueue(conn, cfg, user_id=uid, nid="C3", group_id=group_id, title=domain.display_name(conn, g, uid),
                           body=f"{user['name']}: {body.body.strip()[:120]}", dedupe_key=f"C3:{mid}:{uid}",
                           payload={"group_id": group_id, "route": "chat"},
                           batch_key=None)
        r = conn.execute("SELECT * FROM group_messages WHERE id=%s", (mid,)).fetchone()
    return {"id": str(r["id"]), "user_id": user["id"], "name": user["name"], "is_you": True, "body": r["body"],
            "created_at": r["created_at"].isoformat()}


# ---------------------------------------------------------------- devices (APNs)

class DeviceIn(BaseModel):
    token: str = Field(min_length=10, max_length=200)
    platform: str = "ios"


@router.post("/me/devices")
def register_device(body: DeviceIn, user=Depends(current_user)):
    with db.tx() as conn:
        conn.execute("""INSERT INTO devices (token, user_id, platform, updated_at) VALUES (%s,%s,%s,%s)
                        ON CONFLICT (token) DO UPDATE SET user_id=EXCLUDED.user_id, updated_at=EXCLUDED.updated_at""",
                     (body.token, user["id"], body.platform, clock.now()))
    return {"ok": True}


# ---------- reminders to pay (C5) ----------

@router.post("/groups/{group_id}/debts/{debtor_id}/remind")
def remind_to_pay(group_id: int, debtor_id: int, user=Depends(current_user)):
    """The person who is owed nudges someone to settle. Once per cooldown per pair."""
    with db.tx() as conn:
        g = require_member(conn, group_id, user["id"])
        owed = domain.group_debts(conn, g).get((debtor_id, user["id"]), 0)
        if owed <= 0:
            raise HTTPException(400, "They don't owe you anything here")
        cfg = coin_config.current(conn)
        cooldown = timedelta(hours=cfg["push"]["remind_cooldown_hours"])
        last = domain.last_pay_reminder(conn, group_id, user["id"], debtor_id)
        if last and clock.now() - last < cooldown:
            raise HTTPException(429, "You already sent a reminder. You can send another tomorrow.")
        loc = i18n.locale_of(conn, debtor_id)
        amount = fx.fmt(owed, g["currency"])
        notify.enqueue(conn, cfg, user_id=debtor_id, nid="C5", group_id=group_id,
                       title=i18n.t(loc, "pay_remind_title", name=user["name"]),
                       body=i18n.t(loc, "pay_remind_body", name=user["name"], amount=amount, group=domain.display_name(conn, g, debtor_id)),
                       dedupe_key=f"C5:{group_id}:{user['id']}:{debtor_id}:{clock.now().isoformat()}",
                       payload={"group_id": group_id, "creditor_id": user["id"], "route": "settle"})
        analytics.track(conn, "pay_remind_tapped", user_id=user["id"], group_id=group_id, debtor_id=debtor_id)
        return {"reminded_at": clock.now().isoformat(), "next_at": (clock.now() + cooldown).isoformat()}


# ---------- friends: 1:1 splits without making a group ----------

class FriendIn(BaseModel):
    phone: str


def _friend_json(conn, g, me: int, cfg) -> dict:
    other = conn.execute(
        """SELECT u.id, u.name FROM group_members m JOIN users u ON u.id=m.user_id
           WHERE m.group_id=%s AND m.user_id<>%s AND m.left_at IS NULL LIMIT 1""", (g["id"], me)).fetchone()
    return {"group_id": g["id"], "user_id": other["id"], "name": other["name"], "currency": g["currency"],
            "my_net_paise": domain.user_net(conn, g["id"]).get(me, 0), "coins_enabled": views.eligible(conn, g["id"], cfg)}


@router.get("/friends")
def list_friends(user=Depends(current_user)):
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        gs = conn.execute(
            """SELECT g.* FROM groups g JOIN group_members m ON m.group_id=g.id
               WHERE m.user_id=%s AND m.left_at IS NULL AND g.group_type='DIRECT'
                 AND (SELECT count(*) FROM group_members x WHERE x.group_id=g.id AND x.left_at IS NULL) = 2
               ORDER BY g.created_at DESC""", (user["id"],)).fetchall()
        return {"friends": [_friend_json(conn, g, user["id"], cfg) for g in gs]}


@router.post("/friends")
def add_friend(body: FriendIn, user=Depends(current_user)):
    """Start splitting with someone already on Squared. Returns their 1:1 group (made once per pair)."""
    phone = _norm_phone(body.phone)
    with db.tx() as conn:
        other = conn.execute("SELECT * FROM users WHERE phone=%s", (phone,)).fetchone()
        if not other:
            raise HTTPException(404, "They're not on Squared yet. Send them an invite link instead.")
        if other["id"] == user["id"]:
            raise HTTPException(400, "That's your own number")
        cfg = coin_config.current(conn)
        g = domain.direct_group(conn, user["id"], other["id"])
        created = g is None
        if created:
            g = _new_direct_group(conn, user, cfg)
            conn.execute("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (%s,%s,%s)",
                         (g["id"], other["id"], clock.now()))
            events.emit(conn, "MemberJoined", group_id=g["id"], user_id=other["id"])
        return {**_friend_json(conn, g, user["id"], cfg), "created": created}


@router.post("/friends/invite")
def invite_friend(user=Depends(current_user)):
    """For someone not on Squared yet: a 1:1 group with just you, whose invite link pairs them with you."""
    with db.tx() as conn:
        cfg = coin_config.current(conn)
        g = _new_direct_group(conn, user, cfg)
    from .api_coins import InviteIn, create_invite
    return {"group_id": g["id"], **create_invite(InviteIn(group_id=g["id"]), user)}


def _new_direct_group(conn, user, cfg):
    g = conn.execute(
        """INSERT INTO groups (name, group_type, expected_members, currency, created_by, created_at)
           VALUES ('Friends', 'DIRECT', 2, 'INR', %s, %s) RETURNING *""", (user["id"], clock.now())).fetchone()
    conn.execute("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (%s,%s,%s)",
                 (g["id"], user["id"], clock.now()))
    views.safe(conn, experiment.assign, conn, g, cfg)
    events.emit(conn, "MemberJoined", group_id=g["id"], user_id=user["id"])
    return g
