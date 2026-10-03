"""Goal service: weekly household progress, week close and pot coins (FR-7)."""
from datetime import date, datetime, timedelta

from . import analytics, clock, domain, experiment, ledger, notify


def counted_expenses(conn, group_id: int, week_start: date, cfg) -> list[int]:
    """Expenses whose current version was first confirmed in this IST week by an active member,
    are not disputed, not deleted, and meet the minimum amount."""
    start, end = clock.week_bounds(week_start)
    rows = conn.execute(
        """SELECT e.id FROM expenses e
           WHERE e.group_id=%s AND e.deleted_at IS NULL AND e.amount_paise >= %s AND e.currency='INR'
             AND COALESCE(e.original_currency, 'INR')='INR'
             AND NOT EXISTS (SELECT 1 FROM expense_confirmations d WHERE d.expense_id=e.id
                             AND d.expense_version=e.version AND d.status='DISPUTED')
             AND (SELECT MIN(c.created_at) FROM expense_confirmations c
                  JOIN group_members m ON m.group_id=e.group_id AND m.user_id=c.user_id AND m.left_at IS NULL
                  WHERE c.expense_id=e.id AND c.expense_version=e.version AND c.status='CONFIRMED') >= %s
             AND (SELECT MIN(c.created_at) FROM expense_confirmations c
                  JOIN group_members m ON m.group_id=e.group_id AND m.user_id=c.user_id AND m.left_at IS NULL
                  WHERE c.expense_id=e.id AND c.expense_version=e.version AND c.status='CONFIRMED') < %s
           ORDER BY e.id""", (group_id, cfg["min_expense_inr"] * 100, start, end)).fetchall()
    return [r["id"] for r in rows]


def _goal_row(conn, group_id, week_start, cfg):
    conn.execute(
        """INSERT INTO household_goals (group_id, week_start, target) VALUES (%s,%s,%s)
           ON CONFLICT DO NOTHING""", (group_id, week_start, cfg["earn"]["household_goal_target"]))
    return conn.execute("SELECT * FROM household_goals WHERE group_id=%s AND week_start=%s FOR UPDATE",
                        (group_id, week_start)).fetchone()


def refresh_progress(conn, group_id: int, cfg, week_start: date | None = None) -> dict:
    ws = week_start or clock.ist_week_start()
    row = _goal_row(conn, group_id, ws, cfg)
    if row["status"] != "OPEN":
        return row
    progress = len(counted_expenses(conn, group_id, ws, cfg))
    conn.execute("UPDATE household_goals SET progress=%s WHERE group_id=%s AND week_start=%s", (progress, group_id, ws))
    row["progress"] = progress
    return row


def close_week(conn, group_id: int, week_start, cfg) -> dict:
    if isinstance(week_start, str):
        week_start = date.fromisoformat(week_start)
    row = refresh_progress(conn, group_id, cfg, week_start)
    if row["status"] != "OPEN":
        return row
    eligible, _ = experiment.eligibility(conn, group_id, cfg)
    arm = experiment.arm_of(conn, group_id, cfg)
    members = experiment.active_member_ids(conn, group_id)
    met = eligible and row["progress"] >= row["target"] and len(members) >= 2
    entry = None
    if met:
        pot = ledger.get_wallet(conn, "GROUP", group_id, lock=True)
        entry = ledger.earn(conn, pot, amount=cfg["earn"]["household_goal"], reason="HOUSEHOLD_GOAL",
                            source_type="GOAL", source_id=group_id, source_version=week_start.toordinal(), cfg=cfg,
                            group_id=group_id, metadata={"week_start": week_start.isoformat(),
                                                         "progress": row["progress"]})
    status = "MET" if met else "MISSED"
    conn.execute("UPDATE household_goals SET status=%s, reward_entry_id=%s WHERE group_id=%s AND week_start=%s",
                 (status, entry["id"] if entry else None, group_id, week_start))
    analytics.track(conn, "household_goal_met" if met else "household_goal_missed", group_id=group_id, arm=arm,
                    config_version=cfg.version, week_start=week_start.isoformat(), progress=row["progress"])
    if eligible:
        _recap(conn, group_id, week_start, row["progress"], met, cfg)
    row["status"] = status
    return row


