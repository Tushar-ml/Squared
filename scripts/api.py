"""Tiny CLI client for poking the local API: python3 scripts/api.py <phone> <METHOD> <path> [json]"""
import json
import pathlib
import sys
import urllib.request

BASE = "http://localhost:8080/api/v1"
OTP = "123456"  # DEV_OTP from backend/.env.dev (see backend/.env.example)


def call(method, path, body=None, token=None, headers=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


TOKENS = pathlib.Path(__file__).resolve().parent.parent / ".docker" / "cli-tokens.json"  # git-ignored


def login(phone):
    """Reuse a saved session: OTP sends are rate limited (one per 30s, five per hour per number)."""
    saved = json.loads(TOKENS.read_text()) if TOKENS.exists() else {}
    if saved.get(phone) and call("GET", "/me", token=saved[phone])[0] == 200:
        return saved[phone]
    st, out = call("POST", "/auth/otp/request", {"phone": phone})
    if st != 200:
        sys.exit(f"OTP request failed ({st}): {out.get('detail')}")
    token = call("POST", "/auth/otp/verify", {"phone": phone, "otp": OTP, "device_id": "cli-" + phone})[1]["token"]
    saved[phone] = token
    TOKENS.parent.mkdir(exist_ok=True)
    TOKENS.write_text(json.dumps(saved))
    return token


if __name__ == "__main__":
    phone, method, path = sys.argv[1:4]
    body = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
    st, out = call(method, path, body, login(phone), {"Idempotency-Key": "cli-" + str(hash(str(sys.argv)))})
    print(st)
    print(json.dumps(out, indent=2))
