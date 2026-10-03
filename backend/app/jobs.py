"""Scheduled jobs run by the worker (all boundaries in IST, I-7)."""
import logging
import time
from datetime import timedelta

from . import clock, coin_config, db, domain, engine, experiment, goals, ledger, notify, redemption, views

log = logging.getLogger("jobs")


def drain_outbox(batch: int = 50) -> int:
    """Process pending outbox events, one transaction per event. Failed events retry with backoff."""
    n = 0
    for _ in range(batch):
        with db.tx() as conn:
            ev = conn.execute(
                """SELECT * FROM outbox_events WHERE processed_at IS NULL
                   AND (attempts = 0 OR occurred_at + make_interval(secs => LEAST(300, 2 ^ attempts)) <= %s)
                   ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED""", (clock.now(),)).fetchone()
            if ev is None:
                return n
            try:
                with conn.transaction():
                    engine.process(conn, ev["event_type"], ev["payload"])
                conn.execute("UPDATE outbox_events SET processed_at=%s, attempts=attempts+1 WHERE id=%s",
                             (clock.now(), ev["id"]))
            except Exception as exc:  # noqa: BLE001
                log.exception("event %s failed", ev["id"])
                conn.execute("UPDATE outbox_events SET attempts=attempts+1, last_error=%s WHERE id=%s",
                             (str(exc)[:500], ev["id"]))
        n += 1
    return n


def dispatch_notifications() -> int:
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        return notify.dispatch(conn, cfg)


def close_weeks(force_week=None) -> int:
    """Monday 00:05 IST: emit WeekClosed for last week's open goals of treatment Home groups."""
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        week = force_week or (clock.ist_week_start() - timedelta(days=7))
        gids = [r["group_id"] for r in conn.execute(
            "SELECT group_id FROM experiment_assignments WHERE experiment_key=%s AND arm='TREATMENT'",
            (cfg["experiment"]["key"],))]
        n = 0
        from . import events
        for gid in gids:
            done = conn.execute("SELECT status FROM household_goals WHERE group_id=%s AND week_start=%s",
                                (gid, week)).fetchone()
            if done and done["status"] != "OPEN":
                continue
            exists = conn.execute(
                "SELECT 1 FROM outbox_events WHERE event_type='WeekClosed' AND payload->>'group_id'=%s AND payload->>'week_start'=%s",
                (str(gid), week.isoformat())).fetchone()
            if not exists:
                events.emit(conn, "WeekClosed", group_id=gid, week_start=week.isoformat())
                n += 1
        return n


def expire_lots() -> int:
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        return ledger.expire_due(conn, cfg)


def mark_unverified() -> int:
    with db.tx() as conn:
        r = conn.execute("UPDATE payment_confirmations SET status='UNVERIFIED' WHERE status='PENDING' AND expires_at <= %s",
                         (clock.now(),))
        return r.rowcount


def daily_digest() -> int:
    """N3 at digest_hour IST: confirmations of your expenses today."""
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        start, end = clock.ist_day_bounds()
        rows = conn.execute(
            """SELECT w.owner_id uid, count(*) n, sum(l.amount) coins FROM coin_ledger l JOIN wallets w ON w.id=l.wallet_id
               WHERE l.reason_code='EXPENSE_ADDER' AND l.status='POSTED' AND l.created_at >= %s AND l.created_at < %s
                 AND w.owner_type='USER' GROUP BY w.owner_id""", (start, end)).fetchall()
        for r in rows:
            n = r["n"]
            notify.enqueue(conn, cfg, user_id=r["uid"], nid="N3", title="Coins today",
                           body=f"{n} of your expense{'s were' if n != 1 else ' was'} confirmed today. +{r['coins']} coins",
                           dedupe_key=f"N3:{r['uid']}:{clock.ist().date()}", payload={"route": "wallet"})
        return len(rows)


