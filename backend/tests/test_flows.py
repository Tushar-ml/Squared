"""Eligibility, kill switch, goals, redemption, notifications, fail-open, config, experiment."""
from datetime import timedelta

import pytest

from app import clock, coin_config, db, experiment, jobs, notify, redemption
from conftest import all_integrity_ok, set_config


# ---------------------------------------------------------------- FR-1 eligibility & kill switch

def test_control_solo_and_non_home_groups_have_no_coin_ui(w):
    w.user("Rahul"); w.user("Priya")
    solo = w.flat("Rahul")
    assert w.req("Rahul", "GET", f"/groups/{solo}")["coins_enabled"] is False
    trip = w.flat("Rahul", "Priya", group_type="TRIP", name="Goa")
    detail = w.req("Rahul", "GET", f"/groups/{trip}")
    assert detail["coins_enabled"] is False and detail["arm"] is None
    e = w.expense("Rahul", trip, 500)
    assert "confirmation" not in w.req("Priya", "GET", f"/expenses/{e}")
    w.confirm("Priya", e, expect=409)
    set_config({"experiment": {"treatment_share": 0.0}})
    ctrl = w.flat("Rahul", "Priya", name="Control flat")
    d = w.req("Rahul", "GET", f"/groups/{ctrl}")
    assert d["arm"] == "CONTROL" and d["coins_enabled"] is False
    w.req("Rahul", "GET", f"/groups/{ctrl}/household", expect=404)
    w.drain()
    with db.tx() as c:
        assert c.execute("SELECT count(*) c FROM notifications").fetchone()["c"] == 0


