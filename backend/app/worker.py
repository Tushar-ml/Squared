"""Reward worker: drains the outbox, dispatches notifications and runs scheduled jobs.

If this process is down, the app keeps working (I-1); events wait in the outbox.
"""
import logging
import time

from . import db, jobs, seed
from .settings import settings

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
log = logging.getLogger("worker")


def main():
    db.init_pool(size=4)
    for _ in range(30):
        try:
            db.migrate()
            break
        except Exception:  # db may still be starting
            time.sleep(1)
    seed.ensure_base()
    sched = jobs.Scheduler()
    log.info("worker started")
    while True:
        try:
            n = jobs.drain_outbox()
            jobs.dispatch_notifications()
            sched.tick()
        except Exception:  # noqa: BLE001
            log.exception("worker loop error")
            n = 0
        if not n:
            time.sleep(settings.worker_poll_seconds)


if __name__ == "__main__":
    main()
