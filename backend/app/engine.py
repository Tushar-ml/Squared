"""Reward engine (PRD 8.5). Consumes outbox events; one DB transaction per event.

Every coin amount, cap and threshold comes from the pinned config (I-5). Replaying any
event yields the same ledger thanks to idempotency keys (I-4).
"""
import hashlib
import hmac
import uuid
from datetime import timedelta

from . import analytics, clock, coin_config, domain, experiment, fx, goals, i18n, ledger, notify
from .settings import settings


# ---------------------------------------------------------------- helpers

def surprise_draw(payment_id, cfg) -> tuple[float, int]:
    """Deterministic per payment: u = HMAC_SHA256(secret, 'surprise:'+id) mapped to [0,1)."""
    digest = hmac.new(settings.surprise_secret.encode(), f"surprise:{payment_id}".encode(), hashlib.sha256).digest()
    u = int.from_bytes(digest[:8], "big") / 2**64
    return u, multiplier_for(u, cfg)


def multiplier_for(u: float, cfg) -> int:
    s = cfg["surprise"]
    if u < s["p_3x"]:
        return 3
    if u < s["p_3x"] + s["p_2x"]:
        return 2
    return 1


class Candidate:
    def __init__(self, user_id, amount, reason, rule=None, counterparty=None, capped=True, source_version=None):
        self.user_id = user_id
        self.amount = amount
        self.reason = reason
        self.rule = rule or reason.lower()
        self.counterparty = counterparty
        self.capped = capped  # subject to user daily/monthly caps
        self.source_version = source_version
        self.caps_applied: list[str] = []
        self.wallet = None
        self.source = None  # (source_type, source_id, source_version) override, e.g. first win is per user


def _shared_device_group(conn, group_id) -> bool:
    """AB-2: every active member shares one device fingerprint."""
    rows = conn.execute(
        """SELECT u.device_fingerprint fp FROM group_members m JOIN users u ON u.id=m.user_id
           WHERE m.group_id=%s AND m.left_at IS NULL""", (group_id,)).fetchall()
    fps = {r["fp"] for r in rows}
    return len(rows) >= 2 and len(fps) == 1 and None not in fps


def _risk_score(conn, user_id, counterparty, cfg) -> float:
    r = cfg["risk"]
    u = conn.execute("SELECT created_at, device_fingerprint FROM users WHERE id=%s", (user_id,)).fetchone()
    score = 0.0
    if clock.now() - u["created_at"] < timedelta(days=r["new_account_days"]):
        score += r["new_account_weight"]
    if counterparty:
        c = conn.execute("SELECT device_fingerprint FROM users WHERE id=%s", (counterparty,)).fetchone()
        if c and u["device_fingerprint"] and c["device_fingerprint"] == u["device_fingerprint"]:
            score += r["shared_device_weight"]
    start, end = clock.ist_day_bounds()
    w = ledger.get_wallet(conn, "USER", user_id)
    n = conn.execute("SELECT count(*) c FROM coin_ledger WHERE wallet_id=%s AND entry_type='EARN' AND created_at >= %s",
                     (w["id"], start)).fetchone()["c"]
    if n >= r["velocity_daily_earn_events"]:
        score += r["velocity_weight"]
    return round(score, 3)


def _apply_user_caps(conn, cands: list[Candidate], cfg) -> None:
    day = clock.ist_day_bounds()
    month = clock.ist_month_bounds()
    used: dict[str, list[int]] = {}
    for c in cands:
        if not c.capped or c.amount <= 0:
            continue
        wid = str(c.wallet["id"])
        if wid not in used:
            used[wid] = [ledger.cap_sum(conn, wid, *day), ledger.cap_sum(conn, wid, *month)]
        d_left = cfg["caps"]["user_daily"] - used[wid][0]
        m_left = cfg["caps"]["user_monthly"] - used[wid][1]
        allowed = max(0, min(c.amount, d_left, m_left))
        if allowed < c.amount:
            c.caps_applied.append("cap_user_daily" if d_left <= m_left else "cap_user_monthly")
        c.amount = allowed
        used[wid][0] += allowed
        used[wid][1] += allowed


