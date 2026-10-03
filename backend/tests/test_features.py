"""Recurring bills, simplified debts, comments, search, members, receipts, budgets, activity, chat,
Hindi pushes, PDF reports and ops bulk tools."""
from datetime import timedelta

from app import api_features, clock, db, jobs
from conftest import set_config


def _notifs(uid, nid=None):
    with db.tx() as c:
        q = "SELECT * FROM notifications WHERE user_id=%s" + (" AND notification_id=%s" if nid else "") + " ORDER BY created_at"
        return c.execute(q, (uid, nid) if nid else (uid,)).fetchall()


# ---------------------------------------------------------------- recurring (FR-16)

def test_monthly_recurring_bill_adds_itself_and_reminds_the_day_before(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    today = clock.ist().date()
    clock.set_now(clock.ist().replace(day=10, hour=12))
    r = w.req("Aman", "POST", f"/groups/{g}/recurring", {
        "expense": {"description": "Rent", "amount_paise": 3000000, "split_type": "PERCENT", "percents": {a: 60, b: 40}},
        "frequency": "MONTHLY", "day": 11})
    assert r["next_run"].endswith("-11") and r["split_type"] == "PERCENT" and r["category"] == "rent"
    api_features.run_recurring()          # 10th: day-before reminder only
    assert len(_notifs(b, "C1")) == 1 and "tomorrow" in _notifs(b, "C1")[0]["body"]
    with db.tx() as c:
        assert c.execute("SELECT count(*) n FROM expenses").fetchone()["n"] == 0
    clock.travel(timedelta(days=1))
    assert api_features.run_recurring() == 1
    api_features.run_recurring()          # idempotent within the day
    with db.tx() as c:
        e = c.execute("SELECT * FROM expenses").fetchone()
        rows = c.execute("SELECT count(*) n FROM expenses").fetchone()["n"]
    assert rows == 1 and e["recurring_id"] is not None and e["split_type"] == "PERCENT"
    nxt = w.req("Aman", "GET", f"/groups/{g}/recurring")["recurring"][0]
    assert nxt["next_run"].endswith("-11") and nxt["next_run"] > nxt["last_run"]
    # pausing stops it
    w.req("Aman", "PATCH", f"/recurring/{nxt['id']}", {"active": False})
    assert w.req("Aman", "GET", f"/groups/{g}/recurring")["recurring"] == []
    _ = today


def test_weekly_and_validation(w):
    w.user("Aman"); w.user("Priya")
    g = w.flat("Aman", "Priya")
    base = {"expense": {"description": "Cook", "amount_paise": 150000}}
    r = w.req("Aman", "POST", f"/groups/{g}/recurring", {**base, "frequency": "WEEKLY", "day": 0})
    from datetime import date
    assert date.fromisoformat(r["next_run"]).weekday() == 0
    w.req("Aman", "POST", f"/groups/{g}/recurring", {**base, "frequency": "MONTHLY", "day": 31}, expect=400)
    w.req("Aman", "POST", f"/groups/{g}/recurring", {**base, "frequency": "YEARLY", "day": 1}, expect=400)


def test_next_date_math():
    from datetime import date
    assert api_features.next_date("MONTHLY", 5, date(2026, 10, 3)) == date(2026, 10, 5)
    assert api_features.next_date("MONTHLY", 5, date(2026, 10, 6)) == date(2026, 11, 5)
    assert api_features.next_date("MONTHLY", 28, date(2026, 12, 29)) == date(2027, 1, 28)
    assert api_features.next_date("WEEKLY", 4, date(2026, 10, 3)) == date(2026, 10, 9)   # Sat -> Fri


# ---------------------------------------------------------------- simplified debts

def test_simplify_debts_reduces_payments_without_changing_totals(w):
    a, b, c = w.user("Aman"), w.user("Priya"), w.user("Rahul")
    g = w.flat("Aman", "Priya", "Rahul")
    w.req("Priya", "POST", f"/groups/{g}/expenses", {"description": "X", "amount_paise": 10000, "split_type": "EXACT",
                                                     "exact": {a: 10000}})     # Aman owes Priya 100
    w.req("Rahul", "POST", f"/groups/{g}/expenses", {"description": "Y", "amount_paise": 10000, "split_type": "EXACT",
                                                     "exact": {b: 10000}})     # Priya owes Rahul 100
    before = {(d["debtor_id"], d["creditor_id"]): d["amount_paise"] for d in w.req("Aman", "GET", f"/groups/{g}")["all_debts"]}
    assert before == {(a, b): 10000, (b, c): 10000}
    w.req("Aman", "PATCH", f"/groups/{g}", {"simplify_debts": True})
    after = {(d["debtor_id"], d["creditor_id"]): d["amount_paise"] for d in w.req("Aman", "GET", f"/groups/{g}")["all_debts"]}
    assert after == {(a, c): 10000}
    # paying the simplified suggestion squares everyone
    w.pay("Aman", g, "Rahul", 100)
    assert w.req("Aman", "GET", f"/groups/{g}")["all_debts"] == []


# ---------------------------------------------------------------- comments, search

def test_comments_notify_without_using_coin_push_cap(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.expense("Aman", g, 300)
    out = w.req("Priya", "POST", f"/expenses/{e}/comments", {"body": "Was this for both weeks?"})
    assert out["comments"][0]["body"] == "Was this for both weeks?" and out["comments"][0]["is_you"]
    assert len(_notifs(a, "C2")) == 1
    cid = out["comments"][0]["id"]
    w.req("Aman", "DELETE", f"/comments/{cid}", expect=404)       # only your own
    w.req("Priya", "DELETE", f"/comments/{cid}")
    assert w.req("Aman", "GET", f"/expenses/{e}/comments")["comments"] == []
    for _ in range(3):
        w.req("Priya", "POST", f"/expenses/{e}/comments", {"body": "again"})
    jobs.dispatch_notifications()
    sent = [n for n in _notifs(a) if n["status"] == "SENT"]
    assert len([n for n in sent if n["notification_id"] == "C2"]) == 4      # 1 + 3, not capped at 2


def test_search_filters(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    w.expense("Aman", g, 799, desc="Wifi bill")
    w.expense("Priya", g, 1200, desc="Zepto groceries", participants=["Priya"])
    e3 = w.expense("Aman", g, 50, desc="Milk")
    w.req("Priya", "POST", f"/expenses/{e3}/comments", {"body": "from the dairy"})
    assert [x["description"] for x in w.req("Aman", "GET", f"/groups/{g}/search?q=wifi")["expenses"]] == ["Wifi bill"]
    assert [x["description"] for x in w.req("Aman", "GET", f"/groups/{g}/search?q=dairy")["expenses"]] == ["Milk"]
    assert {x["description"] for x in w.req("Aman", "GET", f"/groups/{g}/search?category=groceries")["expenses"]} == {"Zepto groceries", "Milk"}
    mine = w.req("Aman", "GET", f"/groups/{g}/search?member={a}")["expenses"]
    assert {x["description"] for x in mine} == {"Wifi bill", "Milk"}
    big = w.req("Aman", "GET", f"/groups/{g}/search?min_amount=70000")
    assert {x["description"] for x in big["expenses"]} == {"Wifi bill", "Zepto groceries"} and big["total"] == 199900


# ---------------------------------------------------------------- group settings & members

def test_members_can_only_leave_when_settled_and_creator_removes(w):
    a, b, c = w.user("Aman"), w.user("Priya"), w.user("Rahul")
    g = w.flat("Aman", "Priya", "Rahul")
    w.expense("Aman", g, 300)
    r = w.req("Priya", "DELETE", f"/groups/{g}/members/{b}", expect=409)
    assert "Settle up first" in r["detail"]
    w.req("Priya", "DELETE", f"/groups/{g}/members/{c}", expect=403)      # not the creator
    w.pay("Priya", g, "Aman", 100)
    w.req("Priya", "DELETE", f"/groups/{g}/members/{b}")
    w.pay("Rahul", g, "Aman", 100)
    w.req("Aman", "DELETE", f"/groups/{g}/members/{c}")
    assert [m["id"] for m in w.req("Aman", "GET", f"/groups/{g}")["members"]] == [a]
    w.req("Aman", "POST", f"/groups/{g}/leave")


def test_group_settings_currency_locks_after_first_expense(w):
    w.user("Aman"); w.user("Priya")
    g = w.flat("Aman", "Priya")
    out = w.req("Aman", "PATCH", f"/groups/{g}", {"name": "Flat 9C", "currency": "USD",
                                                  "default_split": {"split_type": "PERCENT", "percents": {"1": 50}}})
    assert out["name"] == "Flat 9C" and out["currency"] == "USD" and out["default_split"]["split_type"] == "PERCENT"
    w.expense("Aman", g, 10)
    w.req("Aman", "PATCH", f"/groups/{g}", {"currency": "EUR"}, expect=409)


# ---------------------------------------------------------------- receipts

def test_receipt_upload_view_and_access_control(w):
    w.user("Aman"); w.user("Priya"); w.user("Stranger")
    g = w.flat("Aman", "Priya")
    e = w.expense("Aman", g, 300)
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 2000 + b"\xff\xd9"
    r = w.c.post(f"/api/v1/expenses/{e}/attachments", content=jpeg,
                 headers={**w.h("Aman"), "Content-Type": "image/jpeg"})
    assert r.status_code == 200, r.text
    aid = r.json()["id"]
    assert w.req("Priya", "GET", f"/expenses/{e}/attachments")["attachments"][0]["bytes"] == len(jpeg)
    got = w.c.get(f"/api/v1/attachments/{aid}", headers=w.h("Priya"))
    assert got.status_code == 200 and got.content == jpeg and got.headers["content-type"] == "image/jpeg"
    assert w.c.get(f"/api/v1/attachments/{aid}", headers=w.h("Stranger")).status_code == 403
    bad = w.c.post(f"/api/v1/expenses/{e}/attachments", content=b"hi", headers={**w.h("Aman"), "Content-Type": "text/plain"})
    assert bad.status_code == 415
    w.req("Priya", "DELETE", f"/attachments/{aid}", expect=404)   # only the uploader
    w.req("Aman", "DELETE", f"/attachments/{aid}")


# ---------------------------------------------------------------- budgets

def test_budget_alerts_once_at_80_and_100_percent(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    st = w.req("Aman", "PUT", f"/groups/{g}/budgets", {"budgets": {"groceries": 100000}})
    assert st["budgets"][0]["limit"] == 100000 and st["budgets"][0]["spent"] == 0
    w.expense("Aman", g, 500, desc="Groceries week 1")
    assert _notifs(b, "C4") == []
    w.expense("Aman", g, 350, desc="Groceries week 2")     # 85%
    assert len(_notifs(b, "C4")) == 1 and "850" in _notifs(b, "C4")[0]["body"]
    w.expense("Aman", g, 200, desc="Vegetables")            # 105%
    w.expense("Aman", g, 10, desc="Milk")
    notes = _notifs(b, "C4")
    assert len(notes) == 2 and "over budget" in notes[1]["body"]
    assert w.req("Aman", "GET", f"/groups/{g}/budgets")["budgets"][0]["pct"] == 106.0
    w.req("Aman", "PUT", f"/groups/{g}/budgets", {"budgets": {"groceries": 0}})
    assert w.req("Aman", "GET", f"/groups/{g}/budgets")["budgets"] == []


# ---------------------------------------------------------------- activity & chat

def test_activity_feed_collects_everything(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.expense("Aman", g, 300, desc="Wifi")
    w.confirm("Priya", e)
    w.req("Priya", "POST", f"/expenses/{e}/comments", {"body": "thanks"})
    w.pay("Priya", g, "Aman", 150)
    kinds = [i["kind"] for i in w.req("Aman", "GET", "/me/activity")["items"]]
    assert {"EXPENSE", "CONFIRMED", "COMMENT", "PAYMENT", "JOINED"} <= set(kinds)
    first = w.req("Aman", "GET", "/me/activity")["items"][0]
    assert first["group_name"] == "Flat 4B" and "actor_name" in first


def test_group_chat(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    m1 = w.req("Aman", "POST", f"/groups/{g}/messages", {"body": "Cylinder is empty"})
    w.req("Priya", "POST", f"/groups/{g}/messages", {"body": "Booked one"})
    msgs = w.req("Aman", "GET", f"/groups/{g}/messages")["messages"]
    assert [m["body"] for m in msgs] == ["Cylinder is empty", "Booked one"] and msgs[0]["is_you"]
    from urllib.parse import quote
    newer = w.req("Aman", "GET", f"/groups/{g}/messages?after={quote(m1['created_at'])}")["messages"]
    assert [m["body"] for m in newer] == ["Booked one"]
    assert len(_notifs(b, "C3")) == 1
    w.user("Stranger")
    w.req("Stranger", "GET", f"/groups/{g}/messages", expect=403)


# ---------------------------------------------------------------- Hindi, devices, PDF, ops

def test_hindi_users_get_hindi_pushes(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    w.req("Priya", "PATCH", "/me", {"locale": "hi"})
    w.expense("Aman", g, 300, desc="Wifi")
    w.drain()
    n = _notifs(b, "N1")[0]
    assert n["title"] == "सही है?" and "आपका हिस्सा" in n["body"]
    assert _notifs(a) == [] or all("सही" not in x["title"] for x in _notifs(a))
    w.req("Priya", "PATCH", "/me", {"locale": "fr"}, expect=422)


def test_device_registration(w):
    w.user("Aman")
    w.req("Aman", "POST", "/me/devices", {"token": "a" * 64})
    with db.tx() as c:
        assert c.execute("SELECT count(*) n FROM devices").fetchone()["n"] == 1


def test_pdf_report(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    w.expense("Aman", g, 3000, desc="Rent")
    w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Duty free", "amount_paise": 10000, "currency": "AED"})
    r = w.c.get(f"/api/v1/groups/{g}/report?format=pdf", headers=w.h("Aman"))
    assert r.status_code == 200 and r.headers["content-type"] == "application/pdf" and r.content.startswith(b"%PDF")
    assert len(r.content) > 1500


def test_ops_ring_report_and_bulk_reverse(w):
    a, b, o = w.user("X", age_days=2, device="d1"), w.user("Y", age_days=2, device="d1"), w.user("Ops")
    w.user("Z", device="d3")
    with db.tx() as c:
        c.execute("UPDATE users SET role='OPS' WHERE id=%s", (o,))
    set_config({"caps": {"user_daily": 1000, "pair_daily_confirmations": 100, "group_daily_rewarded_expenses": 100},
                "risk": {"threshold": 5}})
    g = w.flat("X", "Y", "Z")
    for _ in range(6):
        e = w.expense("X", g, 30, participants=["X", "Y"])
        w.confirm("Y", e)
    w.drain()
    rings = w.req("Ops", "GET", "/admin/rings")["pairs"]
    assert rings and rings[0]["confirmations"] == 6 and rings[0]["risk"] == "high"
    assert "shared device" in rings[0]["flags"]
    ids = [x["id"] for x in w.entries("X") if x["entry_type"] == "EARN"]
    out = w.req("Ops", "POST", "/admin/ledger/bulk-reverse", {"entry_ids": ids, "reason": "confirmed ring"})
    assert out["reversed"] == len(ids)
    assert w.balance("X") == 0
    assert w.req("Ops", "GET", "/admin/audit")["audit"][0]["action"] == "BULK_REVERSE"


# ---------------------------------------------------------------- reminders to pay (C5)

def test_owed_person_can_remind_once_per_cooldown_in_debtor_language(w):
    a, b = w.user("Aman"), w.user("Priya")
    c = w.user("Ravi")
    g = w.flat("Aman", "Priya", "Ravi")
    w.expense("Aman", g, 300, participants=["Aman", "Priya"])   # Priya owes Aman INR 150
    w.req("Priya", "PATCH", "/me", {"locale": "hi"})
    w.req("Aman", "POST", f"/groups/{g}/debts/{b}/remind")
    n = _notifs(b, "C5")
    assert len(n) == 1 and "Aman" in n[0]["title"] and "150" in n[0]["body"] and "चुका" in n[0]["body"]
    assert n[0]["payload"]["route"] == "settle" and n[0]["payload"]["creditor_id"] == a
    detail = w.req("Aman", "GET", f"/groups/{g}")
    assert next(d for d in detail["debts"] if d["debtor_id"] == b)["reminded_at"]
    # cooldown, then allowed again
    w.req("Aman", "POST", f"/groups/{g}/debts/{b}/remind", expect=429)
    clock.travel(timedelta(hours=25))
    w.req("Aman", "POST", f"/groups/{g}/debts/{b}/remind")
    assert len(_notifs(b, "C5")) == 2
    # only someone who is owed can remind; can't remind someone who owes you nothing
    w.req("Priya", "POST", f"/groups/{g}/debts/{a}/remind", expect=400)
    w.req("Aman", "POST", f"/groups/{g}/debts/{c}/remind", expect=400)
    w.req("Ravi", "POST", f"/groups/{g}/debts/{b}/remind", expect=400)



# ---------------------------------------------------------------- friends: 1:1 splits

def test_add_friend_by_phone_makes_one_pair_group_named_after_them(w):
    a, b = w.user("Aman"), w.user("Priya")
    w.user("Ravi")
    priya_phone = w.phones["Priya"]
    f = w.req("Aman", "POST", "/friends", {"phone": priya_phone})
    assert f["created"] and f["name"] == "Priya" and f["user_id"] == b
    again = w.req("Aman", "POST", "/friends", {"phone": priya_phone})
    assert not again["created"] and again["group_id"] == f["group_id"]
    back = w.req("Priya", "POST", "/friends", {"phone": w.phones["Aman"]})
    assert back["group_id"] == f["group_id"] and back["name"] == "Aman"
    gid = f["group_id"]
    # each side sees the other's name; friend pairs don't clutter the groups list
    assert w.req("Aman", "GET", f"/groups/{gid}")["name"] == "Priya"
    assert w.req("Priya", "GET", f"/groups/{gid}")["name"] == "Aman"
    assert all(g["id"] != gid for g in w.req("Aman", "GET", "/groups")["groups"])
    # splitting, coins and balances work like any group
    e = w.expense("Aman", gid, 600)
    w.confirm("Priya", e)
    fr = w.req("Aman", "GET", "/friends")["friends"]
    assert len(fr) == 1 and fr[0]["name"] == "Priya" and fr[0]["my_net_paise"] == 30000 and fr[0]["coins_enabled"]
    w.req("Aman", "POST", "/friends", {"phone": w.phones["Aman"]}, expect=400)
    w.req("Aman", "POST", "/friends", {"phone": "+919111111111"}, expect=404)
    _ = a


def test_friend_invite_link_pairs_new_person_once(w):
    w.user("Aman"); w.user("Priya"); w.user("Ravi")
    inv = w.req("Aman", "POST", "/friends/invite")
    assert "Squared" in inv["message"] and "Join me" in inv["message"]
    assert w.req("Aman", "GET", "/friends")["friends"] == []        # not shown until they join
    j = w.req("Priya", "POST", "/invites/accept", {"token": inv["token"]})
    assert j["group_id"] == inv["group_id"] and j["group_name"] == "Aman"
    assert [f["name"] for f in w.req("Aman", "GET", "/friends")["friends"]] == ["Priya"]
    w.req("Ravi", "POST", "/invites/accept", {"token": inv["token"]}, expect=400)   # link is for one person
    # a second link between the same two people lands on the existing pair
    inv2 = w.req("Aman", "POST", "/friends/invite")
    assert w.req("Priya", "POST", "/invites/accept", {"token": inv2["token"]})["group_id"] == inv["group_id"]
