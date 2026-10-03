"""New-user activation state (PRD goal 1: first confirmed expense with a roommate within 48h).

Computed from core data so it is always correct, whatever device or order the steps happened in.
"""
from fastapi import APIRouter, Depends

from . import analytics, clock, coin_config, db, domain, experiment, views
from .deps import current_user

router = APIRouter(prefix="/api/v1")


def state(conn, user: dict) -> dict:
    uid = user["id"]
    g = conn.execute(
        """SELECT g.* FROM groups g JOIN group_members m ON m.group_id=g.id
           WHERE m.user_id=%s AND m.left_at IS NULL
           ORDER BY (g.group_type='HOME') DESC, g.created_at DESC LIMIT 1""", (uid,)).fetchone()
    out = {"profile_done": bool(user["name"].strip()), "group": None, "steps": [], "activated": False,
           "next_step": None, "confirm_expense_id": None, "waiting_expense_id": None, "waiting_on": [],
           "coins_enabled": False}
    members = invites = 0
    has_expense = activated = False
    if g:
        cfg = coin_config.current(conn)
        members = len(experiment.active_member_ids(conn, g["id"]))
        invites = conn.execute("SELECT count(*) c FROM referrals WHERE group_id=%s AND inviter_id=%s",
                               (g["id"], uid)).fetchone()["c"]
        has_expense = conn.execute(
            """SELECT 1 FROM expenses e WHERE e.group_id=%s AND e.deleted_at IS NULL
               AND (SELECT count(*) FROM expense_splits s WHERE s.expense_id=e.id AND s.share_paise > 0) >= 2""",
            (g["id"],)).fetchone() is not None
        # activated: an expense involving me, confirmed by someone other than its adder
        activated = conn.execute(
            """SELECT 1 FROM expenses e JOIN expense_confirmations c
                 ON c.expense_id=e.id AND c.expense_version=e.version AND c.status='CONFIRMED'
               WHERE e.group_id=%s AND e.deleted_at IS NULL AND c.user_id <> e.created_by
                 AND (e.created_by=%s OR c.user_id=%s
                      OR EXISTS (SELECT 1 FROM expense_splits s WHERE s.expense_id=e.id AND s.user_id=%s))""",
            (g["id"], uid, uid, uid)).fetchone() is not None
        # invitee fast path: an expense waiting on my confirmation
        pending = conn.execute(
            """SELECT e.id FROM expenses e JOIN expense_splits s ON s.expense_id=e.id AND s.user_id=%s AND s.share_paise>0
               WHERE e.group_id=%s AND e.deleted_at IS NULL AND e.created_by<>%s
                 AND NOT EXISTS (SELECT 1 FROM expense_confirmations c WHERE c.expense_id=e.id
                                 AND c.expense_version=e.version AND c.user_id=%s)
               ORDER BY e.created_at DESC LIMIT 1""", (uid, g["id"], uid, uid)).fetchone()
        out["confirm_expense_id"] = pending["id"] if pending else None
        # creator fast path: my latest expense still waiting on roommates -> one-tap remind
        mine = conn.execute(
            """SELECT e.id FROM expenses e WHERE e.group_id=%s AND e.created_by=%s AND e.deleted_at IS NULL
               AND NOT EXISTS (SELECT 1 FROM expense_confirmations c WHERE c.expense_id=e.id AND c.expense_version=e.version)
               ORDER BY e.created_at DESC LIMIT 1""", (g["id"], uid)).fetchone()
        out["waiting_expense_id"] = None
        out["waiting_on"] = []
        if mine:
            e = domain.load_expense(conn, mine["id"])
            waiting = sorted(domain.participants(e) - {uid})
            names = domain.user_names(conn, waiting)
            out["waiting_expense_id"] = e["id"]
            out["waiting_on"] = [names.get(u) for u in waiting]
        out["coins_enabled"] = views.eligible(conn, g["id"], cfg) and not user["hide_coins"]
        out["group"] = {"id": g["id"], "name": g["name"], "member_count": members,
                        "expected_members": g["expected_members"], "created_by_me": g["created_by"] == uid,
                        "invites_sent": invites}
        out["first_win_coins"] = cfg["earn"]["first_win"]
    steps = [
        {"id": "flat", "title": "Set up your flat", "done": g is not None},
        {"id": "roommates", "title": "Bring in a roommate", "done": members >= 2},
        {"id": "expense", "title": "Add a shared expense", "done": has_expense},
        {"id": "confirm", "title": "Get it confirmed", "done": activated},
    ]
    out["steps"] = steps
    out["activated"] = activated
    out["next_step"] = next((s["id"] for s in steps if not s["done"]), None)
    out["account_age_hours"] = round((clock.now() - user["created_at"]).total_seconds() / 3600, 1)
    return out


@router.get("/me/activation")
def activation(user=Depends(current_user)):
    with db.tx() as conn:
        st = state(conn, user)
        if st["activated"]:
            # log the activation moment once per user (funnel: signup -> activated within 48h)
            seen = conn.execute("SELECT 1 FROM analytics_events WHERE name='user_activated' AND user_hash=%s",
                                (analytics.user_hash(user["id"]),)).fetchone()
            if not seen:
                gid = st["group"]["id"]
                cfg = coin_config.current(conn)
                analytics.track(conn, "user_activated", user_id=user["id"], group_id=gid,
                                arm=experiment.arm_of(conn, gid, cfg), config_version=cfg.version,
                                hours_since_signup=st["account_age_hours"],
                                within_48h=st["account_age_hours"] <= 48)
        return st
