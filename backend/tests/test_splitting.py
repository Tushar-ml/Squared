"""Splitting logic: every split type, rounding, balances, edits, multi-currency, insights and reports."""
from datetime import timedelta
from decimal import Decimal

import pytest
from hypothesis import given, settings, strategies as st

from app import clock, db, fx, splits
from conftest import FakeFx


# ---------------------------------------------------------------- pure math

@settings(max_examples=300, deadline=None)
@given(total=st.integers(min_value=1, max_value=10**9),
       weights=st.lists(st.integers(min_value=0, max_value=10**6), min_size=1, max_size=12).filter(lambda w: sum(w) > 0))
def test_allocate_always_sums_exactly_and_is_fair(total, weights):
    out = splits.allocate(total, weights)
    assert sum(out) == total and all(x >= 0 for x in out)
    s = sum(weights)
    for w, x in zip(weights, out):
        exact = Decimal(total) * w / s
        assert abs(Decimal(x) - exact) < 1      # nobody is off by a paisa or more


def test_equal_split_gives_leftover_paise_to_first_people():
    shares, meta = splits.compute(10000, "EQUAL", {1, 2, 3})
    assert shares == {1: 3334, 2: 3333, 3: 3333}
    assert meta == {"participants": [1, 2, 3]}
    assert splits.compute(79900, "EQUAL", {1, 2, 3}, participants=[2, 3])[0] == {2: 39950, 3: 39950}


def test_exact_amounts_must_add_up():
    shares, _ = splits.compute(1000, "EXACT", {1, 2}, exact={1: 700, 2: 300})
    assert shares == {1: 700, 2: 300}
    with pytest.raises(splits.SplitError, match="short by 1.00"):
        splits.compute(1000, "EXACT", {1, 2}, exact={1: 600, 2: 300})
    with pytest.raises(splits.SplitError, match="over by 0.50"):
        splits.compute(1000, "EXACT", {1, 2}, exact={1: 750, 2: 300})


def test_percent_split_with_decimals_and_validation():
    shares, meta = splits.compute(100000, "PERCENT", {1, 2, 3}, percents={1: 50, 2: 30, 3: 20})
    assert shares == {1: 50000, 2: 30000, 3: 20000}
    thirds, _ = splits.compute(100, "PERCENT", {1, 2, 3}, percents={1: 33.33, 2: 33.33, 3: 33.34})
    assert sum(thirds.values()) == 100
    with pytest.raises(splits.SplitError, match="add up to 90%"):
        splits.compute(1000, "PERCENT", {1, 2}, percents={1: 60, 2: 30})


def test_shares_split_by_weight():
    shares, meta = splits.compute(120000, "SHARES", {1, 2, 3}, shares={1: 2, 2: 1, 3: 1})
    assert shares == {1: 60000, 2: 30000, 3: 30000}
    half, _ = splits.compute(1000, "SHARES", {1, 2}, shares={1: 1.5, 2: 0.5})
    assert half == {1: 750, 2: 250}


@pytest.mark.parametrize("kind,kw", [
    ("EQUAL", {"participants": [9]}),
    ("EXACT", {"exact": {1: -100, 2: 1100}}),
    ("PERCENT", {"percents": {1: 120, 2: -20}}),
    ("SHARES", {"shares": {1: 0, 2: 0}}),
])
def test_invalid_splits_are_rejected(kind, kw):
    with pytest.raises(splits.SplitError):
        splits.compute(1000, kind, {1, 2}, **kw)


def test_reallocate_keeps_proportions_across_currencies():
    assert splits.reallocate(96320, {1: 500, 2: 500}) == {1: 48160, 2: 48160}
    out = splits.reallocate(100001, {1: 333, 2: 333, 3: 334})
    assert sum(out.values()) == 100001


