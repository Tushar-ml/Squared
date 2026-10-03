"""Server clock. Server time is authoritative for every window (PRD 8.13).

Tests shift time with `clock.travel(...)`; production never does.
"""
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

IST = ZoneInfo("Asia/Kolkata")
_offset = timedelta(0)


def now() -> datetime:
    return datetime.now(timezone.utc) + _offset


def travel(delta: timedelta) -> None:
    global _offset
    _offset += delta


def set_now(target: datetime) -> None:
    global _offset
    _offset = target - datetime.now(timezone.utc)


def reset() -> None:
    global _offset
    _offset = timedelta(0)


def ist(dt: datetime | None = None) -> datetime:
    return (dt or now()).astimezone(IST)


def ist_day_bounds(dt: datetime | None = None) -> tuple[datetime, datetime]:
    d = ist(dt)
    start = d.replace(hour=0, minute=0, second=0, microsecond=0)
    return start, start + timedelta(days=1)


def ist_month_bounds(dt: datetime | None = None) -> tuple[datetime, datetime]:
    d = ist(dt)
    start = d.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    nxt = (start + timedelta(days=32)).replace(day=1)
    return start, nxt


def ist_week_start(dt: datetime | None = None) -> date:
    """Monday of the ISO week containing dt, in IST."""
    d = ist(dt).date()
    return d - timedelta(days=d.weekday())


def week_bounds(week_start: date) -> tuple[datetime, datetime]:
    start = datetime(week_start.year, week_start.month, week_start.day, tzinfo=IST)
    return start, start + timedelta(days=7)
