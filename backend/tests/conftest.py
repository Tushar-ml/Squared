import os
import uuid
from datetime import timedelta

import pytest

os.environ["APP_ENV"] = "test"
os.environ.setdefault("SURPRISE_SECRET", "test-secret")

from fastapi.testclient import TestClient  # noqa: E402

from app import clock, coin_config, db, jobs, redemption, seed  # noqa: E402
from app.main import app  # noqa: E402

TEST_URL = os.environ.get("TEST_DATABASE_URL", "postgresql://coins:coins@localhost:5433/coins_test")


@pytest.fixture(scope="session", autouse=True)
def _schema():
    db.init_pool(TEST_URL, size=12)
    with db.tx() as c:
        c.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")
    db.migrate()
    yield


TABLES = None


@pytest.fixture(autouse=True)
def _clean(monkeypatch):
    global TABLES
    clock.reset()
    coin_config.invalidate()
    with db.tx() as c:
        if TABLES is None:
            TABLES = [r["tablename"] for r in c.execute(
                "SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename <> 'schema_migrations'")]
        c.execute("ALTER TABLE coin_ledger DISABLE TRIGGER coin_ledger_guard_trg")
        c.execute("TRUNCATE " + ", ".join(TABLES) + " RESTART IDENTITY CASCADE")
        c.execute("ALTER TABLE coin_ledger ENABLE TRIGGER coin_ledger_guard_trg")
    # tests run at a fixed daytime IST moment unless they travel
    clock.set_now(clock.ist().replace(hour=12, minute=0, second=0, microsecond=0).astimezone(clock.IST))
    seed.ensure_base()
    set_config({"experiment": {"treatment_share": 1.0}, "redemption": {"enabled": True}})
    monkeypatch.setattr(redemption, "vendor", FakeVendor())
    from app import fx
    monkeypatch.setattr(fx, "FETCHERS", [FakeFx.fetch])   # never hit the network in tests
    FakeFx.reset()
    yield
    clock.reset()


class FakeVendor:
    def __init__(self):
        self.mode = "ok"
        self.calls = 0

    def issue(self, sku, reference):
        self.calls += 1
        if self.mode == "fail":
            import httpx
            raise httpx.ConnectError("vendor down")
        return {"vendor_ref": "V-" + reference[:6], "code": "CODE-" + reference[:4].upper()}


class FakeFx:
    """Deterministic rates. USD 1 = INR 96.32 etc. Flip `fail` to simulate an outage."""
    DEFAULT = {"INR": 1.0, "USD": 96.32, "EUR": 104.5, "GBP": 121.0, "AED": 26.22, "JPY": 0.64, "SGD": 72.0}
    INR_PER = dict(DEFAULT)
    fail = False
    calls = 0

    @classmethod
    def reset(cls):
        cls.fail = False
        cls.calls = 0
        cls.INR_PER = dict(cls.DEFAULT)

    @classmethod
    def fetch(cls, base):
        cls.calls += 1
        if cls.fail:
            raise RuntimeError("fx down")
        from datetime import datetime, timezone
        b = cls.INR_PER[base]
        return {q: b / v for q, v in cls.INR_PER.items()}, datetime(2026, 10, 2, tzinfo=timezone.utc), "fake"


def set_config(patch):
    with db.tx() as c:
        coin_config.publish(c, patch, None)
    coin_config.invalidate()


@pytest.fixture
def client():
    return TestClient(app)


class World:
    """Helpers that drive the public API like the iOS client would."""

    def __init__(self, client):
        self.c = client
        self.tokens = {}
        self.ids = {}
        self.emails = {}

    def user(self, name, *, age_days=30, device=None, verified=True):
        email = f"{name.lower()}@example.com"
        with db.tx() as c:
            uid = c.execute(
                "INSERT INTO users (name, email, verified, device_fingerprint, created_at) VALUES (%s,%s,%s,%s,%s) RETURNING id",
                (name, email, verified, device or f"dev-{name}",
                 clock.now() - timedelta(days=age_days))).fetchone()["id"]
            tok = uuid.uuid4().hex
            c.execute("INSERT INTO sessions (token, user_id) VALUES (%s,%s)", (tok, uid))
        self.tokens[name] = tok
        self.ids[name] = uid
        self.emails[name] = email
        return uid

    def h(self, name, **extra):
        return {"Authorization": "Bearer " + self.tokens[name], **extra}

    def req(self, name, method, path, json=None, expect=200, **headers):
        r = self.c.request(method, "/api/v1" + path, json=json, headers=self.h(name, **headers))
        assert r.status_code == expect, (r.status_code, r.text)
        return r.json()

    def flat(self, owner, *others, group_type="HOME", name="Flat 4B"):
        g = self.req(owner, "POST", "/groups", {"name": name, "group_type": group_type, "expected_members": 4})
        with db.tx() as c:
            for o in others:
                c.execute("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (%s,%s,%s)",
                          (g["id"], self.ids[o], clock.now()))
        return g["id"]

    def expense(self, adder, gid, amount_inr=300, participants=None, desc="Groceries", paid_by=None):
        body = {"description": desc, "amount_paise": int(amount_inr * 100)}
        if participants:
            body["participants"] = [self.ids[p] for p in participants]
        if paid_by:
            body["paid_by"] = self.ids[paid_by]
        return self.req(adder, "POST", f"/groups/{gid}/expenses", body)["id"]

    def confirm(self, who, eid, expect=200, status="CONFIRMED", reason=None):
        return self.req(who, "POST", f"/expenses/{eid}/confirmations", {"status": status, "reason": reason}, expect=expect)

    def pay(self, payer, gid, receiver, amount_inr):
        return self.req(payer, "POST", f"/groups/{gid}/payments",
                        {"receiver_id": self.ids[receiver], "amount_paise": int(amount_inr * 100)})["id"]

    def receipt(self, receiver, pid, status="CONFIRMED", expect=200):
        return self.req(receiver, "POST", f"/payments/{pid}/confirmation", {"status": status}, expect=expect)

    def drain(self):
        while jobs.drain_outbox():
            pass

    def balance(self, name):
        return self.req(name, "GET", "/coins/wallet")["balance"]

    def entries(self, name):
        return self.req(name, "GET", "/coins/ledger?limit=100")["entries"]

    def reasons(self, name):
        return sorted((e["reason_code"], e["amount"]) for e in self.entries(name))


@pytest.fixture
def w(client):
    return World(client)


def all_integrity_ok():
    with db.tx() as c:
        from app import ledger
        bad = [ledger.integrity(c, r["id"]) for r in c.execute("SELECT id FROM wallets")]
    return [b for b in bad if b] == []