def test_fx_conversion_handles_decimals():
    assert fx.convert_minor(1000, "USD", "INR", Decimal("96.32")) == 96320        # $10.00 -> INR 963.20
    assert fx.convert_minor(1000, "JPY", "INR", Decimal("0.64")) == 64000         # ¥1000 -> INR 640.00
    assert fx.convert_minor(96320, "INR", "JPY", Decimal("1.5625")) == 1505        # INR 963.20 -> ¥1505
    assert fx.fmt(96320, "INR") == "INR 963.20" and fx.fmt(1505, "JPY") == "JPY 1,505"


# ---------------------------------------------------------------- through the API

def _debts(w, who, gid):
    return {(d["debtor_id"], d["creditor_id"]): d["amount_paise"] for d in w.req(who, "GET", f"/groups/{gid}")["all_debts"]}


def test_each_split_type_via_api_drives_balances(w):
    a, b, c = w.user("Aman"), w.user("Priya"), w.user("Rahul")
    g = w.flat("Aman", "Priya", "Rahul")
    e1 = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Rent", "amount_paise": 3600000,
                                                         "split_type": "PERCENT", "percents": {a: 40, b: 30, c: 30}})
    assert {s["user_id"]: s["share_paise"] for s in e1["splits"]} == {a: 1440000, b: 1080000, c: 1080000}
    assert e1["split_type"] == "PERCENT" and e1["category"] == "rent"
    w.req("Priya", "POST", f"/groups/{g}/expenses", {"description": "Groceries", "amount_paise": 120000,
                                                     "split_type": "SHARES", "shares": {a: 1, b: 1, c: 2}})
    w.req("Rahul", "POST", f"/groups/{g}/expenses", {"description": "Wifi bill", "amount_paise": 79900,
                                                     "split_type": "EXACT", "exact": {a: 30000, b: 29900, c: 20000}})
    d = _debts(w, "Aman", g)
    # Priya owes Aman 10,800 (rent) ; Aman owes Priya 300 (groceries) -> net 10,500
    assert d[(b, a)] == 1080000 - 30000
    # Rahul owes Aman 10,800 ; Aman owes Rahul 300 (wifi) -> 10,500
    assert d[(c, a)] == 1080000 - 30000
    # Rahul owes Priya 600 (groceries) ; Priya owes Rahul 299 (wifi) -> 301
    assert d[(c, b)] == 60000 - 29900
    # every user's net sums to zero across the group
    nets = {}
    for (x, y), v in d.items():
        nets[x] = nets.get(x, 0) - v
        nets[y] = nets.get(y, 0) + v
    assert sum(nets.values()) == 0
    # a payment settles exactly
    w.pay("Rahul", g, "Priya", 301)
    assert (c, b) not in _debts(w, "Aman", g)


def test_split_validation_errors_reach_the_client(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    r = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "X", "amount_paise": 1000,
                                                        "split_type": "PERCENT", "percents": {a: 50, b: 40}}, expect=400)
    assert "90%" in r["detail"]
    w.user("Stranger")
    r = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "X", "amount_paise": 1000, "split_type": "EXACT",
                                                        "exact": {a: 500, w.ids["Stranger"]: 500}}, expect=400)
    assert "in the group" in r["detail"]


def test_legacy_shares_field_means_exact_paise(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Old client", "amount_paise": 1000,
                                                        "shares": {a: 600, b: 400}})
    assert e["split_type"] == "EXACT" and {s["user_id"]: s["share_paise"] for s in e["splits"]} == {a: 600, b: 400}


def test_edit_reruns_stored_split_and_resets_confirmation(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Electricity", "amount_paise": 100000,
                                                        "split_type": "PERCENT", "percents": {a: 70, b: 30}})
    w.confirm("Priya", e["id"])
    out = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"amount_paise": 200000})
    assert {s["user_id"]: s["share_paise"] for s in out["splits"]} == {a: 140000, b: 60000}
    assert out["version"] == 2 and out["confirmation"]["status"] == "WAITING"
    out = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"split_type": "SHARES", "shares": {a: 1, b: 1}})
    assert {s["user_id"]: s["share_paise"] for s in out["splits"]} == {a: 100000, b: 100000} and out["version"] == 3
    out = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"category": "utilities", "description": "Power bill"})
    assert out["version"] == 3  # no money change, no reset


