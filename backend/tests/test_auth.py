"""Sign in with Google and Sign in with Apple: token checks, account linking, Apple revocation, dev login."""
import hashlib
import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app import auth, db

KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
GOOGLE_AUD = "123-ios.apps.googleusercontent.com"
BUNDLE = "app.squared.ios"


@pytest.fixture(autouse=True)
def _providers(monkeypatch):
    monkeypatch.setattr(auth, "_signing_key", lambda provider, token: KEY.public_key())
    monkeypatch.setattr(auth.settings, "google_client_ids", GOOGLE_AUD)
    monkeypatch.setattr(auth.settings, "google_web_client_id", "456-web.apps.googleusercontent.com")
    monkeypatch.setattr(auth.settings, "ios_bundle_id", BUNDLE)
    monkeypatch.setattr(auth.settings, "ops_emails", "")


def _token(**claims):
    now = int(time.time())
    base = {"iat": now, "exp": now + 600}
    return jwt.encode({**base, **claims}, KEY, algorithm="RS256", headers={"kid": "test"})


def google(client, sub="g-1", email="asha@gmail.com", nonce="n-123", sent_nonce=None, expect=200, **claims):
    tok = _token(iss="https://accounts.google.com", aud=GOOGLE_AUD, sub=sub, email=email, email_verified=True,
                 name="Asha Rao", nonce=nonce, **claims)
    r = client.post("/api/v1/auth/google", json={"id_token": tok, "nonce": sent_nonce or nonce, "device_id": "d1"})
    assert r.status_code == expect, r.text
    return r.json()


def apple(client, sub="a-1", email="asha@gmail.com", nonce="raw-nonce", sent_nonce=None, name=None, code=None,
          expect=200, **claims):
    tok = _token(iss="https://appleid.apple.com", aud=BUNDLE, sub=sub, email=email, email_verified="true",
                 nonce=hashlib.sha256(nonce.encode()).hexdigest(), **claims)
    body = {"identity_token": tok, "nonce": sent_nonce or nonce, "device_id": "d1"}
    if name:
        body["name"] = name
    if code:
        body["authorization_code"] = code
    r = client.post("/api/v1/auth/apple", json=body)
    assert r.status_code == expect, r.text
    return r.json()


def me(client, token):
    return client.get("/api/v1/me", headers={"Authorization": "Bearer " + token})


def test_google_sign_in_creates_a_verified_account_once(client):
    first = google(client)
    assert first["is_new"] is False   # Google gives a name, so there's no profile step
    assert first["user"]["name"] == "Asha Rao" and first["user"]["email"] == "asha@gmail.com"
    assert me(client, first["token"]).status_code == 200
    again = google(client)
    assert again["user"]["id"] == first["user"]["id"] and again["token"] != first["token"]
    with db.tx() as c:
        u = c.execute("SELECT * FROM users WHERE id=%s", (first["user"]["id"],)).fetchone()
    assert u["verified"] and u["google_sub"] == "g-1" and u["phone"] is None


@pytest.mark.parametrize("bad", [
    {"aud": "someone-elses-app.apps.googleusercontent.com"},
    {"iss": "https://evil.example"},
    {"exp": int(time.time()) - 60},
    {"email_verified": False},
])
def test_google_rejects_tokens_not_meant_for_us(client, bad):
    now = int(time.time())
    claims = {"iss": "https://accounts.google.com", "aud": GOOGLE_AUD, "sub": "g-x", "email": "x@gmail.com",
              "email_verified": True, "nonce": "n", "iat": now, "exp": now + 600, **bad}
    tok = jwt.encode(claims, KEY, algorithm="RS256", headers={"kid": "test"})
    r = client.post("/api/v1/auth/google", json={"id_token": tok, "nonce": "n"})
    assert r.status_code == 401


def test_nonce_must_match_so_a_stolen_token_cannot_be_replayed(client):
    google(client, nonce="n-123", sent_nonce="other", expect=401)
    apple(client, nonce="raw-nonce", sent_nonce="other", expect=401)


