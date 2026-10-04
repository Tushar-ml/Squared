"""Versioned remote config (PRD 8.8, invariant I-5).

Every number the reward module uses comes from here. The engine pins one version
per event; every ledger entry stores that version.
"""
import copy
import json
import time

from . import db

DEFAULT_CONFIG = {
    "enabled": True,
    "kill_switch": False,
    "coin_value_inr": 0.25,
    "min_expense_inr": 20,
    "min_payment_inr": 50,
    "earn": {
        "first_win": 50, "expense_adder": 5, "expense_confirmer": 2, "max_confirmers_per_expense": 4,
        "settle_payer": 20, "settle_quick_bonus": 10, "quick_window_hours": 48,
        "settle_receiver": 10, "invite_each": 50, "max_rewarded_invitees": 10,
        "household_goal": 120, "household_goal_target": 5,
    },
    "surprise": {"p_any": 0.20, "p_3x": 0.05, "p_2x": 0.15},
    "caps": {"user_daily": 60, "user_monthly": 600, "group_daily_rewarded_expenses": 8,
             "pair_daily_confirmations": 5},
    "expiry_months": 12, "expiry_push_days": 30,
    "redemption": {"enabled": False,  # vouchers launch later; coins keep accruing meanwhile
                   "min_account_age_days": 7, "max_per_user_per_week": 2, "first_redemption_hold_hours": 48},
    "confirmation": {"payment_unverified_after_days": 7, "expense_unconfirmed_label_after_days": 7},
    "push": {"max_per_user_per_day": 2, "quiet_start": "22:00", "quiet_end": "08:00",
             "batch_window_minutes": 10, "digest_hour": 20, "recap_hour": 10,
             "remind_cooldown_hours": 24, "settle_nudge_min_inr": 100, "settle_nudge_after_hours": 24,
             "settle_nudge_every_days": 3, "settle_nudge_stop_days": 14, "first_redeem_threshold": 100},
    "risk": {"threshold": 0.7, "new_account_days": 7, "new_account_weight": 0.3,
             "shared_device_weight": 0.5, "velocity_daily_earn_events": 15, "velocity_weight": 0.3},
    "ping_pong_days": 7,
    "experiment": {"key": "roommate_coins_v1", "treatment_share": 0.5},
    "min_app_version": {"ios": "1.0.0", "android": "TBD"},
}

# Keys a client may see (GET /config/coins). Never expose risk or experiment internals.
CLIENT_KEYS = ("enabled", "kill_switch", "coin_value_inr", "min_expense_inr", "earn", "surprise", "caps",
               "expiry_months", "redemption", "confirmation", "min_app_version")


class ConfigError(ValueError):
    pass


def validate(body: dict) -> None:
    s = body.get("surprise", {})
    if abs(s.get("p_any", 0) - (s.get("p_2x", 0) + s.get("p_3x", 0))) > 1e-9:
        raise ConfigError("surprise.p_any must equal p_2x + p_3x")
    for k in ("p_any", "p_2x", "p_3x"):
        if not 0 <= s.get(k, 0) <= 1:
            raise ConfigError(f"surprise.{k} must be within [0,1]")
    if body.get("coin_value_inr", 0) <= 0:
        raise ConfigError("coin_value_inr must be positive")
    share = body.get("experiment", {}).get("treatment_share", 0.5)
    if not 0 <= share <= 1:
        raise ConfigError("experiment.treatment_share must be within [0,1]")


class Config(dict):
    """A pinned config version. Access like a dict; `.version` is the version number."""

    def __init__(self, version: int, body: dict):
        super().__init__(body)
        self.version = version


_cache: tuple[float, Config] | None = None
CACHE_SECONDS = 2.0


def ensure_default(conn, overrides: dict | None = None) -> None:
    row = conn.execute("SELECT 1 FROM coin_config LIMIT 1").fetchone()
    if row is None:
        body = deep_merge(copy.deepcopy(DEFAULT_CONFIG), overrides or {})
        validate(body)
        conn.execute("INSERT INTO coin_config (version, body) VALUES (1, %s)", (json.dumps(body),))


def current(conn=None, fresh: bool = False) -> Config:
    global _cache
    if not fresh and _cache and time.monotonic() - _cache[0] < CACHE_SECONDS:
        return _cache[1]

    def load(c):
        r = c.execute("SELECT version, body FROM coin_config ORDER BY version DESC LIMIT 1").fetchone()
        if r is None:
            return Config(0, copy.deepcopy(DEFAULT_CONFIG))
        return Config(r["version"], deep_merge(copy.deepcopy(DEFAULT_CONFIG), r["body"]))

    if conn is not None:
        cfg = load(conn)
    else:
        with db.tx() as c:
            cfg = load(c)
    _cache = (time.monotonic(), cfg)
    return cfg


def get_version(conn, version: int) -> Config:
    r = conn.execute("SELECT version, body FROM coin_config WHERE version=%s", (version,)).fetchone()
    if r is None:
        return current(conn, fresh=True)
    return Config(r["version"], deep_merge(copy.deepcopy(DEFAULT_CONFIG), r["body"]))


def publish(conn, patch: dict, actor_id: int | None) -> Config:
    """Create a new version = current merged with patch."""
    global _cache
    conn.execute("LOCK TABLE coin_config IN EXCLUSIVE MODE")
    cur = current(conn, fresh=True)
    body = deep_merge(copy.deepcopy(dict(cur)), patch)
    validate(body)
    version = cur.version + 1
    conn.execute("INSERT INTO coin_config (version, body, created_by) VALUES (%s,%s,%s)",
                 (version, json.dumps(body), actor_id))
    _cache = None
    return Config(version, body)


def invalidate() -> None:
    global _cache
    _cache = None


def deep_merge(base: dict, patch: dict) -> dict:
    for k, v in (patch or {}).items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def client_view(cfg: Config) -> dict:
    out = {k: cfg[k] for k in CLIENT_KEYS if k in cfg}
    out["version"] = cfg.version
    out["coins_per_inr"] = round(1 / cfg["coin_value_inr"])
    return out
