"""Analytics emitter (PRD 8.7). Every event carries group_id, arm and config_version."""
import hashlib
import json

KNOWN_CLIENT_EVENTS = {
    "coins_card_viewed", "expense_confirm_tapped", "remind_tapped", "payment_marked_paid", "redeem_started",
    "invite_shared", "push_opened", "push_actioned", "kill_switch_observed", "intro_viewed", "intro_skipped",
}


def user_hash(user_id) -> str | None:
    if user_id is None:
        return None
    return hashlib.sha256(f"rc-analytics:{user_id}".encode()).hexdigest()[:16]


def track(conn, name: str, *, user_id=None, group_id=None, arm=None, config_version=None, platform="server",
          app_version=None, **props) -> None:
    props.pop("code", None)  # voucher codes never reach analytics
    conn.execute(
        """INSERT INTO analytics_events (name, user_hash, group_id, arm, config_version, platform, app_version, props)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s)""",
        (name, user_hash(user_id), group_id, arm, config_version, platform, app_version,
         json.dumps(props, default=str)))