def _recap(conn, group_id, week_start: date, progress: int, met: bool, cfg):
    """S11 / N5: Monday recap at recap_hour IST. Never shaming."""
    g = conn.execute("SELECT name FROM groups WHERE id=%s", (group_id,)).fetchone()
    target = cfg["earn"]["household_goal_target"]
    monday = week_start + timedelta(days=7)
    at = datetime(monday.year, monday.month, monday.day, cfg["push"]["recap_hour"], tzinfo=clock.IST)
    from . import i18n
    for uid in experiment.active_member_ids(conn, group_id):
        loc = i18n.locale_of(conn, uid)
        body = i18n.t(loc, "n5_met" if met else "n5_missed", group=g["name"], progress=progress, target=target)
        notify.enqueue(conn, cfg, user_id=uid, nid="N5", group_id=group_id, title=g["name"], body=body,
                       dedupe_key=f"N5:{group_id}:{week_start.isoformat()}:{uid}",
                       payload={"group_id": group_id, "route": "household"}, deliver_after=max(at, clock.now()))


def summary(conn, group_id: int, viewer_id: int, cfg) -> dict:
    ws = clock.ist_week_start()
    row = refresh_progress(conn, group_id, cfg, ws)
    pot = ledger.get_wallet(conn, "GROUP", group_id)
    squared = conn.execute("SELECT count(*) c FROM household_goals WHERE group_id=%s AND status='MET'",
                           (group_id,)).fetchone()["c"]
    start, end = clock.week_bounds(ws)
    members = experiment.active_member_ids(conn, group_id)
    names = domain.user_names(conn, members)
    ticks = {r["user_id"] for r in conn.execute(
        """SELECT DISTINCT c.user_id FROM expense_confirmations c JOIN expenses e ON e.id=c.expense_id
           WHERE e.group_id=%s AND c.status='CONFIRMED' AND c.created_at >= %s AND c.created_at < %s""",
        (group_id, start, end))}
    last = conn.execute(
        "SELECT * FROM household_goals WHERE group_id=%s AND week_start=%s", (group_id, ws - timedelta(days=7))).fetchone()
    pot_redemptions = conn.execute(
        """SELECT r.id, r.redeemed_by, r.coins, r.status, r.created_at, c.brand, c.face_value_inr
           FROM redemptions r JOIN catalog_items c ON c.id=r.catalog_item_id
           WHERE r.wallet_id=%s ORDER BY r.created_at DESC LIMIT 10""", (pot["id"],)).fetchall()
    rnames = domain.user_names(conn, [r["redeemed_by"] for r in pot_redemptions])
    g = conn.execute("SELECT * FROM groups WHERE id=%s", (group_id,)).fetchone()
    return {
        "group_id": group_id,
        "week_start": ws.isoformat(),
        "target": row["target"],
        "progress": row["progress"],
        "goal_met": row["progress"] >= row["target"],
        "goal_reward": cfg["earn"]["household_goal"],
        "pot_coins": pot["balance_cached"],
        "pot_inr": round(pot["balance_cached"] * cfg["coin_value_inr"], 2),
        "weeks_squared": squared,
        "members": [{"user_id": m, "name": names.get(m), "confirmed_this_week": m in ticks,
                     "is_you": m == viewer_id} for m in members],
        "expected_members": g["expected_members"],
        "last_week": None if not last else {"progress": last["progress"], "status": last["status"],
                                             "target": last["target"]},
        "pot_redemptions": [{"id": str(r["id"]), "redeemed_by": rnames.get(r["redeemed_by"]), "brand": r["brand"],
                             "face_value_inr": r["face_value_inr"], "coins": r["coins"], "status": r["status"],
                             "created_at": r["created_at"].isoformat()} for r in pot_redemptions],
    }