def test_exact_split_edit_requires_new_amounts(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "X", "amount_paise": 1000, "split_type": "EXACT",
                                                        "exact": {a: 700, b: 300}})
    w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"amount_paise": 2000}, expect=400)
    ok = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"amount_paise": 2000, "exact": {a: 1500, b: 500}})
    assert ok["amount_paise"] == 2000


# ---------------------------------------------------------------- multi-currency

def test_foreign_currency_expense_converts_at_snapshot_rate(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Hotel in Dubai", "amount_paise": 50000,
                                                        "currency": "AED"})   # AED 500
    assert e["original_currency"] == "AED" and e["original_amount_minor"] == 50000
    assert e["amount_paise"] == 1311000 and e["currency"] == "INR"            # 500 * 26.22
    assert sum(s["share_paise"] for s in e["splits"]) == e["amount_paise"]
    # market moves; existing expense keeps its rate, even when the amount is edited
    FakeFx.INR_PER["AED"] = 30.0
    clock.travel(timedelta(hours=2))
    out = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"amount_paise": 100000})
    assert out["amount_paise"] == 2622000 and abs(out["fx_rate"] - 26.22) < 1e-9
    # switching currency uses today's rate
    out = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"currency": "USD", "amount_paise": 1000})
    assert out["amount_paise"] == 96320 and out["original_currency"] == "USD"
    # back to the group currency clears the originals
    out = w.req("Aman", "PATCH", f"/expenses/{e['id']}", {"currency": "INR", "amount_paise": 50000})
    assert out["original_currency"] is None and out["amount_paise"] == 50000


def test_foreign_exact_split_is_scaled_to_group_currency(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Dinner", "amount_paise": 1001, "currency": "USD",
                                                        "split_type": "EXACT", "exact": {a: 501, b: 500}})
    shares = {s["user_id"]: s["share_paise"] for s in e["splits"]}
    assert sum(shares.values()) == e["amount_paise"] == 96416        # 10.01 * 96.32 = 964.1632
    assert shares[a] > shares[b]


def test_non_inr_expenses_earn_no_coins(w):
    w.user("Aman"); w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Souvenirs", "amount_paise": 5000, "currency": "USD"})
    assert e["confirmation"]["adder_reward"] == 0
    w.confirm("Priya", e["id"])
    w.drain()
    assert not [x for x in w.entries("Aman") if x["reason_code"] == "EXPENSE_ADDER"]


def test_group_in_other_currency(w):
    a, b = w.user("Aman"), w.user("Priya")
    gid = w.req("Aman", "POST", "/groups", {"name": "London trip", "group_type": "TRIP", "currency": "GBP"})["id"]
    with db.tx() as c:
        c.execute("INSERT INTO group_members (group_id, user_id) VALUES (%s,%s)", (gid, b))
    e = w.req("Aman", "POST", f"/groups/{gid}/expenses", {"description": "Tube", "amount_paise": 2000})
    assert e["currency"] == "GBP" and e["original_currency"] is None
    e2 = w.req("Aman", "POST", f"/groups/{gid}/expenses", {"description": "Snacks", "amount_paise": 121000, "currency": "INR"})
    assert e2["amount_paise"] == 1000    # INR 1,210 = GBP 10.00


def test_fx_rates_cache_and_fallback(w):
    w.user("Aman")
    r = w.req("Aman", "GET", "/fx/rates?base=USD")
    assert abs(r["rates"]["INR"] - 96.32) < 1e-9 and r["stale"] is False
    calls = FakeFx.calls
    w.req("Aman", "GET", "/fx/rates?base=USD")
    assert FakeFx.calls == calls                     # served from the hourly cache
    clock.travel(timedelta(hours=2))
    FakeFx.fail = True
    r = w.req("Aman", "GET", "/fx/rates?base=USD")
    assert r["stale"] is True and abs(r["rates"]["INR"] - 96.32) < 1e-9   # last known rates
    w.req("Aman", "GET", "/fx/rates?base=EUR", expect=503)                  # never fetched, provider down
    assert len(w.req("Aman", "GET", "/fx/currencies")["currencies"]) == len(fx.SUPPORTED)


