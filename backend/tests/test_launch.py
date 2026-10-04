"""Launch hardening: redemption switch, account deletion, OTP abuse limits, production guard."""
from datetime import timedelta

import pytest

from app import clock, coin_config, db
from app.settings import Settings
from conftest import set_config


def _redeem(w, name, expect=200):
    item = w.req(name, "GET", "/coins/catalog")["items"][0]["id"]
    return w.req(name, "POST", "/coins/redemptions", {"catalog_item_id": item}, expect=expect,
                 **{"Idempotency-Key": f"k-{name}"})


# ---------------------------------------------------------------- redemption switch

def test_redemption_is_off_by_default_and_says_coming_soon(w):
    assert coin_config.DEFAULT_CONFIG["redemption"]["enabled"] is False
    set_config({"redemption": {"enabled": False}})
    w.user("Aman", age_days=60)
    r = _redeem(w, "Aman", expect=403)
    assert r["detail"]["code"] == "coming_soon" and "coming soon" in r["detail"]["message"].lower()
    cat = w.req("Aman", "GET", "/coins/catalog")
    assert cat["redemption_enabled"] is False
    assert w.req("Aman", "GET", "/config/coins")["redemption"]["enabled"] is False


def test_no_redeem_push_while_redemption_is_off(w):
    set_config({"redemption": {"enabled": False}})
    w.user("Aman"); w.user("Priya")
    g = w.flat("Aman", "Priya")
    for i in range(12):                      # well past the first-redeem threshold
        w.confirm("Priya", w.expense("Aman", g, 300, desc=f"Bill {i}"))
    with db.tx() as c:
        assert c.execute("SELECT count(*) n FROM notifications WHERE notification_id='N6'").fetchone()["n"] == 0


# ---------------------------------------------------------------- account deletion

def test_delete_account_needs_settled_balances(w):
    w.user("Aman"); w.user("Priya")
    g = w.flat("Aman", "Priya")
    w.confirm("Priya", w.expense("Aman", g, 300))          # Priya owes Aman 150
    r = w.req("Priya", "DELETE", "/me", expect=409)
    assert "settle" in r["detail"].lower()
    w.req("Aman", "DELETE", "/me", expect=409)              # being owed also blocks: they'd lose track of it


