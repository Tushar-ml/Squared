"""Redemption service (FR-8): catalogue, redeem, vendor adapter, refunds."""
import hashlib
import os
import smtplib
import uuid
from datetime import timedelta
from email.message import EmailMessage

import httpx
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from . import analytics, clock, coin_config, db, experiment, ledger
from .settings import settings


class RedeemError(Exception):
    def __init__(self, code: str, message: str, status: int = 400):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status = status


# ---------------------------------------------------------------- envelope encryption

def _master() -> bytes:
    return hashlib.sha256(settings.voucher_key.encode()).digest()


def encrypt_code(code: str) -> bytes:
    dk = AESGCM.generate_key(bit_length=256)
    n1, n2 = os.urandom(12), os.urandom(12)
    wrapped = AESGCM(_master()).encrypt(n1, dk, b"dk")
    ct = AESGCM(dk).encrypt(n2, code.encode(), b"voucher")
    return n1 + len(wrapped).to_bytes(2, "big") + wrapped + n2 + ct


def decrypt_code(blob: bytes) -> str:
    blob = bytes(blob)
    n1 = blob[:12]
    ln = int.from_bytes(blob[12:14], "big")
    wrapped = blob[14:14 + ln]
    n2 = blob[14 + ln:26 + ln]
    ct = blob[26 + ln:]
    dk = AESGCM(_master()).decrypt(n1, wrapped, b"dk")
    return AESGCM(dk).decrypt(n2, ct, b"voucher").decode()


# ---------------------------------------------------------------- vendor adapter

class VendorAdapter:
    """Swap vendors behind this interface (Q3)."""

    def issue(self, sku: str, reference: str) -> dict:
        r = httpx.post(f"{settings.vendor_url}/v1/vouchers", json={"sku": sku, "reference": reference},
                       timeout=settings.vendor_timeout)
        r.raise_for_status()
        return r.json()


vendor: VendorAdapter = VendorAdapter()


def send_email(to: str | None, subject: str, body: str) -> None:
    if not to or not settings.smtp_host:
        return
    try:
        msg = EmailMessage()
        msg["From"] = "coins@squared.local"
        msg["To"] = to
        msg["Subject"] = subject
        msg.set_content(body)
        with smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=3) as s:
            s.send_message(msg)
    except OSError:
        pass  # email is best effort; code is always shown in-app


# ---------------------------------------------------------------- redeem

def eligibility_errors(conn, user: dict, cfg, wallet: dict) -> RedeemError | None:
    r = cfg["redemption"]
    if not user["verified"]:
        return RedeemError("unverified", "Sign in with Google or Apple to redeem.")
    if clock.now() - user["created_at"] < timedelta(days=r["min_account_age_days"]):
        return RedeemError("account_too_new", f"Redeeming opens {r['min_account_age_days']} days after you join.")
    week_n = conn.execute(
        """SELECT count(*) c FROM redemptions WHERE redeemed_by=%s AND created_at >= %s
           AND status NOT IN ('FAILED','REFUNDED')""", (user["id"], clock.now() - timedelta(days=7))).fetchone()["c"]
    if week_n >= r["max_per_user_per_week"]:
        return RedeemError("weekly_limit", f"You can redeem {r['max_per_user_per_week']} vouchers a week.")
    if wallet["redemption_frozen"]:
        return RedeemError("frozen", "Redemption is paused on this wallet. Contact support.")
    if wallet["deficit"] > 0:
        return RedeemError("deficit", "Redemption is paused until reversed coins are earned back.")
    return None


