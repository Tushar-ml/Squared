"""Notification orchestrator (PRD 8.9, FR-9).

Every coin push goes through enqueue(). The dispatcher decides: send now, delay to
quiet-end, batch, or in-app inbox only. Devices pull SENT notifications from
GET /me/notifications/deliver (local-dev transport; an APNs adapter can replace it).
"""
import json
import uuid
from datetime import datetime, time, timedelta

from . import analytics, clock, push

ACTIONABLE = {"N1", "N2"}
CATEGORY = {"N1": "EXPENSE_CONFIRM", "N2": "PAYMENT_RECEIPT", "N3": "OPEN_WALLET", "N4": "SETTLE_NUDGE",
            "N5": "OPEN_HOUSEHOLD", "N6": "REDEEM", "N7": "OPEN_WALLET", "N8": "OPEN_GROUP", "N9": "INFO",
            "C1": "OPEN_GROUP", "C2": "OPEN_EXPENSE", "C3": "OPEN_CHAT", "C4": "OPEN_INSIGHTS"}
ALL_IDS = ["N1", "N2", "N3", "N4", "N5", "N6", "N7", "N8", "C1", "C2", "C3", "C4"]
# C* are everyday app notifications (recurring, comments, chat, budgets): quiet hours and opt-outs apply,
# but they don't count toward the PRD's 2-per-day cap, which is for coin pushes only.


def _hm(s: str) -> time:
    h, m = s.split(":")
    return time(int(h), int(m))


def in_quiet_hours(cfg, at: datetime | None = None) -> bool:
    t = clock.ist(at).time()
    start, end = _hm(cfg["push"]["quiet_start"]), _hm(cfg["push"]["quiet_end"])
    return t >= start or t < end if start > end else start <= t < end


def next_quiet_end(cfg, at: datetime | None = None) -> datetime:
    d = clock.ist(at)
    end = _hm(cfg["push"]["quiet_end"])
    target = d.replace(hour=end.hour, minute=end.minute, second=0, microsecond=0)
    if target <= d:
        target += timedelta(days=1)
    return target


def opted_in(conn, user_id: int, nid: str) -> bool:
    r = conn.execute("SELECT enabled FROM notification_prefs WHERE user_id=%s AND notification_id=%s",
                     (user_id, nid)).fetchone()
    return True if r is None else r["enabled"]


def enqueue(conn, cfg, *, user_id: int, nid: str, title: str, body: str, dedupe_key: str, group_id=None,
            payload: dict | None = None, deliver_after: datetime | None = None, batch_key: str | None = None,
            batch_title=None, batch_body=None) -> str | None:
    """Queue a coin push. Returns the notification id, or None if deduped."""
    payload = dict(payload or {})
    payload["category"] = CATEGORY.get(nid, "INFO")
    status = "QUEUED"
    if batch_key and nid == "N1":
        window = clock.now() - timedelta(minutes=cfg["push"]["batch_window_minutes"])
        recent = conn.execute(
            """SELECT count(*) c FROM notifications WHERE user_id=%s AND notification_id='N1'
               AND payload->>'batch_key' = %s AND created_at >= %s AND status <> 'SUPPRESSED'""",
            (user_id, batch_key, window)).fetchone()["c"]
        payload["batch_key"] = batch_key
        if recent >= 2:  # this is the 3rd in the window: collapse into one digest push
            status = "BATCHED"
            n = recent + 1
            bucket = int(clock.now().timestamp() // (cfg["push"]["batch_window_minutes"] * 60))
            ckey = f"N1-batch:{user_id}:{batch_key}:{bucket}"
            conn.execute(
                """INSERT INTO notifications (id, user_id, notification_id, group_id, dedupe_key, title, body, payload,
                       priority, status, deliver_after, created_at)
                   VALUES (%s,%s,'N1',%s,%s,%s,%s,%s,2,'QUEUED',%s,%s)
                   ON CONFLICT (dedupe_key) DO UPDATE SET body = EXCLUDED.body, title = EXCLUDED.title""",
                (uuid.uuid4(), user_id, group_id, ckey, batch_title or title,
                 (batch_body or "{n} expenses to review").format(n=n),
                 json.dumps({"category": "OPEN_GROUP", "group_id": group_id, "batch": True}),
                 clock.now(), clock.now()))
    r = conn.execute(
        """INSERT INTO notifications (id, user_id, notification_id, group_id, dedupe_key, title, body, payload,
               priority, status, deliver_after, created_at)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT (dedupe_key) DO NOTHING RETURNING id""",
        (uuid.uuid4(), user_id, nid, group_id, dedupe_key, title, body, json.dumps(payload, default=str),
         2 if nid in ACTIONABLE else 1, status, deliver_after or clock.now(), clock.now())).fetchone()
    return str(r["id"]) if r else None


def sent_today(conn, user_id: int) -> int:
    start, end = clock.ist_day_bounds()
    return conn.execute("SELECT count(*) c FROM notifications WHERE user_id=%s AND status='SENT' AND sent_at >= %s AND sent_at < %s"
                        " AND notification_id LIKE 'N%%'",
                        (user_id, start, end)).fetchone()["c"]


def dispatch(conn, cfg) -> int:
    """Move due QUEUED notifications to SENT / INBOX_ONLY / delayed. Returns count processed."""
    rows = conn.execute(
        """SELECT * FROM notifications WHERE status='QUEUED' AND deliver_after <= %s
           ORDER BY priority DESC, created_at LIMIT 200 FOR UPDATE SKIP LOCKED""", (clock.now(),)).fetchall()
    n = 0
    for row in rows:
        n += 1
        if not opted_in(conn, row["user_id"], row["notification_id"]):
            _set(conn, row, "INBOX_ONLY")
            continue
        if in_quiet_hours(cfg):
            conn.execute("UPDATE notifications SET deliver_after=%s WHERE id=%s", (next_quiet_end(cfg), row["id"]))
            continue
        if row["notification_id"].startswith("C"):
            _set(conn, row, "SENT")
            push.send(conn, row)
            continue
        cap = cfg["push"]["max_per_user_per_day"]
        used = sent_today(conn, row["user_id"])
        if row["notification_id"] not in ACTIONABLE:
            # keep room for actionable pushes waiting for this user
            waiting = conn.execute(
                """SELECT count(*) c FROM notifications WHERE user_id=%s AND status='QUEUED' AND priority=2
                   AND deliver_after <= %s AND id <> %s""", (row["user_id"], clock.now(), row["id"])).fetchone()["c"]
            used += waiting
        if used >= cap:
            _set(conn, row, "INBOX_ONLY")
            continue
        _set(conn, row, "SENT")
        push.send(conn, row)
        analytics.track(conn, "push_sent", user_id=row["user_id"], group_id=row["group_id"],
                        config_version=cfg.version, notification_id=row["notification_id"])
    return n


def _set(conn, row, status):
    conn.execute("UPDATE notifications SET status=%s, sent_at=CASE WHEN %s='SENT' THEN %s ELSE sent_at END WHERE id=%s",
                 (status, status, clock.now(), row["id"]))
