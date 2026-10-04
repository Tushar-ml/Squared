"""Sign in with Google and Sign in with Apple.

The app gets an ID token from Google or Apple and sends it here. We check it ourselves against the
provider's published keys (no third-party auth service): signature, issuer, audience (our app),
expiry, and a nonce the app generated for this sign-in so an intercepted token can't be replayed.

Apple requires apps to revoke Sign in with Apple when an account is deleted. For that we exchange the
one-time authorization code for a refresh token at sign-in and revoke it on deletion. It needs a Sign in
with Apple key (APPLE_SIGNIN_KEY_ID + APPLE_SIGNIN_PRIVATE_KEY) from the Apple Developer account.
"""
import hashlib
import hmac
import logging
import time
from dataclasses import dataclass

import httpx
import jwt
from fastapi import HTTPException

from .settings import settings

log = logging.getLogger("auth")

GOOGLE_ISSUERS = ("https://accounts.google.com", "accounts.google.com")
APPLE_ISSUER = "https://appleid.apple.com"
JWKS = {"google": "https://www.googleapis.com/oauth2/v3/certs", "apple": "https://appleid.apple.com/auth/keys"}
_clients: dict[str, jwt.PyJWKClient] = {}


@dataclass
class Identity:
    provider: str          # "google" or "apple"
    sub: str               # the provider's stable user id
    email: str | None
    email_verified: bool
    name: str | None


def _signing_key(provider: str, token: str):
    if provider not in _clients:
        _clients[provider] = jwt.PyJWKClient(JWKS[provider], cache_keys=True, lifespan=3600)
    return _clients[provider].get_signing_key_from_jwt(token).key


def _decode(provider: str, token: str, audiences: list[str], issuers) -> dict:
    if not audiences:
        raise HTTPException(503, f"Sign in with {provider.title()} isn't set up on this server")
    try:
        claims = jwt.decode(token, _signing_key(provider, token), algorithms=["RS256"], audience=audiences,
                            options={"require": ["exp", "iat", "sub", "iss", "aud"]}, leeway=30)
    except Exception as e:  # noqa: BLE001  any invalid, expired or foreign token
        log.info("rejected %s token: %s", provider, e)
        raise HTTPException(401, "That sign-in didn't work. Please try again.")
    if claims["iss"] not in issuers:
        raise HTTPException(401, "That sign-in didn't work. Please try again.")
    return claims


def _truthy(v) -> bool:
    return v is True or str(v).lower() == "true"


def verify_google(id_token: str, nonce: str) -> Identity:
    audiences = [a.strip() for a in settings.google_client_ids.split(",") if a.strip()]
    if settings.google_web_client_id:
        audiences.append(settings.google_web_client_id)
    c = _decode("google", id_token, audiences, GOOGLE_ISSUERS)
    if not nonce or not hmac.compare_digest(str(c.get("nonce", "")), nonce):
        raise HTTPException(401, "That sign-in didn't work. Please try again.")
    if not c.get("email") or not _truthy(c.get("email_verified")):
        raise HTTPException(401, "Use a Google account with a verified email.")
    return Identity("google", c["sub"], c["email"].strip().lower(), True, c.get("name"))


def verify_apple(identity_token: str, raw_nonce: str) -> Identity:
    c = _decode("apple", identity_token, [settings.ios_bundle_id], (APPLE_ISSUER,))
    expected = hashlib.sha256((raw_nonce or "").encode()).hexdigest()
    if not raw_nonce or not hmac.compare_digest(str(c.get("nonce", "")), expected):
        raise HTTPException(401, "That sign-in didn't work. Please try again.")
    email = (c.get("email") or "").strip().lower() or None
    return Identity("apple", c["sub"], email, bool(email) and _truthy(c.get("email_verified")), None)


# ---------------------------------------------------------------- Apple token revocation

def apple_revocation_configured() -> bool:
    return bool(settings.apple_team_id and settings.apple_signin_key_id and settings.apple_signin_private_key)


def _apple_client_secret() -> str:
    now = int(time.time())
    key = settings.apple_signin_private_key.replace("\\n", "\n")
    return jwt.encode({"iss": settings.apple_team_id, "iat": now, "exp": now + 300, "aud": APPLE_ISSUER,
                       "sub": settings.ios_bundle_id}, key, algorithm="ES256",
                      headers={"kid": settings.apple_signin_key_id})


def apple_exchange_code(code: str) -> str | None:
    """One-time authorization code -> refresh token (kept only so it can be revoked later)."""
    if not apple_revocation_configured():
        return None
    try:
        r = httpx.post(f"{APPLE_ISSUER}/auth/token", timeout=10, data={
            "client_id": settings.ios_bundle_id, "client_secret": _apple_client_secret(),
            "code": code, "grant_type": "authorization_code"})
        r.raise_for_status()
        return r.json().get("refresh_token")
    except Exception:  # noqa: BLE001  sign-in still works; revocation is best effort
        log.exception("apple code exchange failed")
        return None


def apple_revoke(refresh_token: str) -> bool:
    if not apple_revocation_configured():
        return False
    try:
        r = httpx.post(f"{APPLE_ISSUER}/auth/revoke", timeout=10, data={
            "client_id": settings.ios_bundle_id, "client_secret": _apple_client_secret(),
            "token": refresh_token, "token_type_hint": "refresh_token"})
        return r.status_code == 200
    except Exception:  # noqa: BLE001
        log.exception("apple revoke failed")
        return False
