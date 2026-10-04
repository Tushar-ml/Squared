"""Tiny CLI client for poking the local API: python3 scripts/api.py <email> <METHOD> <path> [json]

Signs in with the dev-only /auth/dev endpoint (local stack only)."""
import json
import pathlib
import sys
import urllib.request

BASE = "http://localhost:8080/api/v1"


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


def login(email):
    """Reuse a saved session, else sign in with the dev-only endpoint."""
    saved = json.loads(TOKENS.read_text()) if TOKENS.exists() else {}
    if saved.get(email) and call("GET", "/me", token=saved[email])[0] == 200:
        return saved[email]
    st, out = call("POST", "/auth/dev", {"email": email, "device_id": "cli-" + email})
    if st != 200:
        sys.exit(f"dev sign-in failed ({st}): {out.get('detail')}")
    token = out["token"]
    saved[email] = token
    TOKENS.parent.mkdir(exist_ok=True)
    TOKENS.write_text(json.dumps(saved))
    return token


if __name__ == "__main__":
    email, method, path = sys.argv[1:4]
    body = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
    st, out = call(method, path, body, login(email), {"Idempotency-Key": "cli-" + str(hash(str(sys.argv)))})
    print(st)
    print(json.dumps(out, indent=2))
