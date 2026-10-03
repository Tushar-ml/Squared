"""Earn rules, AB-1..AB-8 and caps (FR-3, FR-4, FR-5). Each test asserts the ledger result."""
from datetime import timedelta

from app import clock, db, jobs
from conftest import all_integrity_ok, set_config


def test_confirm_pays_adder_confirmer_and_first_win(w):
    w.user("Rahul"); w.user("Priya"); w.user("Aman")
    g = w.flat("Rahul", "Priya", "Aman")
    e = w.expense("Rahul", g, 799)
    w.drain()
    out = w.confirm("Priya", e)
    assert out["reward_preview"]["coins"] == 2
    w.drain()
    assert w.reasons("Rahul") == [("EXPENSE_ADDER", 5), ("FIRST_WIN", 50)]
    assert w.reasons("Priya") == [("EXPENSE_CONFIRMER", 2), ("FIRST_WIN", 50)]
    # second confirmer: confirmer coins only, adder is paid once per expense version
    w.confirm("Aman", e)
    w.drain()
    assert w.reasons("Rahul") == [("EXPENSE_ADDER", 5), ("FIRST_WIN", 50)]
    assert ("EXPENSE_CONFIRMER", 2) in w.reasons("Aman")
    assert all_integrity_ok()


def test_max_confirmers_per_expense(w):
    names = ["A", "B", "C", "D", "E", "F"]
    for n in names:
        w.user(n)
    g = w.flat("A", *names[1:])
    e = w.expense("A", g, 600)
    for n in names[1:]:
        w.confirm(n, e)
    w.drain()
    paid = [n for n in names[1:] if ("EXPENSE_CONFIRMER", 2) in w.reasons(n)]
    assert paid == ["B", "C", "D", "E"]  # 4 per expense


def test_ab1_self_confirm_and_non_participant_rejected(w):
    w.user("Rahul"); w.user("Priya"); w.user("Aman")
    g = w.flat("Rahul", "Priya", "Aman")
    e = w.expense("Rahul", g, 500, participants=["Rahul", "Priya"])
    w.confirm("Rahul", e, expect=403)
    w.confirm("Aman", e, expect=403)
    w.drain()
    assert w.entries("Rahul") == []


def test_ab1_unverified_confirmer_earns_nothing(w):
    w.user("Rahul"); w.user("Priya", verified=False)
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    w.confirm("Priya", e)
    w.drain()
    assert w.entries("Priya") == [] and w.entries("Rahul") == []


def test_ab2_below_minimum_and_shared_device(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 19)
    w.confirm("Priya", e)
    w.drain()
    assert w.entries("Rahul") == []
    w.user("X", device="same"); w.user("Y", device="same")
    g2 = w.flat("X", "Y", name="Twins")
    e2 = w.expense("X", g2, 400)
    w.confirm("Y", e2)
    w.drain()
    assert w.entries("X") == [] and w.entries("Y") == []


def test_ab3_edit_resets_confirmation_and_reverses(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500, desc="Groceries")
    w.confirm("Priya", e)
    w.drain()
    out = w.req("Rahul", "PATCH", f"/expenses/{e}", {"amount_paise": 60000})
    assert out["version"] == 2 and out["confirmation"]["status"] == "WAITING"
    w.drain()
    assert w.balance("Rahul") == 50  # adder 5 reversed, first win kept
    texts = [x["text"] for x in w.entries("Rahul")]
    assert "Reversed: Groceries was edited" in texts and "Groceries, confirmed by Priya" in texts
    w.confirm("Priya", e)
    w.drain()
    assert w.balance("Rahul") == 55
    # description-only edits keep the confirmation
    out = w.req("Rahul", "PATCH", f"/expenses/{e}", {"description": "Veggies"})
    assert out["version"] == 2 and out["confirmation"]["status"] == "CONFIRMED"
    assert all_integrity_ok()


