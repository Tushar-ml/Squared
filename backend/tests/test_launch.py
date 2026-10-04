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


def test_delete_account_anonymises_and_frees_the_email(w):
    a, b = w.user("Aman"), w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.expense("Aman", g, 300)
    w.confirm("Priya", e)
    w.pay("Priya", g, "Aman", 150)
    email = "priya@example.com"
    with db.tx() as c:
        c.execute("UPDATE users SET google_sub='g-priya' WHERE id=%s", (b,))
    w.req("Priya", "DELETE", "/me")
    w.req("Priya", "GET", "/me", expect=401)                 # sessions gone
    with db.tx() as c:
        u = c.execute("SELECT * FROM users WHERE id=%s", (b,)).fetchone()
        assert u["deleted_at"] is not None and u["email"] is None and u["upi_id"] is None and u["google_sub"] is None
        assert u["name"] == "Deleted user"
        assert c.execute("SELECT left_at FROM group_members WHERE group_id=%s AND user_id=%s", (g, b)).fetchone()["left_at"]
        assert c.execute("SELECT count(*) n FROM devices WHERE user_id=%s", (b,)).fetchone()["n"] == 0
    # the group keeps its history, shown with a neutral name
    d = w.req("Aman", "GET", f"/groups/{g}")
    assert d["payments"][0]["payer_name"] == "Deleted user"
    assert d["my_net_paise"] == 0 and [m["name"] for m in d["members"]] == ["Aman"]
    # the same person can sign up again later as a brand-new account
    r = w.c.post("/api/v1/auth/dev", json={"email": email, "name": "Priya"})
    assert r.status_code == 200 and r.json()["user"]["id"] != b
    _ = a


# ---------------------------------------------------------------- production guard

def _prod(**env):
    s = Settings()
    s.app_env = "prod"
    s.surprise_secret = s.invite_secret = s.voucher_key = "x" * 32
    s.public_base_url = "https://api.squared.example"
    s.storage_backend, s.s3_bucket = "s3", "squared-bills"
    s.support_email, s.apple_team_id = "help@squared.example", "ABCDE12345"
    s.google_client_ids = "123-ios.apps.googleusercontent.com"
    for k, v in env.items():
        setattr(s, k, v)
    return s


def test_production_guard_lists_every_unsafe_setting():
    assert _prod().production_problems() == []
    problems = _prod(invite_secret="change-me", voucher_key="", google_client_ids="",
                     public_base_url="http://api.squared.example", storage_backend="local").production_problems()
    text = " ".join(problems)
    assert "INVITE_SECRET" in text and "VOUCHER_KEY" in text and "https" in text
    assert "STORAGE_BACKEND" in text and "GOOGLE_CLIENT_IDS" in text


def test_production_guard_blocks_startup():
    with pytest.raises(RuntimeError):
        _prod(invite_secret="").assert_safe_for_production()
    _prod().assert_safe_for_production()
    dev = Settings(); dev.app_env = "dev"; dev.invite_secret = ""
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


def test_apple_team_id_and_revocation_key_are_warnings_until_enrolment():
    s = _prod(apple_team_id="", apple_signin_key_id="", apple_signin_private_key="")
    assert s.production_problems() == []
    w = " ".join(s.production_warnings())
    assert "APPLE_TEAM_ID" in w and "APPLE_SIGNIN_KEY_ID" in w