def _write(conn, cands: list[Candidate], *, source_type, source_id, source_version, group_id, cfg, arm,
           extra_meta=None) -> list[tuple[Candidate, dict]]:
    written = []
    for c in cands:
        if c.caps_applied:
            for cap in c.caps_applied:
                conn.execute(
                    """INSERT INTO reward_notices (user_id, cap_key, source_key, created_at) VALUES (%s,%s,%s,%s)
                       ON CONFLICT DO NOTHING""",
                    (c.user_id, cap, f"{source_type}:{source_id}:{source_version}", clock.now()))
                analytics.track(conn, "cap_hit", user_id=c.user_id, group_id=group_id, arm=arm,
                                config_version=cfg.version, cap_key=cap)
        if c.amount <= 0:
            continue
        risk = _risk_score(conn, c.user_id, c.counterparty, cfg)
        pending = risk >= cfg["risk"]["threshold"]
        meta = {"caps_applied": c.caps_applied, "risk_score": risk, **(extra_meta or {})}
        st, sid, sv = c.source or (source_type, source_id, c.source_version or source_version)
        e = ledger.earn(conn, c.wallet, amount=c.amount, reason=c.reason, rule=c.rule, source_type=st,
                        source_id=sid, source_version=sv, cfg=cfg,
                        group_id=group_id, counterparty=c.counterparty, metadata=meta, pending=pending)
        if e is None:
            continue
        written.append((c, e))
        analytics.track(conn, "coins_earned", user_id=c.user_id, group_id=group_id, arm=arm,
                        config_version=cfg.version, reason_code=c.reason, amount=c.amount,
                        cap_applied=bool(c.caps_applied), pending=pending)
    return written


def _maybe_first_redeem_push(conn, user_ids, cfg, group_id=None):
    for uid in set(user_ids):
        w = ledger.get_wallet(conn, "USER", uid)
        if w["balance_cached"] >= cfg["push"]["first_redeem_threshold"]:
            cheapest = conn.execute("SELECT min(face_value_inr) v FROM catalog_items WHERE scope='USER' AND active").fetchone()["v"]
            loc = i18n.locale_of(conn, uid)
            notify.enqueue(conn, cfg, user_id=uid, nid="N6", title=i18n.t(loc, "n6_title"),
                           body=i18n.t(loc, "n6_body", value=cheapest or 25), dedupe_key=f"N6:{uid}",
                           group_id=group_id, payload={"route": "redeem"})


def _celebrate(conn, user_id, kind, coins, title, source_key, multiplier=None, bonus=0):
    conn.execute(
        """INSERT INTO celebrations (id, user_id, kind, coins, bonus_multiplier, bonus_coins, title, source_key, created_at)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT (source_key) DO NOTHING""",
        (uuid.uuid4(), user_id, kind, coins, multiplier, bonus, title, source_key, clock.now()))


def _group_currency(conn, group_id) -> str:
    return conn.execute("SELECT currency FROM groups WHERE id=%s", (group_id,)).fetchone()["currency"]


# ---------------------------------------------------------------- handlers

def on_expense_created(conn, ev, cfg):
    e = domain.load_expense(conn, ev["expense_id"])
    if not e or e["deleted_at"]:
        return
    ok, _ = experiment.eligibility(conn, e["group_id"], cfg)
    if not ok:
        return
    names = domain.user_names(conn, [e["created_by"]] + [s["user_id"] for s in e["splits"]])
    adder = names.get(e["created_by"], "Someone")
    shares = {s["user_id"]: s["share_paise"] for s in e["splits"]}
    for uid in sorted(domain.participants(e) - {e["created_by"]}):
        share = shares.get(uid, 0)
        loc = i18n.locale_of(conn, uid)
        notify.enqueue(
            conn, cfg, user_id=uid, nid="N1", group_id=e["group_id"],
            title=i18n.t(loc, "n1_title"),
            body=i18n.t(loc, "n1_body", adder=adder, desc=e["description"], amount=fx.fmt(e["amount_paise"], e["currency"]),
                        share=fx.fmt(share, e["currency"])),
            dedupe_key=f"N1:{e['id']}:{e['version']}:{uid}",
            payload={"expense_id": e["id"], "version": e["version"], "group_id": e["group_id"]},
            batch_key=f"{e['group_id']}:{e['created_by']}", batch_title=i18n.t(loc, "n1_batch_title"),
            batch_body=i18n.t(loc, "n1_batch_body", adder=adder))


