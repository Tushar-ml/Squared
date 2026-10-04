"""Base data (config v1, catalogue) and, in dev, a demo flat."""
import uuid
from datetime import timedelta

from . import clock, coin_config, db, events, experiment
from .settings import settings

# Placeholder brands: real partners are open question Q3.
CATALOG = [
    ("USER", "FreshBasket", "groceries", 25, 100, "FB-25"),
    ("USER", "QuickCart", "quick commerce", 50, 200, "QC-50"),
    ("USER", "FoodRun", "food delivery", 100, 400, "FR-100"),
    ("USER", "FiberNet", "broadband", 50, 200, "FN-50"),
    ("GROUP", "Group Feast", "food delivery", 200, 800, "FF-200-GRP"),
]

# Local dev: every Home group is in treatment and first redemptions are held ~1 minute.
DEV_OVERRIDES = {"experiment": {"treatment_share": 1.0}, "redemption": {"first_redemption_hold_hours": 0.02}}

DEMO_USERS = [("Aman", "aman@example.com", "aman@upi"),
              ("Priya", "priya@example.com", "priya@upi"),
              ("Rahul", "rahul@example.com", "rahul@upi")]
OPS_USER = ("ops@squared.local", "Ops Reviewer")   # dev only; production Ops access comes from OPS_EMAILS


def ensure_base(conn=None) -> None:
    if conn is None:
        with db.tx() as c:
            return ensure_base(c)
    conn.execute("SELECT pg_advisory_xact_lock(43)")
    coin_config.ensure_default(conn, DEV_OVERRIDES if settings.is_dev else None)
    if not conn.execute("SELECT 1 FROM catalog_items LIMIT 1").fetchone():
        for scope, brand, cat, face, cost, sku in CATALOG:
            conn.execute(
                """INSERT INTO catalog_items (id, scope, brand, category, face_value_inr, coin_cost, vendor_sku, funded_by)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,'internal')""", (uuid.uuid4(), scope, brand, cat, face, cost, sku))
    if settings.app_env == "dev":
        ensure_demo(conn)


def ensure_demo(conn) -> None:
    if conn.execute("SELECT 1 FROM users WHERE email=%s", (OPS_USER[0],)).fetchone():
        return
    old = clock.now() - timedelta(days=30)
    conn.execute("INSERT INTO users (email, name, verified, role, created_at) VALUES (%s,%s,true,'OPS',%s)",
                 (OPS_USER[0], OPS_USER[1], old))
    ids = []
    for i, (name, email, upi) in enumerate(DEMO_USERS):
        ids.append(conn.execute(
            """INSERT INTO users (name, email, upi_id, verified, device_fingerprint, created_at)
               VALUES (%s,%s,%s,true,%s,%s) RETURNING id""",
            (name, email, upi, f"demo-device-{i}", old)).fetchone()["id"])
    aman, priya, rahul = ids
    g = conn.execute(
        "INSERT INTO groups (name, group_type, expected_members, created_by, created_at) VALUES ('Flat 4B','HOME',4,%s,%s) RETURNING *",
        (aman, old)).fetchone()
    for u in ids:
        conn.execute("INSERT INTO group_members (group_id, user_id, joined_at) VALUES (%s,%s,%s)", (g["id"], u, old))
    cfg = coin_config.current(conn, fresh=True)
    experiment.assign(conn, g, cfg)
    now = clock.now()
    for desc, amount, payer in [("Wifi bill", 79900, rahul), ("Groceries", 120000, priya), ("Gas cylinder", 110000, aman)]:
        e = conn.execute(
            """INSERT INTO expenses (group_id, description, amount_paise, paid_by, created_by, created_at, updated_at)
               VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING id""", (g["id"], desc, amount, payer, payer, now, now)).fetchone()
        base, rem = divmod(amount, 3)
        for i, u in enumerate(sorted(ids)):
            conn.execute("INSERT INTO expense_splits (expense_id, user_id, share_paise) VALUES (%s,%s,%s)",
                         (e["id"], u, base + (1 if i < rem else 0)))
        events.emit(conn, "ExpenseCreated", expense_id=e["id"], group_id=g["id"], version=1, user_id=payer)
