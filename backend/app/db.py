import pathlib
from contextlib import contextmanager

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from .settings import settings

_pool: ConnectionPool | None = None
MIGRATIONS = pathlib.Path(__file__).resolve().parent.parent / "migrations"


def init_pool(url: str | None = None, size: int = 10) -> ConnectionPool:
    global _pool
    if _pool is not None:
        _pool.close()
    _pool = ConnectionPool(url or settings.database_url, min_size=1, max_size=size,
                           kwargs={"row_factory": dict_row, "autocommit": False}, open=True)
    return _pool


def pool() -> ConnectionPool:
    if _pool is None:
        init_pool()
    return _pool


@contextmanager
def tx():
    """One transaction. Commits on success, rolls back on error."""
    with pool().connection() as conn:
        with conn.transaction():
            yield conn


def migrate(conn=None) -> None:
    def run(c):
        c.execute("SELECT pg_advisory_xact_lock(42)")
        c.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz DEFAULT now())")
        done = {r["name"] for r in c.execute("SELECT name FROM schema_migrations").fetchall()}
        for f in sorted(MIGRATIONS.glob("*.sql")):
            if f.name not in done:
                c.execute(f.read_text())
                c.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (f.name,))
    if conn is not None:
        run(conn)
    else:
        with tx() as c:
            run(c)
