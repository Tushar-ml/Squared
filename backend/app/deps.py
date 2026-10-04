from fastapi import Depends, Header, HTTPException

from . import db


def current_user(authorization: str | None = Header(default=None)) -> dict:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Sign in required")
    token = authorization.split(" ", 1)[1].strip()
    with db.tx() as conn:
        u = conn.execute(
            "SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token=%s AND u.deleted_at IS NULL", (token,)).fetchone()
    if not u:
        raise HTTPException(401, "Session expired")
    return u


def ops_user(user: dict = Depends(current_user)) -> dict:
    if user["role"] != "OPS":
        raise HTTPException(403, "Ops role required")
    return user


def require_member(conn, group_id: int, user_id: int) -> dict:
    g = conn.execute("SELECT * FROM groups WHERE id=%s", (group_id,)).fetchone()
    if not g:
        raise HTTPException(404, "Group not found")
    m = conn.execute("SELECT 1 FROM group_members WHERE group_id=%s AND user_id=%s AND left_at IS NULL",
                     (group_id, user_id)).fetchone()
    if not m:
        raise HTTPException(403, "Not a member of this group")
    return g