# ---------------------------------------------------------------- insights & reports

def test_group_insights_per_user_and_categories(w):
    a, b, c = w.user("Aman"), w.user("Priya"), w.user("Rahul")
    g = w.flat("Aman", "Priya", "Rahul")
    w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Rent", "amount_paise": 3000000})
    w.req("Priya", "POST", f"/groups/{g}/expenses", {"description": "Zepto groceries", "amount_paise": 90000})
    w.req("Rahul", "POST", f"/groups/{g}/expenses", {"description": "Swiggy dinner", "amount_paise": 60000,
                                                     "split_type": "EXACT", "exact": {c: 60000}})
    ins = w.req("Priya", "GET", f"/groups/{g}/insights")
    assert ins["total_spend"] == 3150000 and ins["expense_count"] == 3
    m = {x["user_id"]: x for x in ins["members"]}
    assert m[a]["paid"] == 3000000 and m[a]["share"] == 1030000
    assert m[c]["share"] == 1000000 + 30000 + 60000 and m[b]["is_you"]
    assert sum(x["net"] for x in ins["members"]) == 0
    assert [x["category"] for x in ins["categories"]] == ["rent", "groceries", "food"]
    assert ins["trend"][-1]["total"] == 3150000 and ins["trend"][-1]["my_share"] == 1030000
    assert ins["top_expenses"][0]["description"] == "Rent"
    last = (clock.ist().date().replace(day=1) - timedelta(days=1)).strftime("%Y-%m")
    assert w.req("Priya", "GET", f"/groups/{g}/insights?month={last}")["total_spend"] == 0


def test_my_insights_converts_across_groups(w):
    a, b = w.user("Aman"), w.user("Priya")
    home = w.flat("Aman", "Priya")
    trip = w.req("Aman", "POST", "/groups", {"name": "Goa", "group_type": "TRIP", "currency": "USD"})["id"]
    with db.tx() as c:
        c.execute("INSERT INTO group_members (group_id, user_id) VALUES (%s,%s)", (trip, b))
    w.req("Aman", "POST", f"/groups/{home}/expenses", {"description": "Wifi", "amount_paise": 100000})   # my share 500
    w.req("Aman", "POST", f"/groups/{trip}/expenses", {"description": "Boat", "amount_paise": 2000})     # my share $10
    r = w.req("Aman", "GET", "/me/insights?currency=INR")
    assert r["total_share"] == 50000 + 96320
    assert {g["group_name"] for g in r["by_group"]} == {"Flat 4B", "Goa"}
    usd = w.req("Aman", "GET", "/me/insights?currency=USD")
    assert usd["currency"] == "USD" and usd["total_share"] == 1519   # $5.19 + $10.00


def test_monthly_report_csv(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    w.req("Aman", "POST", f"/groups/{g}/expenses", {"description": "Rent", "amount_paise": 3000000,
                                                    "split_type": "PERCENT", "percents": {a: 60, b: 40}})
    w.req("Priya", "POST", f"/groups/{g}/expenses", {"description": "Duty free", "amount_paise": 10000, "currency": "AED"})
    w.pay("Priya", g, "Aman", 5000)
    r = w.c.get(f"/api/v1/groups/{g}/report", headers=w.h("Aman"))
    assert r.status_code == 200 and r.headers["content-type"].startswith("text/csv")
    text = r.text
    assert "Flat 4B statement" in text and "Aman share" in text and "Priya share" in text
    assert "30000.00,,Percent,18000.00,12000.00" in text
    assert "AED 100.00 @ 26.2200" in text
    assert "Payments" in text and "Outstanding balances today" in text