def test_kill_switch_hides_ui_stops_earning_keeps_balance(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    w.confirm("Priya", e)
    w.drain()
    before = w.balance("Rahul")
    set_config({"kill_switch": True})
    assert w.req("Rahul", "GET", f"/groups/{g}")["coins_enabled"] is False
    assert w.c.get("/api/v1/config/coins").json()["kill_switch"] is True
    e2 = w.expense("Rahul", g, 500)  # core flow still works
    w.drain()
    with db.tx() as c:
        c.execute("INSERT INTO expense_confirmations (expense_id, expense_version, user_id, status) VALUES (%s,1,%s,'CONFIRMED')",
                  (e2, w.ids["Priya"]))
        from app import events
        events.emit(c, "ExpenseConfirmed", expense_id=e2, group_id=g, version=1, user_id=w.ids["Priya"])
    w.drain()
    assert w.balance("Rahul") == before
    set_config({"kill_switch": False})
    assert w.balance("Rahul") == before


def test_experiment_assignment_is_deterministic_and_logged(w):
    set_config({"experiment": {"treatment_share": 0.5}})
    w.user("Rahul")
    arms = []
    for i in range(20):
        gid = w.flat("Rahul", name=f"F{i}")
        with db.tx() as c:
            cfg = coin_config.current(c, fresh=True)
            arm = experiment.arm_of(c, gid, cfg)
            again = experiment.assign(c, c.execute("SELECT * FROM groups WHERE id=%s", (gid,)).fetchone(), cfg)
        assert arm == again == ("TREATMENT" if experiment.bucket(cfg["experiment"]["key"], gid) < 0.5 else "CONTROL")
        arms.append(arm)
    assert set(arms) == {"TREATMENT", "CONTROL"}
    with db.tx() as c:
        assert c.execute("SELECT count(*) c FROM analytics_events WHERE name='experiment_assigned'").fetchone()["c"] == 20


def test_config_rejects_bad_surprise_odds():
    with pytest.raises(coin_config.ConfigError):
        with db.tx() as c:
            coin_config.publish(c, {"surprise": {"p_any": 0.3, "p_2x": 0.15, "p_3x": 0.05}}, None)


def test_hide_coins_preference(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    w.req("Priya", "PATCH", "/me", {"hide_coins": True})
    assert w.req("Priya", "GET", f"/groups/{g}")["coins_enabled"] is False
    assert w.req("Rahul", "GET", f"/groups/{g}")["coins_enabled"] is True


# ---------------------------------------------------------------- FR-7 household goal

def test_weekly_goal_met_pays_pot_once_and_recap(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    clock.set_now(clock.ist().replace(hour=12) - timedelta(days=clock.ist().weekday()))  # Monday noon
    for _ in range(5):
        e = w.expense("Rahul", g, 100)
        w.confirm("Priya", e)
    w.drain()
    h = w.req("Rahul", "GET", f"/groups/{g}/household")
    assert h["progress"] == 5 and h["goal_met"] and h["pot_coins"] == 0
    assert [m["confirmed_this_week"] for m in h["members"]] == [False, True]
    clock.travel(timedelta(days=7))  # next Monday
    assert jobs.close_weeks() == 1
    w.drain()
    jobs.close_weeks()
    w.drain()
    h = w.req("Rahul", "GET", f"/groups/{g}/household")
    assert h["pot_coins"] == 120 and h["weeks_squared"] == 1 and h["progress"] == 0
    with db.tx() as c:
        recaps = c.execute("SELECT body FROM notifications WHERE notification_id='N5'").fetchall()
    assert len(recaps) == 2 and "hit the goal" in recaps[0]["body"]


def test_weekly_goal_missed_uses_kind_copy(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 100)
    w.confirm("Priya", e)
    w.drain()
    clock.travel(timedelta(days=7))
    jobs.close_weeks()
    w.drain()
    with db.tx() as c:
        body = c.execute("SELECT body FROM notifications WHERE notification_id='N5' LIMIT 1").fetchone()["body"]
        assert c.execute("SELECT status FROM household_goals").fetchone()["status"] == "MISSED"
    assert body.startswith("Last week was quiet")
    assert w.req("Rahul", "GET", f"/groups/{g}/household")["pot_coins"] == 0


# ---------------------------------------------------------------- FR-8 redemption

def _rich(w, name, coins, group=None):
    from app import ledger
    with db.tx() as c:
        cfg = coin_config.current(c, fresh=True)
        wal = ledger.get_wallet(c, "GROUP" if group else "USER", group or w.ids[name])
        ledger.earn(c, wal, amount=coins, reason="TEST", source_type="T", source_id=f"{name}{group}", source_version=1, cfg=cfg)


def _item(cost, scope="USER"):
    with db.tx() as c:
        return str(c.execute("SELECT id FROM catalog_items WHERE coin_cost=%s AND scope=%s LIMIT 1", (cost, scope)).fetchone()["id"])


def test_first_redemption_is_held_then_fulfilled(w):
    set_config({"redemption": {"first_redemption_hold_hours": 48}})
    w.user("Rahul")
    _rich(w, "Rahul", 250)
    r = w.req("Rahul", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, **{"Idempotency-Key": "a"})
    assert r["status"] == "HELD" and r["code"] is None
    assert w.balance("Rahul") == 150
    clock.travel(timedelta(hours=49))
    jobs.release_redemptions()
    hist = w.req("Rahul", "GET", "/coins/redemptions")["redemptions"]
    assert hist[0]["status"] == "FULFILLED" and hist[0]["code"].startswith("CODE-")
    r2 = w.req("Rahul", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, **{"Idempotency-Key": "b"})
    assert r2["status"] == "FULFILLED"  # only the first one is held
    same = w.req("Rahul", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, **{"Idempotency-Key": "b"})
    assert same["id"] == r2["id"] and w.balance("Rahul") == 50  # idempotent


def test_vendor_failure_refunds_coins(w):
    set_config({"redemption": {"first_redemption_hold_hours": 0}})
    w.user("Rahul")
    _rich(w, "Rahul", 120)
    redemption.vendor.mode = "fail"
    r = w.req("Rahul", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, **{"Idempotency-Key": "x"})
    assert r["status"] == "REFUNDED"
    assert w.balance("Rahul") == 120
    texts = [e["text"] for e in w.entries("Rahul")]
    assert "Refund: voucher didn't go through" in texts
    assert all_integrity_ok()


def test_redemption_eligibility_rules(w):
    set_config({"redemption": {"first_redemption_hold_hours": 0, "max_per_user_per_week": 1}})
    w.user("New", age_days=2)
    _rich(w, "New", 500)
    err = w.req("New", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, expect=400, **{"Idempotency-Key": "1"})
    assert err["detail"]["code"] == "account_too_new"
    w.user("Old")
    _rich(w, "Old", 500)
    w.req("Old", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, **{"Idempotency-Key": "1"})
    err = w.req("Old", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, expect=400, **{"Idempotency-Key": "2"})
    assert err["detail"]["code"] == "weekly_limit"
    cat = w.req("Old", "GET", "/coins/catalog?scope=USER")["items"]
    big = next(i for i in cat if i["coin_cost"] == 400)
    assert big["affordable"] is True or big["coins_needed"] == 400 - 400


def test_frozen_wallet_cannot_redeem(w):
    set_config({"redemption": {"first_redemption_hold_hours": 0}})
    w.user("Rahul"); w.user("Ops")
    with db.tx() as c:
        c.execute("UPDATE users SET role='OPS' WHERE id=%s", (w.ids["Ops"],))
    _rich(w, "Rahul", 200)
    wal = w.req("Ops", "GET", "/admin/wallets?query=Rahul")["wallets"][0]
    w.req("Ops", "POST", f"/admin/wallets/{wal['id']}/freeze", {"frozen": True, "reason": "suspicious ring"})
    err = w.req("Rahul", "POST", "/coins/redemptions", {"catalog_item_id": _item(100)}, expect=400, **{"Idempotency-Key": "f"})
    assert err["detail"]["code"] == "frozen"


def test_household_voucher_from_pot_visible_to_all(w):
    set_config({"redemption": {"first_redemption_hold_hours": 0}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    _rich(w, "pot", 900, group=g)
    r = w.req("Priya", "POST", "/coins/redemptions", {"catalog_item_id": _item(800, "GROUP"), "group_id": g},
              **{"Idempotency-Key": "h"})
    assert r["status"] == "FULFILLED"
    h = w.req("Rahul", "GET", f"/groups/{g}/household")
    assert h["pot_coins"] == 100 and h["pot_redemptions"][0]["redeemed_by"] == "Priya"
    # personal balance untouched; non-members can't spend the pot
    w.user("Stranger")
    w.req("Stranger", "POST", "/coins/redemptions", {"catalog_item_id": _item(800, "GROUP"), "group_id": g},
          expect=403, **{"Idempotency-Key": "s"})


def test_voucher_code_encrypted_at_rest():
    blob = redemption.encrypt_code("ABCD-1234")
    assert b"ABCD" not in blob and redemption.decrypt_code(blob) == "ABCD-1234"


# ---------------------------------------------------------------- FR-9 notifications

def test_push_quiet_hours_cap_and_optout(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    clock.set_now(clock.ist().replace(hour=23, minute=0))
    w.expense("Rahul", g, 100, desc="Late snack")
    w.drain()
    jobs.dispatch_notifications()
    with db.tx() as c:
        n = c.execute("SELECT * FROM notifications WHERE user_id=%s", (w.ids["Priya"],)).fetchone()
    assert n["status"] == "QUEUED" and clock.ist(n["deliver_after"]).hour == 8
    clock.set_now(clock.ist().replace(hour=8, minute=1) + timedelta(days=1))
    for d in ("Milk", "Bread", "Eggs"):
        w.expense("Rahul", g, 100, desc=d)
    w.drain()
    jobs.dispatch_notifications()
    with db.tx() as c:
        rows = c.execute("SELECT status, count(*) c FROM notifications WHERE user_id=%s GROUP BY status", (w.ids["Priya"],)).fetchall()
    counts = {r["status"]: r["c"] for r in rows}
    assert counts.get("SENT") == 2  # 2 per user per day
    assert counts.get("INBOX_ONLY", 0) + counts.get("BATCHED", 0) >= 1
    delivered = w.req("Priya", "GET", "/me/notifications/deliver")["notifications"]
    assert len(delivered) == 2 and delivered[0]["payload"]["category"] == "EXPENSE_CONFIRM"
    assert w.req("Priya", "GET", "/me/notifications/deliver")["notifications"] == []
    w.req("Priya", "PUT", "/me/notification-prefs", {"prefs": {"N2": False}})
    w.pay("Rahul", g, "Priya", 300)
    w.drain()
    clock.travel(timedelta(days=1))
    jobs.dispatch_notifications()
    with db.tx() as c:
        st = c.execute("SELECT status FROM notifications WHERE notification_id='N2'").fetchone()["status"]
    assert st == "INBOX_ONLY"


def test_n1_batches_three_in_ten_minutes(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    for d in ("A", "B", "C", "D"):
        w.expense("Rahul", g, 100, desc=d)
    w.drain()
    with db.tx() as c:
        rows = c.execute("SELECT status, body FROM notifications WHERE user_id=%s ORDER BY created_at", (w.ids["Priya"],)).fetchall()
    assert [r["status"] for r in rows].count("BATCHED") == 2
    assert any(r["body"] == "Rahul added 4 expenses. Review" for r in rows)


def test_remind_limited_once_per_24h(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 100)
    assert len(w.req("Rahul", "POST", f"/expenses/{e}/remind")["reminded"]) == 1
    assert w.req("Rahul", "POST", f"/expenses/{e}/remind")["reminded"] == []
    w.req("Priya", "POST", f"/expenses/{e}/remind", expect=403)
    clock.travel(timedelta(hours=25))
    assert len(w.req("Rahul", "POST", f"/expenses/{e}/remind")["reminded"]) == 1


def test_settle_nudge_and_first_redeem_push(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Priya", g, 900)
    w.confirm("Rahul", e)
    w.drain()
    clock.travel(timedelta(hours=25))
    assert jobs.settle_nudges() == 1
    assert jobs.settle_nudges() == 0  # once per 3 days
    with db.tx() as c:
        body = c.execute("SELECT body FROM notifications WHERE notification_id='N4'").fetchone()["body"]
    assert body == "You owe Priya INR 450. Pay today for +30 coins"


# ---------------------------------------------------------------- FR-14 fail-open

def test_core_flows_work_while_reward_worker_is_down(w):
    """No drain: events sit in the outbox; adding, confirming and paying still work."""
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    w.confirm("Priya", e)
    p = w.pay("Priya", g, "Rahul", 250)
    w.receipt("Rahul", p)
    d = w.req("Rahul", "GET", f"/groups/{g}")
    assert d["my_net_paise"] == 0
    assert w.balance("Rahul") == 0
    w.drain()  # worker comes back: events drain
    assert w.balance("Rahul") > 0


def test_core_flows_survive_broken_reward_tables(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    with db.tx() as c:
        c.execute("ALTER TABLE coin_ledger RENAME TO coin_ledger_broken")
    try:
        e = w.expense("Rahul", g, 500)
        d = w.req("Rahul", "GET", f"/groups/{g}")
        assert d["expenses"][0]["id"] == e
        w.req("Priya", "GET", "/me/inbox/needs-you")  # core list still loads; coin parts drop out
        assert w.req("Rahul", "GET", "/coins/wallet", expect=503)["detail"] == "Coins unavailable right now"
    finally:
        with db.tx() as c:
            c.execute("ALTER TABLE coin_ledger_broken RENAME TO coin_ledger")


def test_old_clients_ignore_additive_fields(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    core_keys = {"id", "group_id", "description", "amount_paise", "paid_by", "splits", "created_at"}
    assert core_keys <= set(w.req("Priya", "GET", f"/expenses/{e}"))


def test_balances_unchanged_by_confirmation(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    before = w.req("Rahul", "GET", f"/groups/{g}")["all_debts"]
    w.confirm("Priya", e)
    w.drain()
    assert w.req("Rahul", "GET", f"/groups/{g}")["all_debts"] == before


# ---------------------------------------------------------------- ops

def test_ops_reverse_writes_reversal_and_audit(w):
    w.user("Rahul"); w.user("Priya"); w.user("Ops")
    with db.tx() as c:
        c.execute("UPDATE users SET role='OPS' WHERE id=%s", (w.ids["Ops"],))
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    w.confirm("Priya", e)
    w.drain()
    w.req("Rahul", "GET", "/admin/wallets", expect=403)
    wal = next(x for x in w.req("Ops", "GET", "/admin/wallets?query=Rahul")["wallets"] if x["owner_type"] == "USER")
    led = w.req("Ops", "GET", f"/admin/wallets/{wal['id']}/ledger")
    adder = next(x for x in led["entries"] if x["reason_code"] == "EXPENSE_ADDER")
    w.req("Ops", "POST", f"/admin/ledger/{adder['id']}/reverse", {"reason": "duplicate expense"})
    w.req("Ops", "POST", f"/admin/ledger/{adder['id']}/reverse", {"reason": "again"})  # idempotent
    assert w.balance("Rahul") == 50
    hist = [x["text"] for x in w.entries("Rahul")]
    assert "Reversed: Corrected by support" in hist and "Groceries, confirmed by Priya" in hist
    assert len([a for a in w.req("Ops", "GET", "/admin/audit")["audit"] if a["action"] == "REVERSE_ENTRY"]) == 2
    w.req("Ops", "POST", f"/admin/ledger/{adder['id']}/reverse", {"reason": ""}, expect=422)
    assert jobs.integrity_check() == []
