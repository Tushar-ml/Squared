"""Ledger invariants: property tests, idempotency replay, concurrency, expiry (PRD 8.12)."""
import random
import threading
import uuid
from datetime import timedelta

import pytest
from hypothesis import HealthCheck, given, settings, strategies as st

from app import clock, coin_config, db, ledger
from conftest import all_integrity_ok


def _cfg():
    return coin_config.current(fresh=True)


def _check(conn, wid):
    assert ledger.integrity(conn, wid) is None
    w = conn.execute("SELECT * FROM wallets WHERE id=%s", (wid,)).fetchone()
    posted = conn.execute("SELECT COALESCE(SUM(amount),0) s FROM coin_ledger WHERE wallet_id=%s AND status='POSTED'", (wid,)).fetchone()["s"]
    lots = conn.execute("SELECT COALESCE(SUM(remaining),0) s FROM coin_lots WHERE wallet_id=%s", (wid,)).fetchone()["s"]
    assert posted == w["balance_cached"]
    assert lots == w["balance_cached"] + w["deficit"]


ops = st.lists(st.tuples(st.sampled_from(["earn", "spend", "reverse", "expire", "refund", "pending", "release"]),
                         st.integers(min_value=1, max_value=60)), min_size=1, max_size=40)


@settings(max_examples=40, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture])
@given(seq=ops)
def test_property_invariants_hold_for_any_sequence(seq):
    cfg = _cfg()
    owner = random.randint(10**6, 10**9)
    with db.tx() as conn:
        w = ledger.get_wallet(conn, "USER", owner)
        earns, spends, pend = [], [], []
        for i, (op, n) in enumerate(seq):
            src = uuid.uuid4().hex
            if op == "earn":
                e = ledger.earn(conn, w, amount=n, reason="TEST", source_type="T", source_id=src, source_version=1, cfg=cfg)
                earns.append(e)
            elif op == "pending":
                pend.append(ledger.earn(conn, w, amount=n, reason="TEST", source_type="T", source_id=src, source_version=1,
                                        cfg=cfg, pending=True))
            elif op == "release" and pend:
                ledger.release_pending(conn, pend.pop()["id"], cfg)
            elif op == "spend":
                cur = conn.execute("SELECT * FROM wallets WHERE id=%s FOR UPDATE", (w["id"],)).fetchone()
                if cur["deficit"] == 0 and cur["balance_cached"] >= n:
                    rid = uuid.uuid4()
                    ledger.spend(conn, w["id"], n, redemption_id=rid, cfg=cfg)
                    spends.append(rid)
            elif op == "refund" and spends:
                ledger.refund(conn, w["id"], redemption_id=spends.pop(), cfg=cfg)
            elif op == "reverse" and earns:
                ledger.reverse(conn, earns.pop(n % len(earns)), reason="test", cfg=cfg)
            elif op == "expire":
                clock.travel(timedelta(days=400))
                ledger.expire_due(conn, cfg)
            _check(conn, w["id"])
        neg = conn.execute("SELECT count(*) c FROM coin_lots WHERE remaining < 0").fetchone()["c"]
        assert neg == 0
    clock.reset()


def test_spend_is_fifo_by_expiry_and_expiry_job(w):
    cfg = _cfg()
    with db.tx() as conn:
        wal = ledger.get_wallet(conn, "USER", 999)
        ledger.earn(conn, wal, amount=40, reason="OLD", source_type="T", source_id="a", source_version=1, cfg=cfg)
        clock.travel(timedelta(days=30))
        ledger.earn(conn, wal, amount=60, reason="NEW", source_type="T", source_id="b", source_version=1, cfg=cfg)
        ledger.spend(conn, wal["id"], 50, redemption_id=uuid.uuid4(), cfg=cfg)
        lots = conn.execute("SELECT earned_amount, remaining FROM coin_lots WHERE wallet_id=%s ORDER BY expires_at", (wal["id"],)).fetchall()
        assert [(l["earned_amount"], l["remaining"]) for l in lots] == [(40, 0), (60, 50)]
        clock.travel(timedelta(days=365))
        assert ledger.expire_due(conn, cfg) == 1
        _check(conn, wal["id"])
        assert conn.execute("SELECT balance_cached FROM wallets WHERE id=%s", (wal["id"],)).fetchone()["balance_cached"] == 0