def on_expense_confirmed(conn, ev, cfg):
    e = domain.load_expense(conn, ev["expense_id"])
    if not e or e["deleted_at"] or e["version"] != ev["version"]:
        return
    gid = e["group_id"]
    ok, _ = experiment.eligibility(conn, gid, cfg)
    arm = experiment.arm_of(conn, gid, cfg)
    if ok:
        goals.refresh_progress(conn, gid, cfg)
    if not ok or not domain.is_inr(e):
        return
    confs = domain.confirmations(conn, e["id"], e["version"])
    if any(c["status"] == "DISPUTED" for c in confs):  # AB-6
        return
    confirmer = ev["user_id"]
    mine = next((c for c in confs if c["user_id"] == confirmer and c["status"] == "CONFIRMED"), None)
    adder = e["created_by"]
    if mine is None or confirmer == adder or confirmer not in domain.participants(e):  # AB-1
        return
    verified = conn.execute("SELECT phone_verified FROM users WHERE id=%s", (confirmer,)).fetchone()["phone_verified"]
    if not verified:
        return
    if e["amount_paise"] < cfg["min_expense_inr"] * 100 or _shared_device_group(conn, gid):  # AB-2
        return
    confirmers = [c["user_id"] for c in confs if c["status"] == "CONFIRMED"]
    if confirmers.index(confirmer) >= cfg["earn"]["max_confirmers_per_expense"]:
        return

    cands = [Candidate(confirmer, cfg["earn"]["expense_confirmer"], "EXPENSE_CONFIRMER", counterparty=adder),
             Candidate(adder, cfg["earn"]["expense_adder"], "EXPENSE_ADDER", counterparty=confirmer)]
    # caps on rewarded expenses for the group and per pair; they withhold both entries
    day_start, day_end = clock.ist_day_bounds()
    group_n = conn.execute(
        """SELECT count(DISTINCT source_id) c FROM coin_ledger WHERE group_id=%s AND reason_code='EXPENSE_ADDER'
           AND status IN ('POSTED','PENDING') AND created_at >= %s AND created_at < %s AND source_id <> %s""",
        (gid, day_start, day_end, str(e["id"]))).fetchone()["c"]
    already_rewarded = conn.execute(
        "SELECT 1 FROM coin_ledger WHERE source_type='EXPENSE' AND source_id=%s AND source_version=%s AND reason_code='EXPENSE_ADDER'",
        (str(e["id"]), e["version"])).fetchone()
    cw = ledger.get_wallet(conn, "USER", confirmer)
    pair_n = conn.execute(
        """SELECT count(*) c FROM coin_ledger WHERE wallet_id=%s AND reason_code='EXPENSE_CONFIRMER'
           AND counterparty_user_id=%s AND status IN ('POSTED','PENDING') AND created_at >= %s AND created_at < %s""",
        (cw["id"], adder, day_start, day_end)).fetchone()["c"]
    for c in cands:
        if group_n >= cfg["caps"]["group_daily_rewarded_expenses"] and not already_rewarded:
            c.caps_applied.append("cap_group_daily_rewarded_expenses")
            c.amount = 0
        elif pair_n >= cfg["caps"]["pair_daily_confirmations"]:
            c.caps_applied.append("cap_pair_daily_confirmations")
            c.amount = 0

    # first win and invite rewards (excluded from caps)
    for uid in (adder, confirmer):
        w = ledger.get_wallet(conn, "USER", uid)
        if not conn.execute("SELECT 1 FROM coin_ledger WHERE wallet_id=%s AND reason_code='FIRST_WIN'", (w["id"],)).fetchone():
            fw = Candidate(uid, cfg["earn"]["first_win"], "FIRST_WIN", capped=False,
                           counterparty=confirmer if uid == adder else adder)
            fw.source = ("USER", uid, 1)  # once ever per user, whatever expense triggers it
            cands.append(fw)
    referral_cands = _invite_candidates(conn, gid, (adder, confirmer), cfg)

    wallets = {}
    for c in cands + [rc for rc, _ in referral_cands]:
        wallets.setdefault(c.user_id, ledger.get_wallet(conn, "USER", c.user_id))
    ledger.lock_wallets(conn, [w["id"] for w in wallets.values()])
    for c in cands + [rc for rc, _ in referral_cands]:
        c.wallet = wallets[c.user_id]
    _apply_user_caps(conn, cands, cfg)

    written = _write(conn, cands, source_type="EXPENSE", source_id=e["id"], source_version=e["version"],
                     group_id=gid, cfg=cfg, arm=arm)
    for c, entry in written:
        if c.reason == "FIRST_WIN" and entry["status"] == "POSTED":
            _celebrate(conn, c.user_id, "FIRST_WIN", c.amount, "Your first confirmed expense",
                       f"first_win:{c.user_id}")
    for rc, ref in referral_cands:
        w = _write(conn, [rc], source_type="REFERRAL", source_id=ref["id"], source_version=1, group_id=gid,
                   cfg=cfg, arm=arm)
        if w:
            conn.execute("UPDATE referrals SET status='REWARDED' WHERE id=%s", (ref["id"],))
            analytics.track(conn, "invite_rewarded", user_id=rc.user_id, group_id=gid, arm=arm,
                            config_version=cfg.version, channel="whatsapp")
    _maybe_first_redeem_push(conn, [c.user_id for c, _ in written], cfg, gid)


