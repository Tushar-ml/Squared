"""APNs sender. Inert until APNS_* env vars are set; local dev delivers through /me/notifications/deliver.

Uses token-based auth (ES256 JWT, refreshed every 50 min) over HTTP/2 as Apple requires.
"""
import json
import logging
import os
import time

log = logging.getLogger("push")

KEY_ID = os.getenv("APNS_KEY_ID", "")
TEAM_ID = os.getenv("APNS_TEAM_ID", "")
KEY_PATH = os.getenv("APNS_KEY_PATH", "")        # path to the AuthKey_XXXX.p8 file
TOPIC = os.getenv("APNS_TOPIC", "tech.simplismart.roommatecoins")
HOST = "https://api.sandbox.push.apple.com" if os.getenv("APNS_SANDBOX", "1") == "1" else "https://api.push.apple.com"
_jwt = (0.0, "")


def enabled() -> bool:
    return bool(KEY_ID and TEAM_ID and KEY_PATH and os.path.exists(KEY_PATH))


def _token() -> str:
    global _jwt
    if time.time() - _jwt[0] < 50 * 60:
        return _jwt[1]
    import jwt  # PyJWT
    with open(KEY_PATH) as f:
        key = f.read()
    tok = jwt.encode({"iss": TEAM_ID, "iat": int(time.time())}, key, algorithm="ES256", headers={"kid": KEY_ID})
    _jwt = (time.time(), tok)
    return tok


def payload_for(row) -> dict:
    p = dict(row["payload"] or {})
    aps = {"alert": {"title": row["title"], "body": row["body"]}, "sound": "default",
           "category": p.get("category", ""), "thread-id": f"group-{row['group_id']}" if row["group_id"] else "general"}
    return {"aps": aps, **{k: v for k, v in p.items() if k != "category"}, "notification_uuid": str(row["id"]),
            "nid": row["notification_id"]}


def send(conn, row) -> None:
    """Best effort: failures never block the orchestrator; the in-app inbox still has the notification."""
    if not enabled():
        return
    import httpx
    tokens = [r["token"] for r in conn.execute("SELECT token FROM devices WHERE user_id=%s AND platform='ios'", (row["user_id"],))]
    if not tokens:
        return
    body = json.dumps(payload_for(row)).encode()
    headers = {"authorization": f"bearer {_token()}", "apns-topic": TOPIC, "apns-push-type": "alert",
               "apns-priority": "10" if row["notification_id"] in ("N1", "N2") else "5"}
    try:
        with httpx.Client(http2=True, timeout=5) as c:
            for t in tokens:
                r = c.post(f"{HOST}/3/device/{t}", content=body, headers=headers)
                if r.status_code == 410 or (r.status_code == 400 and "BadDeviceToken" in r.text):
                    conn.execute("DELETE FROM devices WHERE token=%s", (t,))
                elif r.status_code != 200:
                    log.warning("apns %s: %s", r.status_code, r.text[:200])
    except Exception as exc:  # noqa: BLE001
        log.warning("apns send failed: %s", exc)