def test_apple_sign_in_takes_the_name_from_the_app_and_links_by_verified_email(client):
    g = google(client, sub="g-1", email="asha@gmail.com")
    a = apple(client, sub="a-9", email="ASHA@gmail.com", name="Asha R")
    assert a["user"]["id"] == g["user"]["id"]                     # same person, same account
    assert a["user"]["name"] == "Asha Rao"                         # an existing name is kept
    fresh = apple(client, sub="a-2", email="xyz@privaterelay.appleid.com", name="Ravi")
    assert fresh["user"]["id"] != g["user"]["id"] and fresh["user"]["name"] == "Ravi"
    nameless = apple(client, sub="a-3", email="q@privaterelay.appleid.com")
    assert nameless["is_new"] is True                              # no name yet: the app asks for one


def test_ops_role_comes_from_ops_emails(client, monkeypatch):
    monkeypatch.setattr(auth.settings, "ops_emails", "Ops@Squared.example")
    r = google(client, sub="g-ops", email="ops@squared.example")
    assert r["user"]["role"] == "OPS"
    assert google(client, sub="g-2", email="b@gmail.com")["user"]["role"] == "USER"


def test_apple_refresh_token_is_kept_and_revoked_on_account_deletion(client, monkeypatch):
    calls = []
    monkeypatch.setattr(auth, "apple_exchange_code", lambda code: calls.append(("exchange", code)) or "rt-abc")
    monkeypatch.setattr(auth, "apple_revoke", lambda rt: calls.append(("revoke", rt)) or True)
    r = apple(client, sub="a-7", email="z@privaterelay.appleid.com", name="Zed", code="auth-code-1")
    with db.tx() as c:
        assert c.execute("SELECT apple_refresh_token FROM users WHERE id=%s", (r["user"]["id"],)).fetchone()[
            "apple_refresh_token"] == "rt-abc"
    d = client.delete("/api/v1/me", headers={"Authorization": "Bearer " + r["token"]})
    assert d.status_code == 200
    assert calls == [("exchange", "auth-code-1"), ("revoke", "rt-abc")]
    with db.tx() as c:
        u = c.execute("SELECT * FROM users WHERE id=%s", (r["user"]["id"],)).fetchone()
    assert u["apple_sub"] is None and u["apple_refresh_token"] is None
    # signing in again with the same Apple ID starts a new account
    assert apple(client, sub="a-7", email="z@privaterelay.appleid.com", name="Zed")["user"]["id"] != r["user"]["id"]


def test_dev_login_exists_only_outside_production(client, monkeypatch):
    r = client.post("/api/v1/auth/dev", json={"email": "dev@example.com", "name": "Dev"})
    assert r.status_code == 200 and r.json()["user"]["email"] == "dev@example.com"
    monkeypatch.setattr(auth.settings, "app_env", "prod")
    assert client.post("/api/v1/auth/dev", json={"email": "dev@example.com"}).status_code == 404


def test_auth_config_tells_clients_what_to_show(client, monkeypatch):
    c = client.get("/api/v1/auth/config").json()
    assert c["dev_login"] is True and c["google_web_client_id"] == "456-web.apps.googleusercontent.com"
    monkeypatch.setattr(auth.settings, "app_env", "prod")
    assert client.get("/api/v1/auth/config").json()["dev_login"] is False


def test_ops_web_client_id_is_also_accepted(client):
    now = int(time.time())
    tok = jwt.encode({"iss": "accounts.google.com", "aud": "456-web.apps.googleusercontent.com", "sub": "g-web",
                      "email": "w@gmail.com", "email_verified": True, "nonce": "n", "iat": now, "exp": now + 600},
                     KEY, algorithm="RS256", headers={"kid": "test"})
    assert client.post("/api/v1/auth/google", json={"id_token": tok, "nonce": "n"}).status_code == 200