def _invite_candidates(conn, gid, user_ids, cfg):
    out = []
    for uid in set(user_ids):
        ref = conn.execute("SELECT * FROM referrals WHERE invitee_id=%s AND group_id=%s AND status='JOINED'",
                           (uid, gid)).fetchone()
        if not ref:
            continue
        rewarded = conn.execute(
            "SELECT count(*) c FROM referrals WHERE inviter_id=%s AND status='REWARDED'", (ref["inviter_id"],)).fetchone()["c"]
        if rewarded >= cfg["earn"]["max_rewarded_invitees"]:
            continue
        amt = cfg["earn"]["invite_each"]
        out.append((Candidate(uid, amt, "INVITE", rule="invite", capped=False, counterparty=ref["inviter_id"]), ref))
        out.append((Candidate(ref["inviter_id"], amt, "INVITE", rule="invite", capped=False, counterparty=uid), ref))
    return out


def on_expense_disputed(conn, ev, cfg):
    e = domain.load_expense(conn, ev["expense_id"])
    if not e:
        return
    ledger.reverse_source(conn, source_type="EXPENSE", source_id=e["id"], cfg=cfg, only_version=ev["version"],
                          reason="disputed", reason_codes=("EXPENSE_ADDER", "EXPENSE_CONFIRMER"))
    ok, _ = experiment.eligibility(conn, e["group_id"], cfg)
    if not ok:
        return
    goals.refresh_progress(conn, e["group_id"], cfg)
    who = domain.user_names(conn, [ev["user_id"]]).get(ev["user_id"], "Someone")
    loc = i18n.locale_of(conn, e["created_by"])
    notify.enqueue(conn, cfg, user_id=e["created_by"], nid="N9", group_id=e["group_id"], title=i18n.t(loc, "dispute_title"),
                   body=i18n.t(loc, "dispute_body", name=who, desc=e["description"]),
                   dedupe_key=f"N9:dispute:{e['id']}:{e['version']}:{ev['user_id']}",
                   payload={"expense_id": e["id"], "group_id": e["group_id"]})


def on_expense_updated(conn, ev, cfg):
    e = domain.load_expense(conn, ev["expense_id"])
    if not e:
        return
    if ev.get("money_changed"):  # AB-3
        ledger.reverse_source(conn, source_type="EXPENSE", source_id=e["id"], cfg=cfg, max_version=ev["version"],
                              reason="edited", reason_codes=("EXPENSE_ADDER", "EXPENSE_CONFIRMER"))
        if experiment.eligibility(conn, e["group_id"], cfg)[0]:
            goals.refresh_progress(conn, e["group_id"], cfg)
            on_expense_created(conn, {"expense_id": e["id"]}, cfg)


def on_expense_deleted(conn, ev, cfg):  # AB-4
    ledger.reverse_source(conn, source_type="EXPENSE", source_id=ev["expense_id"], cfg=cfg, reason="deleted",
                          reason_codes=("EXPENSE_ADDER", "EXPENSE_CONFIRMER"))
    e = domain.load_expense(conn, ev["expense_id"])
    if e and experiment.eligibility(conn, e["group_id"], cfg)[0]:
        goals.refresh_progress(conn, e["group_id"], cfg)