def test_delete_account_anonymises_and_frees_the_phone(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.expense("Aman", g, 300)
    w.confirm("Priya", e)
    w.pay("Priya", g, "Aman", 150)
    phone = w.phones["Priya"]
    w.req("Priya", "DELETE", "/me")
    w.req("Priya", "GET", "/me", expect=401)                 # sessions gone
    with db.tx() as c:
        u = c.execute("SELECT * FROM users WHERE id=%s", (b,)).fetchone()
        assert u["deleted_at"] is not None and u["phone"] != phone and u["email"] is None and u["upi_id"] is None
        assert u["name"] == "Deleted user"
        assert c.execute("SELECT left_at FROM group_members WHERE group_id=%s AND user_id=%s", (g, b)).fetchone()["left_at"]
        assert c.execute("SELECT count(*) n FROM devices WHERE user_id=%s", (b,)).fetchone()["n"] == 0
    # the group keeps its history, shown with a neutral name
    d = w.req("Aman", "GET", f"/groups/{g}")
    assert d["payments"][0]["payer_name"] == "Deleted user"
    assert d["my_net_paise"] == 0 and [m["name"] for m in d["members"]] == ["Aman"]
    # the same number can sign up again as a brand-new account
    r = w.c.post("/api/v1/auth/otp/request", json={"phone": phone})
    assert r.status_code == 200
    _ = a


# ---------------------------------------------------------------- OTP abuse limits

def _otp(w, phone, ip="10.0.0.1"):
    return w.c.post("/api/v1/auth/otp/request", json={"phone": phone}, headers={"X-Forwarded-For": ip})


def _verify(w, phone, code):
    return w.c.post("/api/v1/auth/otp/verify", json={"phone": phone, "otp": code})


def test_otp_send_is_rate_limited_per_phone(w):
    phone = "+919111100001"
    assert _otp(w, phone).status_code == 200
    r = _otp(w, phone)
    assert r.status_code == 429 and "wait" in r.json()["detail"].lower()
    for _ in range(4):                                    # 1 per 30s, 5 per hour
        clock.travel(timedelta(seconds=31))
        assert _otp(w, phone).status_code == 200
    clock.travel(timedelta(seconds=31))
    assert _otp(w, phone).status_code == 429
    clock.travel(timedelta(hours=1))
    assert _otp(w, phone).status_code == 200


def test_otp_send_is_rate_limited_per_ip(w, monkeypatch):
    from app import api_core
    monkeypatch.setattr(api_core.settings, "trust_proxy", True)
    for i in range(20):
        assert _otp(w, f"+9191111{i:05d}", ip="203.0.113.9").status_code == 200
    assert _otp(w, "+919111199999", ip="203.0.113.9").status_code == 429
    assert _otp(w, "+919111199999", ip="203.0.113.10").status_code == 200


def test_otp_guesses_are_capped_and_codes_are_stored_hashed(w):
    phone = "+919111100002"
    _otp(w, phone)
    with db.tx() as c:
        row = c.execute("SELECT * FROM otp_codes WHERE phone=%s", (phone,)).fetchone()
    assert row["code"] != "123456" and len(row["code"]) == 64     # sha256 hex, never the code itself
    for _ in range(5):
        assert _verify(w, phone, "000000").status_code == 400
    r = _verify(w, phone, "123456")                                # right code, but too late
    assert r.status_code == 429 and "new code" in r.json()["detail"].lower()
    clock.travel(timedelta(seconds=31))
    _otp(w, phone)
    assert _verify(w, phone, "123456").status_code == 200


# ---------------------------------------------------------------- production guard

def _prod(**env):
    s = Settings()
    s.app_env = "prod"
    s.dev_otp = ""
    s.surprise_secret = s.invite_secret = s.voucher_key = s.otp_secret = "x" * 32
    s.public_base_url = "https://api.squared.example"
    s.storage_backend, s.s3_bucket = "s3", "squared-bills"
    s.support_email, s.apple_team_id = "help@squared.example", "ABCDE12345"
    for k, v in env.items():
        setattr(s, k, v)
    return s


def test_production_guard_lists_every_unsafe_setting():
    assert _prod().production_problems() == []
    problems = _prod(dev_otp="123456", invite_secret="change-me", voucher_key="",
                     public_base_url="http://api.squared.example", storage_backend="local").production_problems()
    text = " ".join(problems)
    assert "DEV_OTP" in text and "INVITE_SECRET" in text and "VOUCHER_KEY" in text and "https" in text
    assert "STORAGE_BACKEND" in text


def test_production_guard_blocks_startup():
    with pytest.raises(RuntimeError):
        _prod(dev_otp="123456").assert_safe_for_production()
    _prod().assert_safe_for_production()
    dev = Settings(); dev.app_env = "dev"; dev.dev_otp = "123456"
    dev.assert_safe_for_production()                               # dev is never blocked


# ---------------------------------------------------------------- bill photos in object storage

def test_bill_photos_round_trip_through_s3(w):
    import boto3
    from moto import mock_aws
    from app import storage
    with mock_aws():
        s3 = boto3.client("s3", region_name="ap-south-1")
        s3.create_bucket(Bucket="squared-bills", CreateBucketConfiguration={"LocationConstraint": "ap-south-1"})
        storage.use(storage.S3Storage("squared-bills", client=s3))
        try:
            w.user("Aman"); w.user("Priya"); w.user("Ravi")
            g = w.flat("Aman", "Priya")
            e = w.expense("Aman", g, 300)
            jpeg = b"\xff\xd8\xff\xe0" + b"x" * 1000
            r = w.c.post(f"/api/v1/expenses/{e}/attachments", content=jpeg,
                         headers=w.h("Aman", **{"Content-Type": "image/jpeg"}))
            assert r.status_code == 200, r.text
            aid = r.json()["id"]
            keys = [o["Key"] for o in s3.list_objects_v2(Bucket="squared-bills")["Contents"]]
            assert keys == [f"{g}/{aid}.jpg"]
            got = w.c.get(f"/api/v1/attachments/{aid}", headers=w.h("Priya"))
            assert got.status_code == 200 and got.content == jpeg and got.headers["content-type"] == "image/jpeg"
            assert w.c.get(f"/api/v1/attachments/{aid}", headers=w.h("Ravi")).status_code == 403   # not in the group
            assert w.c.delete(f"/api/v1/attachments/{aid}", headers=w.h("Aman")).status_code == 200
            assert s3.list_objects_v2(Bucket="squared-bills").get("KeyCount") == 0
        finally:
            storage.use(None)


# ---------------------------------------------------------------- public pages

def test_legal_and_support_pages_render(client, monkeypatch):
    from app import api_coins
    monkeypatch.setattr(api_coins.settings, "support_email", "help@squared.example")
    for path, must in [("/legal/terms", "no cash value"), ("/legal/privacy", "Digital Personal Data Protection Act"),
                       ("/support", "Delete your account")]:
        r = client.get(path)
        assert r.status_code == 200 and must in r.text and "help@squared.example" in r.text, path
        assert "{" not in r.text.split("<main>")[1].split("<footer>")[0], path   # every placeholder filled


def test_universal_links_file(client, monkeypatch):
    from app import api_coins
    monkeypatch.setattr(api_coins.settings, "apple_team_id", "")
    assert client.get("/.well-known/apple-app-site-association").status_code == 404
    monkeypatch.setattr(api_coins.settings, "apple_team_id", "ABCDE12345")
    r = client.get("/.well-known/apple-app-site-association")
    assert r.status_code == 200 and r.headers["content-type"].startswith("application/json")
    d = r.json()["applinks"]["details"][0]
    assert d["appIDs"] == ["ABCDE12345.app.squared.ios"] and d["components"] == [{"/": "/j/*"}]