def start(user_id: int, item_id: str, group_id: int | None, idem: str) -> dict:
    """Debit coins and create the redemption. Vendor is called after commit."""
    key = f"{user_id}:{idem}"
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        existing = conn.execute("SELECT * FROM redemptions WHERE idempotency_key=%s", (key,)).fetchone()
        if existing:
            return existing
        if not cfg["enabled"] or cfg["kill_switch"]:
            raise RedeemError("unavailable", "Coins unavailable right now", 503)
        if not cfg["redemption"].get("enabled"):
            raise RedeemError("coming_soon", "Redeeming coins is coming soon. Your coins are saved until then.", 403)
        user = conn.execute("SELECT * FROM users WHERE id=%s", (user_id,)).fetchone()
        item = conn.execute("SELECT * FROM catalog_items WHERE id=%s AND active", (item_id,)).fetchone()
        if not item:
            raise RedeemError("not_found", "This voucher is no longer available.", 404)
        if item["scope"] == "GROUP":
            if not group_id:
                raise RedeemError("group_required", "Choose a household to redeem from.")
            member = conn.execute("SELECT 1 FROM group_members WHERE group_id=%s AND user_id=%s AND left_at IS NULL",
                                  (group_id, user_id)).fetchone()
            if not member or not experiment.eligibility(conn, group_id, cfg)[0]:
                raise RedeemError("not_member", "You can only redeem from your own household pot.", 403)
            wallet = ledger.get_wallet(conn, "GROUP", group_id, lock=True)
        else:
            group_id = None
            wallet = ledger.get_wallet(conn, "USER", user_id, lock=True)
        err = eligibility_errors(conn, user, cfg, wallet)
        if err:
            raise err
        if wallet["balance_cached"] < item["coin_cost"]:
            raise RedeemError("insufficient", f"{item['coin_cost'] - wallet['balance_cached']} more coins needed.")
        first = not conn.execute(
            "SELECT 1 FROM redemptions WHERE redeemed_by=%s AND status IN ('FULFILLED','HELD','REQUESTED')",
            (user_id,)).fetchone()
        rid = uuid.uuid4()
        status = "HELD" if first and cfg["redemption"]["first_redemption_hold_hours"] > 0 else "REQUESTED"
        red = conn.execute(
            """INSERT INTO redemptions (id, wallet_id, redeemed_by, group_id, catalog_item_id, coins, status,
                   idempotency_key, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING *""",
            (rid, wallet["id"], user_id, group_id, item["id"], item["coin_cost"], status, key, clock.now(),
             clock.now())).fetchone()
        ledger.spend(conn, wallet["id"], item["coin_cost"], redemption_id=rid, cfg=cfg)
        analytics.track(conn, "redeem_started", user_id=user_id, group_id=group_id, config_version=cfg.version,
                        catalog_item_id=str(item["id"]), coins=item["coin_cost"])
    return red


def fulfil(redemption_id) -> dict:
    """Call the vendor outside any transaction; then fulfil or refund."""
    with db.tx() as conn:
        red = conn.execute("SELECT r.*, c.vendor_sku, c.brand, c.face_value_inr FROM redemptions r "
                           "JOIN catalog_items c ON c.id=r.catalog_item_id WHERE r.id=%s", (redemption_id,)).fetchone()
    if red is None or red["status"] in ("FULFILLED", "REFUNDED"):
        return red
    try:
        out = vendor.issue(red["vendor_sku"], str(red["id"]))
        failure = None
    except (httpx.HTTPError, ValueError) as exc:
        out, failure = None, type(exc).__name__
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        cur = conn.execute("SELECT * FROM redemptions WHERE id=%s FOR UPDATE", (redemption_id,)).fetchone()
        if cur["status"] in ("FULFILLED", "REFUNDED"):
            return cur
        if out:
            conn.execute("""UPDATE redemptions SET status='FULFILLED', vendor_ref=%s, code_encrypted=%s, updated_at=%s
                            WHERE id=%s""", (out["vendor_ref"], encrypt_code(out["code"]), clock.now(), redemption_id))
            analytics.track(conn, "redeem_succeeded", user_id=red["redeemed_by"], group_id=red["group_id"],
                            config_version=cfg.version, catalog_item_id=str(red["catalog_item_id"]), coins=red["coins"])
            user = conn.execute("SELECT email FROM users WHERE id=%s", (red["redeemed_by"],)).fetchone()
            email_to, code = user["email"], out["code"]
        else:
            conn.execute("UPDATE redemptions SET status='FAILED', failure_code=%s, updated_at=%s WHERE id=%s",
                         (failure, clock.now(), redemption_id))
            ledger.refund(conn, red["wallet_id"], redemption_id=redemption_id, cfg=cfg)
            conn.execute("UPDATE redemptions SET status='REFUNDED', updated_at=%s WHERE id=%s",
                         (clock.now(), redemption_id))
            analytics.track(conn, "redeem_failed", user_id=red["redeemed_by"], group_id=red["group_id"],
                            config_version=cfg.version, catalog_item_id=str(red["catalog_item_id"]),
                            coins=red["coins"], failure_code=failure)
            email_to = None
        final = conn.execute("SELECT * FROM redemptions WHERE id=%s", (redemption_id,)).fetchone()
    if email_to:
        send_email(email_to, f"Your INR {red['face_value_inr']} {red['brand']} voucher",
                   f"Here is your voucher code: {code}\n\nThanks for keeping things square.")
    return final


def release_held(older_than_hours: float | None = None) -> int:
    """Worker job: fulfil HELD redemptions whose review window has passed."""
    with db.tx() as conn:
        cfg = coin_config.current(conn, fresh=True)
        hours = cfg["redemption"]["first_redemption_hold_hours"] if older_than_hours is None else older_than_hours
        ids = [r["id"] for r in conn.execute(
            "SELECT id FROM redemptions WHERE status='HELD' AND created_at <= %s",
            (clock.now() - timedelta(hours=hours),))]
        ids += [r["id"] for r in conn.execute(
            "SELECT id FROM redemptions WHERE status='REQUESTED' AND created_at <= %s",
            (clock.now() - timedelta(seconds=30),))]  # recover requests whose vendor call never ran
    for rid in ids:
        fulfil(rid)
    return len(ids)