def on_payment_recorded(conn, ev, cfg):
    p = conn.execute("SELECT * FROM payments WHERE id=%s", (ev["payment_id"],)).fetchone()
    if not p or p["deleted_at"] or not experiment.eligibility(conn, p["group_id"], cfg)[0]:
        return
    payer = domain.user_names(conn, [p["payer_id"]]).get(p["payer_id"], "Someone")
    loc = i18n.locale_of(conn, p["receiver_id"])
    notify.enqueue(conn, cfg, user_id=p["receiver_id"], nid="N2", group_id=p["group_id"], title=i18n.t(loc, "n2_title"),
                   body=i18n.t(loc, "n2_body", payer=payer, amount=fx.fmt(p["amount_paise"], _group_currency(conn, p["group_id"]))),
                   dedupe_key=f"N2:{p['id']}", payload={"payment_id": p["id"], "group_id": p["group_id"]})


def on_payment_rejected(conn, ev, cfg):
    p = conn.execute("SELECT * FROM payments WHERE id=%s", (ev["payment_id"],)).fetchone()
    if not p or not experiment.eligibility(conn, p["group_id"], cfg)[0]:
        return
    rec = domain.user_names(conn, [p["receiver_id"]]).get(p["receiver_id"], "They")
    loc = i18n.locale_of(conn, p["payer_id"])
    notify.enqueue(conn, cfg, user_id=p["payer_id"], nid="N9", group_id=p["group_id"], title=i18n.t(loc, "reject_title"),
                   body=i18n.t(loc, "reject_body", name=rec), dedupe_key=f"N9:reject:{p['id']}",
                   payload={"payment_id": p["id"], "group_id": p["group_id"]})


def on_payment_confirmed(conn, ev, cfg):
    p = conn.execute("SELECT * FROM payments WHERE id=%s", (ev["payment_id"],)).fetchone()
    pc = domain.payment_state(conn, ev["payment_id"])
    if not p or p["deleted_at"] or not pc or pc["status"] != "CONFIRMED":
        return
    gid = p["group_id"]
    ok, _ = experiment.eligibility(conn, gid, cfg)
    arm = experiment.arm_of(conn, gid, cfg)
    if not ok:
        return
    payer, receiver = p["payer_id"], p["receiver_id"]
    if not conn.execute("SELECT phone_verified FROM users WHERE id=%s", (receiver,)).fetchone()["phone_verified"]:
        return
    cleared = (payer, receiver) not in domain.pair_debts(conn, gid)
    if p["amount_paise"] < cfg["min_payment_inr"] * 100 and not cleared:
        return
    window = timedelta(days=cfg["ping_pong_days"])
    pingpong = conn.execute(
        """SELECT 1 FROM payments WHERE group_id=%s AND payer_id=%s AND receiver_id=%s AND deleted_at IS NULL
           AND amount_paise=%s AND created_at BETWEEN %s AND %s AND id <> %s""",
        (gid, receiver, payer, p["amount_paise"], p["created_at"] - window, p["created_at"], p["id"])).fetchone()
    if pingpong:  # AB-5
        return
    if _shared_device_group(conn, gid):
        return
    start = domain.debt_age_start(conn, gid, payer, receiver, p)
    quick = start is not None and p["created_at"] - start <= timedelta(hours=cfg["earn"]["quick_window_hours"])
    cands = [Candidate(payer, cfg["earn"]["settle_payer"], "SETTLE_PAYER", counterparty=receiver)]
    if quick:
        cands.append(Candidate(payer, cfg["earn"]["settle_quick_bonus"], "SETTLE_QUICK_BONUS", counterparty=receiver))
    cands.append(Candidate(receiver, cfg["earn"]["settle_receiver"], "SETTLE_RECEIVER", counterparty=payer))
    wallets = {u: ledger.get_wallet(conn, "USER", u) for u in (payer, receiver)}
    ledger.lock_wallets(conn, [w["id"] for w in wallets.values()])
    for c in cands:
        c.wallet = wallets[c.user_id]
    _apply_user_caps(conn, cands, cfg)
    u, mult = surprise_draw(p["id"], cfg)
    meta = {"debt_age_start": start.isoformat() if start else None}
    written = _write(conn, cands, source_type="PAYMENT", source_id=p["id"], source_version=1, group_id=gid, cfg=cfg,
                     arm=arm, extra_meta=meta)
    payer_coins = sum(c.amount for c, e in written if c.user_id == payer)
    bonus = 0
    if mult > 1 and payer_coins > 0:
        bonus = (mult - 1) * payer_coins
        b = Candidate(payer, bonus, "SURPRISE_BONUS", capped=False, counterparty=receiver)
        b.wallet = wallets[payer]
        _write(conn, [b], source_type="PAYMENT", source_id=p["id"], source_version=1, group_id=gid, cfg=cfg, arm=arm,
               extra_meta={"u": u, "multiplier": mult})
    analytics.track(conn, "surprise_drawn", user_id=payer, group_id=gid, arm=arm, config_version=cfg.version,
                    multiplier=mult, u=round(u, 6))
    names = domain.user_names(conn, [payer, receiver])
    if payer_coins > 0:
        when = ""
        if quick and start is not None:
            when = ", same day" if clock.ist(p["created_at"]).date() == clock.ist(start).date() else ", quickly"
        _celebrate(conn, payer, "SETTLEMENT", payer_coins, f"Settled with {names.get(receiver)}{when}",
                   f"settle:{p['id']}:{payer}", multiplier=mult if bonus else None, bonus=bonus)
    rec_coins = sum(c.amount for c, e in written if c.user_id == receiver)
    if rec_coins > 0:
        _celebrate(conn, receiver, "SETTLEMENT", rec_coins, f"{names.get(payer)}'s payment confirmed",
                   f"settle:{p['id']}:{receiver}")
    _maybe_first_redeem_push(conn, [payer, receiver], cfg, gid)


