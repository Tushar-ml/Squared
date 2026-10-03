"""Live currency conversion with a database cache.

Rates come from open.er-api.com (160+ currencies) with Frankfurter (ECB) as fallback,
are cached for an hour, and keep working from the last cached value if both are down.
Expenses snapshot the rate they were entered with, so balances never drift with the market.
"""
import logging
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_EVEN, Decimal

import httpx

from . import clock

log = logging.getLogger("fx")

SUPPORTED = ["INR", "USD", "EUR", "GBP", "AED", "SGD", "AUD", "CAD", "JPY", "THB", "SAR", "QAR", "CHF",
             "CNY", "HKD", "NZD", "MYR", "IDR", "LKR", "NPR", "BDT", "ZAR", "KRW", "SEK"]
NAMES = {"INR": "Indian rupee", "USD": "US dollar", "EUR": "Euro", "GBP": "British pound", "AED": "UAE dirham",
         "SGD": "Singapore dollar", "AUD": "Australian dollar", "CAD": "Canadian dollar", "JPY": "Japanese yen",
         "THB": "Thai baht", "SAR": "Saudi riyal", "QAR": "Qatari riyal", "CHF": "Swiss franc",
         "CNY": "Chinese yuan", "HKD": "Hong Kong dollar", "NZD": "New Zealand dollar", "MYR": "Malaysian ringgit",
         "IDR": "Indonesian rupiah", "LKR": "Sri Lankan rupee", "NPR": "Nepalese rupee", "BDT": "Bangladeshi taka",
         "ZAR": "South African rand", "KRW": "South Korean won", "SEK": "Swedish krona"}
SYMBOLS = {"INR": "₹", "USD": "$", "EUR": "€", "GBP": "£", "JPY": "¥", "KRW": "₩", "THB": "฿", "CNY": "¥"}
ZERO_DECIMAL = {"JPY", "KRW", "IDR"}
CACHE_TTL = timedelta(hours=1)


class FxUnavailable(Exception):
    pass


def digits(cur: str) -> int:
    return 0 if cur in ZERO_DECIMAL else 2


def _fetch_er_api(base: str) -> tuple[dict, datetime, str]:
    r = httpx.get(f"https://open.er-api.com/v6/latest/{base}", timeout=6, follow_redirects=True)
    r.raise_for_status()
    j = r.json()
    if j.get("result") != "success":
        raise ValueError("er-api error")
    as_of = datetime.fromtimestamp(j.get("time_last_update_unix", clock.now().timestamp()), tz=timezone.utc)
    return j["rates"], as_of, "open.er-api.com"


def _fetch_frankfurter(base: str) -> tuple[dict, datetime, str]:
    r = httpx.get(f"https://api.frankfurter.app/latest?from={base}", timeout=6, follow_redirects=True)
    r.raise_for_status()
    j = r.json()
    rates = dict(j["rates"])
    rates[base] = 1.0
    as_of = datetime.fromisoformat(j["date"]).replace(tzinfo=timezone.utc)
    return rates, as_of, "frankfurter.app (ECB)"


FETCHERS = [_fetch_er_api, _fetch_frankfurter]


def _cached(conn, base):
    rows = conn.execute("SELECT quote, rate, as_of, source, fetched_at FROM fx_rates WHERE base=%s", (base,)).fetchall()
    return {r["quote"]: r for r in rows}


def rates(conn, base: str, refresh: bool = False) -> dict:
    """{'base','rates': {quote: float}, 'as_of', 'source', 'stale'} for SUPPORTED quotes."""
    base = base.upper()
    if base not in SUPPORTED:
        raise FxUnavailable(f"{base} isn't supported")
    cache = _cached(conn, base)
    fresh = bool(cache) and max(r["fetched_at"] for r in cache.values()) > clock.now() - CACHE_TTL
    if fresh and not refresh:
        return _pack(base, cache, stale=False)
    for fetch in FETCHERS:
        try:
            got, as_of, source = fetch(base)
        except Exception as exc:  # noqa: BLE001 - try the next provider
            log.warning("fx fetch %s failed: %s", fetch.__name__, exc)
            continue
        for q in SUPPORTED:
            if q in got and got[q]:
                conn.execute(
                    """INSERT INTO fx_rates (base, quote, rate, as_of, source, fetched_at) VALUES (%s,%s,%s,%s,%s,%s)
                       ON CONFLICT (base, quote) DO UPDATE SET rate=EXCLUDED.rate, as_of=EXCLUDED.as_of,
                       source=EXCLUDED.source, fetched_at=EXCLUDED.fetched_at""",
                    (base, q, Decimal(str(got[q])), as_of, source, clock.now()))
        return _pack(base, _cached(conn, base), stale=False)
    if cache:
        return _pack(base, cache, stale=True)
    raise FxUnavailable("Live exchange rates are unavailable right now")


def _pack(base, cache, stale) -> dict:
    out = {q: float(r["rate"]) for q, r in cache.items() if q in SUPPORTED}
    out[base] = 1.0
    any_row = next(iter(cache.values()), None)
    return {"base": base, "rates": out, "as_of": any_row["as_of"].isoformat() if any_row else None,
            "source": any_row["source"] if any_row else None, "stale": stale}


def rate(conn, src: str, dst: str) -> Decimal:
    src, dst = src.upper(), dst.upper()
    if src == dst:
        return Decimal(1)
    r = rates(conn, src)["rates"].get(dst)
    if not r:
        raise FxUnavailable(f"No rate for {src} to {dst}")
    return Decimal(str(r))


def convert_minor(amount_minor: int, src: str, dst: str, fx_rate: Decimal) -> int:
    """Convert minor units using a given rate, handling currencies with different decimals."""
    major = Decimal(amount_minor) / (Decimal(10) ** digits(src))
    out = (major * fx_rate * (Decimal(10) ** digits(dst))).quantize(Decimal(1), rounding=ROUND_HALF_EVEN)
    return int(out)


def fmt(amount_minor: int, cur: str) -> str:
    d = digits(cur)
    major = Decimal(amount_minor) / (Decimal(10) ** d)
    if cur == "INR":
        from .domain import inr
        return inr(amount_minor)
    s = f"{major:,.{d}f}"
    if d and s.endswith("." + "0" * d):
        s = s[: -(d + 1)]
    return f"{cur} {s}"
