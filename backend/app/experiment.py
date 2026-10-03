"""Group-level experiment assignment and coin eligibility (FR-1, FR-13)."""
import hashlib

from . import analytics


def bucket(experiment_key: str, group_id: int) -> float:
    h = hashlib.sha256(f"{experiment_key}:{group_id}".encode()).digest()
    return int.from_bytes(h[:8], "big") / 2**64


def assign(conn, group: dict, cfg) -> str | None:
    """Assign once, deterministically. Groups of any type in India enter the experiment."""
    if group["country"] != "IN":
        return None
    key = cfg["experiment"]["key"]
    row = conn.execute("SELECT arm FROM experiment_assignments WHERE experiment_key=%s AND group_id=%s",
                       (key, group["id"])).fetchone()
    if row:
        return row["arm"]
    arm = "TREATMENT" if bucket(key, group["id"]) < cfg["experiment"]["treatment_share"] else "CONTROL"
    r = conn.execute(
        """INSERT INTO experiment_assignments (experiment_key, group_id, arm) VALUES (%s,%s,%s)
           ON CONFLICT DO NOTHING RETURNING arm""", (key, group["id"], arm)).fetchone()
    if r:
        analytics.track(conn, "experiment_assigned", group_id=group["id"], arm=arm, config_version=cfg.version)
        return arm
    return conn.execute("SELECT arm FROM experiment_assignments WHERE experiment_key=%s AND group_id=%s",
                        (key, group["id"])).fetchone()["arm"]


def arm_of(conn, group_id: int, cfg) -> str | None:
    r = conn.execute("SELECT arm FROM experiment_assignments WHERE experiment_key=%s AND group_id=%s",
                     (cfg["experiment"]["key"], group_id)).fetchone()
    return r["arm"] if r else None


def active_member_ids(conn, group_id: int) -> list[int]:
    return [r["user_id"] for r in conn.execute(
        "SELECT user_id FROM group_members WHERE group_id=%s AND left_at IS NULL ORDER BY joined_at", (group_id,))]


def eligibility(conn, group_id: int, cfg) -> tuple[bool, str]:
    """(eligible, reason). Eligible means coin UI shows and rewards accrue for this group."""
    if not cfg["enabled"]:
        return False, "disabled"
    if cfg["kill_switch"]:
        return False, "kill_switch"
    g = conn.execute("SELECT * FROM groups WHERE id=%s", (group_id,)).fetchone()
    if g is None:
        return False, "no_group"
    if arm_of(conn, group_id, cfg) != "TREATMENT":
        return False, "control"
    if len(active_member_ids(conn, group_id)) < 2:
        return False, "solo"
    return True, "ok"