def settle_nudges() -> int:
    """N4: debt aged >= 24h and >= INR 100; max 1 per debt per 3 days; stops after 14 days."""
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        p = cfg["push"]
        gids = [r["group_id"] for r in conn.execute(
            "SELECT group_id FROM experiment_assignments WHERE experiment_key=%s AND arm='TREATMENT'",
            (cfg["experiment"]["key"],))]
        n = 0
        for gid in gids:
            if not experiment.eligibility(conn, gid, cfg)[0]:
                continue
            names = None
            for (a, b), v in domain.pair_debts(conn, gid).items():
                if v < p["settle_nudge_min_inr"] * 100:
                    continue
                start = domain.debt_age_start(conn, gid, a, b, {"id": -1, "created_at": clock.now()})
                if start is None:
                    continue
                age = clock.now() - start
                if age < timedelta(hours=p["settle_nudge_after_hours"]) or age > timedelta(days=p["settle_nudge_stop_days"]):
                    continue
                bucket = int(age.total_seconds() // (p["settle_nudge_every_days"] * 86400))
                names = names or domain.user_names(conn, experiment.active_member_ids(conn, gid))
                coins = views.settle_hint(conn, gid, a, b, cfg)
                if notify.enqueue(conn, cfg, user_id=a, nid="N4", group_id=gid, title="Settle up",
                                  body=f"You owe {names.get(b)} {domain.inr(v)}. Pay today for +{coins} coins",
                                  dedupe_key=f"N4:{gid}:{a}:{b}:{start.date()}:{bucket}",
                                  payload={"group_id": gid, "creditor_id": b, "route": "settle"}):
                    n += 1
        return n


def expiry_warnings() -> int:
    """N7: one per month when a lot expires within expiry_push_days."""
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        rows = conn.execute(
            """SELECT w.owner_id uid, sum(l.remaining) coins, min(l.expires_at) t FROM coin_lots l JOIN wallets w ON w.id=l.wallet_id
               WHERE w.owner_type='USER' AND l.remaining > 0 AND l.expires_at <= %s AND l.expires_at > %s
               GROUP BY w.owner_id""", (clock.now() + timedelta(days=cfg["expiry_push_days"]), clock.now())).fetchall()
        for r in rows:
            notify.enqueue(conn, cfg, user_id=r["uid"], nid="N7", title="Coins expiring",
                           body=f"{r['coins']} coins expire on {clock.ist(r['t']).strftime('%-d %b')}",
                           dedupe_key=f"N7:{r['uid']}:{clock.ist().strftime('%Y-%m')}", payload={"route": "wallet"})
        return len(rows)


def integrity_check() -> list:
    """Hourly: compare balance_cached with the ledger and lots; record and rebuild on mismatch."""
    bad = []
    with db.tx() as conn:
        for w in conn.execute("SELECT id FROM wallets").fetchall():
            problems = ledger.integrity(conn, w["id"])
            if problems:
                import json
                conn.execute("INSERT INTO integrity_reports (wallet_id, detail) VALUES (%s,%s)", (w["id"], json.dumps(problems)))
                log.error("ledger integrity mismatch wallet=%s %s", w["id"], problems)
                if "balance" in problems:
                    ledger.rebuild_balance(conn, w["id"])
                bad.append({"wallet_id": str(w["id"]), **problems})
    return bad


def release_redemptions() -> int:
    return redemption.release_held()


class Scheduler:
    """Tiny wall-clock scheduler keyed on IST times; good enough for one worker process."""

    def __init__(self):
        self.last: dict[str, str] = {}

    def due(self, name: str, period_key: str) -> bool:
        if self.last.get(name) == period_key:
            return False
        self.last[name] = period_key
        return True

    def tick(self):
        cfg = coin_config.current()
        t = clock.ist()
        runs = []
        if self.due("minute", t.strftime("%Y%m%d%H%M")):
            runs += [mark_unverified, release_redemptions]
        if self.due("hourly", t.strftime("%Y%m%d%H")):
            runs += [integrity_check, settle_nudges]
        if t.weekday() == 0 and (t.hour, t.minute) >= (0, 5) and self.due("week_close", t.strftime("%G%V")):
            runs.append(close_weeks)
        if t.hour >= 2 and self.due("nightly", t.strftime("%Y%m%d")):
            runs.append(expire_lots)
        if t.hour >= cfg["push"]["digest_hour"] and self.due("digest", t.strftime("%Y%m%d")):
            runs.append(daily_digest)
        if t.day == 1 and t.hour >= 9 and self.due("expiry_warn", t.strftime("%Y%m")):
            runs.append(expiry_warnings)
        for job in runs:
            try:
                job()
            except Exception:  # noqa: BLE001
                log.exception("job %s failed", job.__name__)