def on_payment_deleted(conn, ev, cfg):
    ledger.reverse_source(conn, source_type="PAYMENT", source_id=ev["payment_id"], cfg=cfg, reason="deleted")


def on_member_joined(conn, ev, cfg):
    gid = ev["group_id"]
    if ev.get("referral_id"):
        ref = conn.execute("SELECT * FROM referrals WHERE id=%s", (ev["referral_id"],)).fetchone()
        if ref:
            g = conn.execute("SELECT * FROM groups WHERE id=%s", (gid,)).fetchone()
            who = domain.user_names(conn, [ev["user_id"]]).get(ev["user_id"], "Someone")
            if experiment.eligibility(conn, gid, cfg)[0]:
                loc = i18n.locale_of(conn, ref["inviter_id"])
                notify.enqueue(conn, cfg, user_id=ref["inviter_id"], nid="N8", group_id=gid, title=i18n.t(loc, "n8_title"),
                               body=i18n.t(loc, "n8_body", name=who, group=domain.display_name(conn, g, ref["inviter_id"])), dedupe_key=f"N8:{ref['id']}",
                               payload={"group_id": gid})
            analytics.track(conn, "invite_joined", user_id=ev["user_id"], group_id=gid,
                            arm=experiment.arm_of(conn, gid, cfg), config_version=cfg.version, channel="link")


def on_member_left(conn, ev, cfg):
    if experiment.eligibility(conn, ev["group_id"], cfg)[0]:
        goals.refresh_progress(conn, ev["group_id"], cfg)


def on_week_closed(conn, ev, cfg):
    goals.close_week(conn, ev["group_id"], ev["week_start"], cfg)


HANDLERS = {
    "ExpenseCreated": on_expense_created,
    "ExpenseConfirmed": on_expense_confirmed,
    "ExpenseDisputed": on_expense_disputed,
    "ExpenseUpdated": on_expense_updated,
    "ExpenseDeleted": on_expense_deleted,
    "PaymentRecorded": on_payment_recorded,
    "PaymentConfirmed": on_payment_confirmed,
    "PaymentRejected": on_payment_rejected,
    "PaymentDeleted": on_payment_deleted,
    "MemberJoined": on_member_joined,
    "MemberLeft": on_member_left,
    "WeekClosed": on_week_closed,
}


def process(conn, event_type: str, payload: dict) -> None:
    """Process one event inside the caller's transaction. Config version is pinned here."""
    cfg = coin_config.current(conn, fresh=True)
    if not cfg["enabled"] or cfg["kill_switch"]:
        return  # kill switch: no new coins (FR-1)
    handler = HANDLERS.get(event_type)
    if handler:
        handler(conn, payload, cfg)