def test_ab4_delete_reverses_and_spent_coins_create_deficit(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 500)
    w.confirm("Priya", e)
    w.drain()
    with db.tx() as c:  # Priya spends the 52 coins she has... set up a cheap item for the test
        c.execute("UPDATE catalog_items SET coin_cost=52 WHERE vendor_sku='FB-25'")
        item = c.execute("SELECT id FROM catalog_items WHERE vendor_sku='FB-25'").fetchone()["id"]
    set_config({"redemption": {"first_redemption_hold_hours": 0}})
    r = w.req("Priya", "POST", "/coins/redemptions", {"catalog_item_id": str(item)}, **{"Idempotency-Key": "k1"})
    assert r["status"] == "FULFILLED" and r["code"]
    w.req("Rahul", "DELETE", f"/expenses/{e}")
    w.drain()
    wal = w.req("Priya", "GET", "/coins/wallet")
    assert wal["deficit"] == 2 and wal["balance"] == 0
    err = w.req("Priya", "POST", "/coins/redemptions", {"catalog_item_id": str(item)}, expect=400, **{"Idempotency-Key": "k2"})
    assert err["detail"]["code"] in ("deficit", "insufficient")
    assert all_integrity_ok()


def test_ab5_ping_pong_payment_earns_nothing(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    p1 = w.pay("Rahul", g, "Priya", 500)
    w.receipt("Priya", p1)
    w.drain()
    assert w.balance("Rahul") >= 20
    before = {n: len(w.entries(n)) for n in ("Rahul", "Priya")}
    p2 = w.pay("Priya", g, "Rahul", 500)  # same amount straight back within 7 days
    w.receipt("Rahul", p2)
    w.drain()
    assert {n: len(w.entries(n)) for n in ("Rahul", "Priya")} == before


def test_ab6_dispute_earns_nothing_and_reverses(w):
    w.user("Rahul"); w.user("Priya"); w.user("Aman")
    g = w.flat("Rahul", "Priya", "Aman")
    e = w.expense("Rahul", g, 900)
    w.confirm("Aman", e)
    w.drain()
    w.confirm("Priya", e, status="DISPUTED", reason="WRONG_AMOUNT")
    w.drain()
    assert w.balance("Rahul") == 50  # adder coins reversed; first win stays
    assert ("EXPENSE_CONFIRMER", -2) in [(x["reason_code"].replace("REVERSAL_", ""), x["amount"]) for x in w.entries("Aman")]
    detail = w.req("Rahul", "GET", f"/expenses/{e}")
    assert detail["confirmation"]["status"] == "DISPUTED"
    with db.tx() as c:
        n = c.execute("SELECT count(*) c FROM notifications WHERE user_id=%s AND notification_id='N9'", (w.ids["Rahul"],)).fetchone()["c"]
    assert n == 1


def test_ab7_risky_new_account_goes_pending_then_ops_release(w, client):
    w.user("Rahul", age_days=1, device="d1"); w.user("Priya", age_days=1, device="d1"); w.user("Aman", device="d2")
    g = w.flat("Rahul", "Priya", "Aman")
    e = w.expense("Rahul", g, 500)
    w.confirm("Priya", e)
    w.drain()
    pend = [x for x in w.entries("Priya") if x["status"] == "PENDING"]
    assert pend and w.balance("Priya") == 0
    with db.tx() as c:
        c.execute("UPDATE users SET role='OPS' WHERE id=%s", (w.ids["Aman"],))
    q = w.req("Aman", "GET", "/admin/pending")["pending"]
    assert len(q) >= 1
    w.req("Aman", "POST", f"/admin/pending/{pend[0]['id']}/release", {"reason": "verified roommates"})
    assert w.balance("Priya") == pend[0]["amount"]
    audit = w.req("Aman", "GET", "/admin/audit")["audit"]
    assert audit[0]["action"] == "RELEASE_PENDING"
    assert all_integrity_ok()


def test_ab8_invite_rewards_only_after_first_confirmed_expense(w):
    w.user("Rahul"); w.user("Priya"); w.user("Newbie")
    g = w.flat("Rahul", "Priya")
    inv = w.req("Rahul", "POST", "/invites", {"group_id": g})
    assert "earn coins" in inv["message"]
    w.req("Newbie", "POST", "/invites/accept", {"token": inv["token"]})
    w.drain()
    assert not [x for x in w.entries("Rahul") if x["reason_code"] == "INVITE"]
    statuses = w.req("Rahul", "GET", f"/invites?group_id={g}")["invites"]
    assert statuses[0]["status"] == "JOINED"
    e = w.expense("Newbie", g, 300, participants=["Newbie", "Priya"])
    w.confirm("Priya", e)
    w.drain()
    assert ("INVITE", 50) in w.reasons("Rahul") and ("INVITE", 50) in w.reasons("Newbie")
    assert w.req("Rahul", "GET", f"/invites?group_id={g}")["invites"][0]["status"] == "REWARDED"
    # replays don't pay twice
    with db.tx() as c:
        c.execute("UPDATE outbox_events SET processed_at=NULL")
    w.drain()
    assert [x["reason_code"] for x in w.entries("Rahul")].count("INVITE") == 1


def test_cap_user_daily_trims_and_notifies(w):
    set_config({"caps": {"user_daily": 7}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e1 = w.expense("Rahul", g, 100)
    e2 = w.expense("Rahul", g, 100)
    w.confirm("Priya", e1)
    w.drain()
    w.confirm("Priya", e2)
    w.drain()
    # Rahul: 5 + min(5, 7-5=2) = 7 capped coins (+50 first win excluded from caps)
    assert w.balance("Rahul") == 57
    wal = w.req("Rahul", "GET", "/coins/wallet")
    assert wal["cap_notice"]["message"] == "Daily coin limit reached, back tomorrow"
    # next IST day the cap resets
    clock.travel(timedelta(days=1))
    e3 = w.expense("Rahul", g, 100)
    w.confirm("Priya", e3)
    w.drain()
    assert w.balance("Rahul") == 62


def test_cap_boundary_at_ist_midnight(w):
    set_config({"caps": {"user_daily": 5}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    clock.set_now(clock.ist().replace(hour=23, minute=59, second=0))
    e1 = w.expense("Rahul", g, 100)
    w.confirm("Priya", e1)
    w.drain()
    e2 = w.expense("Rahul", g, 100)
    w.confirm("Priya", e2)
    w.drain()
    assert w.balance("Rahul") == 55  # second earn capped on the same IST day
    clock.travel(timedelta(minutes=2))  # 00:01 IST next day
    e3 = w.expense("Rahul", g, 100)
    w.confirm("Priya", e3)
    w.drain()
    assert w.balance("Rahul") == 60


def test_cap_user_monthly(w):
    set_config({"caps": {"user_monthly": 6, "user_daily": 100}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    for _ in range(2):
        e = w.expense("Rahul", g, 100)
        w.confirm("Priya", e)
        w.drain()
    assert w.balance("Rahul") == 56
    assert w.req("Rahul", "GET", "/coins/wallet")["cap_notice"]["cap_key"] == "cap_user_monthly"


def test_cap_group_daily_rewarded_expenses(w):
    set_config({"caps": {"group_daily_rewarded_expenses": 2, "user_daily": 1000}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    for _ in range(3):
        e = w.expense("Rahul", g, 100)
        w.confirm("Priya", e)
    w.drain()
    assert [x["reason_code"] for x in w.entries("Rahul")].count("EXPENSE_ADDER") == 2


def test_cap_pair_daily_confirmations(w):
    set_config({"caps": {"pair_daily_confirmations": 2, "user_daily": 1000}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    eids = [w.expense("Rahul", g, 100) for _ in range(3)]
    w.drain()
    for e in eids[:2]:
        w.confirm("Priya", e)
    w.drain()
    preview = w.req("Priya", "GET", f"/expenses/{eids[2]}")["confirmation"]["reward_preview"]
    assert preview["coins"] == 0 and preview["capped_reason"] == "cap_pair_daily_confirmations"
    w.confirm("Priya", eids[2])
    w.drain()
    assert [x["reason_code"] for x in w.entries("Priya")].count("EXPENSE_CONFIRMER") == 2


def test_caps_never_block_core_action(w):
    set_config({"caps": {"user_daily": 0}})
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 100)
    out = w.confirm("Priya", e)
    assert out["confirmation"]["status"] == "CONFIRMED"
    assert out["reward_preview"]["capped_reason"] == "cap_user_daily"


def test_settlement_rewards_quick_bonus_and_threshold(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Priya", g, 900)  # Rahul owes Priya 450
    w.confirm("Rahul", e)
    w.drain()
    p = w.pay("Rahul", g, "Priya", 450)
    pay = w.req("Rahul", "GET", f"/groups/{g}")["payments"][0]
    assert pay["confirmation"]["status"] == "PENDING"
    w.receipt("Priya", p)
    w.drain()
    rs = w.reasons("Rahul")
    assert ("SETTLE_PAYER", 20) in rs and ("SETTLE_QUICK_BONUS", 10) in rs
    assert ("SETTLE_RECEIVER", 10) in w.reasons("Priya")
    cel = w.req("Rahul", "GET", "/coins/celebrations")["celebrations"]
    assert cel[-1]["coins"] == 30 and "same day" in cel[-1]["title"]


def test_settlement_no_quick_bonus_after_48h(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Priya", g, 900)
    w.confirm("Rahul", e)
    w.drain()
    clock.travel(timedelta(hours=49))
    p = w.pay("Rahul", g, "Priya", 450)
    w.receipt("Priya", p)
    w.drain()
    rs = w.reasons("Rahul")
    assert ("SETTLE_PAYER", 20) in rs and not [r for r in rs if r[0] == "SETTLE_QUICK_BONUS"]


def test_small_payment_only_rewarded_when_it_clears_balance(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Priya", g, 120)  # Rahul owes 60
    w.drain()
    p = w.pay("Rahul", g, "Priya", 40)  # < 50 and does not clear
    w.receipt("Priya", p)
    w.drain()
    assert not [x for x in w.entries("Rahul") if x["reason_code"] == "SETTLE_PAYER"]
    p2 = w.pay("Rahul", g, "Priya", 20)  # < 50 but clears the pair
    w.receipt("Priya", p2)
    w.drain()
    assert [x for x in w.entries("Rahul") if x["reason_code"] == "SETTLE_PAYER"]


def test_payment_unverified_after_7_days(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    p = w.pay("Rahul", g, "Priya", 500)
    clock.travel(timedelta(days=8))
    jobs.mark_unverified()
    w.receipt("Priya", p, expect=409)
    assert w.req("Rahul", "GET", f"/groups/{g}")["payments"][0]["confirmation"]["status"] == "UNVERIFIED"
    w.drain()
    assert w.entries("Rahul") == []


def test_payment_rejected_notifies_payer_and_no_coins(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    p = w.pay("Rahul", g, "Priya", 500)
    w.receipt("Priya", p, status="REJECTED")
    w.drain()
    assert w.entries("Rahul") == []
    with db.tx() as c:
        body = c.execute("SELECT body FROM notifications WHERE user_id=%s AND notification_id='N9'", (w.ids["Rahul"],)).fetchone()["body"]
    assert "hasn't received it yet" in body


def test_only_receiver_can_confirm_payment(w):
    w.user("Rahul"); w.user("Priya"); w.user("Aman")
    g = w.flat("Rahul", "Priya", "Aman")
    p = w.pay("Rahul", g, "Priya", 500)
    w.receipt("Aman", p, expect=403)
    w.receipt("Rahul", p, expect=403)


def test_surprise_bonus_is_separate_entry(w, monkeypatch):
    from app import engine
    monkeypatch.setattr(engine, "surprise_draw", lambda pid, cfg: (0.01, 3))
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Priya", g, 900)
    w.confirm("Rahul", e)
    w.drain()
    p = w.pay("Rahul", g, "Priya", 450)
    w.receipt("Priya", p)
    w.drain()
    bonus = [x for x in w.entries("Rahul") if x["reason_code"] == "SURPRISE_BONUS"]
    assert len(bonus) == 1 and bonus[0]["amount"] == 60  # 3x of 30 adds 60
    cel = w.req("Rahul", "GET", "/coins/celebrations")["celebrations"][-1]
    assert cel["bonus_multiplier"] == 3 and cel["bonus_coins"] == 60


def test_surprise_draw_boundaries_and_determinism():
    from app import engine
    from app.coin_config import Config, DEFAULT_CONFIG
    cfg = Config(1, DEFAULT_CONFIG)
    assert engine.multiplier_for(0.0499999, cfg) == 3
    assert engine.multiplier_for(0.05, cfg) == 2
    assert engine.multiplier_for(0.1999999, cfg) == 2
    assert engine.multiplier_for(0.20, cfg) == 1
    assert engine.surprise_draw(42, cfg) == engine.surprise_draw(42, cfg)
    hits = sum(engine.surprise_draw(i, cfg)[1] > 1 for i in range(5000)) / 5000
    assert 0.17 < hits < 0.23
    assert engine.multiplier_for(0.0, Config(2, {**DEFAULT_CONFIG, "surprise": {"p_any": 0, "p_2x": 0, "p_3x": 0}})) == 1