def test_ledger_is_append_only():
    cfg = _cfg()
    with db.tx() as conn:
        wal = ledger.get_wallet(conn, "USER", 1234)
        e = ledger.earn(conn, wal, amount=5, reason="T", source_type="T", source_id="x", source_version=1, cfg=cfg)
    with pytest.raises(Exception):
        with db.tx() as conn:
            conn.execute("UPDATE coin_ledger SET amount=500 WHERE id=%s", (e["id"],))
    with pytest.raises(Exception):
        with db.tx() as conn:
            conn.execute("DELETE FROM coin_ledger WHERE id=%s", (e["id"],))


def test_every_entry_stores_config_version(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    e = w.expense("Rahul", g, 300)
    w.confirm("Priya", e)
    w.drain()
    with db.tx() as c:
        versions = {r["config_version"] for r in c.execute("SELECT config_version FROM coin_ledger")}
        cur = coin_config.current(c, fresh=True).version
    assert versions == {cur}


def _ledger_snapshot():
    with db.tx() as c:
        return sorted((r["idempotency_key"], r["amount"], r["status"]) for r in c.execute("SELECT * FROM coin_ledger"))


def test_replay_three_times_and_shuffled_is_identical(w):
    for n in ("Rahul", "Priya", "Aman"):
        w.user(n)
    g = w.flat("Rahul", "Priya", "Aman")
    e1 = w.expense("Rahul", g, 600)
    e2 = w.expense("Priya", g, 900)
    w.confirm("Priya", e1); w.confirm("Aman", e1); w.confirm("Rahul", e2)
    w.req("Rahul", "PATCH", f"/expenses/{e1}", {"amount_paise": 70000})
    w.confirm("Priya", e1)
    p = w.pay("Aman", g, "Priya", 300)
    w.receipt("Priya", p)
    w.drain()
    clean = _ledger_snapshot()
    from app import engine
    with db.tx() as c:
        evs = c.execute("SELECT event_type, payload FROM outbox_events ORDER BY id").fetchall()
    for _ in range(3):
        for ev in evs:
            with db.tx() as c:
                engine.process(c, ev["event_type"], ev["payload"])
    random.seed(7)
    shuffled = evs[:]
    random.shuffle(shuffled)
    for ev in shuffled:
        with db.tx() as c:
            engine.process(c, ev["event_type"], ev["payload"])
    assert _ledger_snapshot() == clean
    assert all_integrity_ok()


def test_concurrent_confirmations_pay_adder_once(w):
    for n in ("Rahul", "Priya", "Aman"):
        w.user(n)
    g = w.flat("Rahul", "Priya", "Aman")
    e = w.expense("Rahul", g, 600)
    barrier = threading.Barrier(2)

    def go(name):
        barrier.wait()
        w.confirm(name, e)

    ts = [threading.Thread(target=go, args=(n,)) for n in ("Priya", "Aman")]
    [t.start() for t in ts]
    [t.join() for t in ts]
    # two workers drain concurrently
    from app import jobs
    ws = [threading.Thread(target=jobs.drain_outbox) for _ in range(3)]
    [t.start() for t in ws]
    [t.join() for t in ws]
    w.drain()
    assert [x["reason_code"] for x in w.entries("Rahul")].count("EXPENSE_ADDER") == 1
    assert all_integrity_ok()


def test_concurrent_redemptions_cannot_overspend(w):
    from conftest import set_config
    set_config({"redemption": {"first_redemption_hold_hours": 0, "max_per_user_per_week": 10}})
    w.user("Rahul")
    cfg = _cfg()
    with db.tx() as c:
        wal = ledger.get_wallet(c, "USER", w.ids["Rahul"])
        ledger.earn(c, wal, amount=150, reason="T", source_type="T", source_id="s", source_version=1, cfg=cfg)
        item = c.execute("SELECT id FROM catalog_items WHERE coin_cost=100 AND scope='USER'").fetchone()["id"]
    results = []
    barrier = threading.Barrier(2)

    def go(k):
        barrier.wait()
        r = w.c.post("/api/v1/coins/redemptions", json={"catalog_item_id": str(item)},
                     headers=w.h("Rahul", **{"Idempotency-Key": k}))
        results.append(r.status_code)

    ts = [threading.Thread(target=go, args=(f"k{i}",)) for i in range(2)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted(results) == [200, 400]
    assert w.balance("Rahul") == 50
    assert all_integrity_ok()
