"""New-user activation checklist (/me/activation)."""
from app import db


def steps(w, name):
    st = w.req(name, "GET", "/me/activation")
    return st, {s["id"]: s["done"] for s in st["steps"]}


def test_creator_path_walks_the_checklist(w):
    w.user("Rahul"); w.user("Priya")
    st, s = steps(w, "Rahul")
    assert st["next_step"] == "flat" and not any(s.values()) and st["group"] is None
    g = w.flat("Rahul")
    st, s = steps(w, "Rahul")
    assert s["flat"] and st["next_step"] == "roommates" and st["coins_enabled"] is False  # solo: no coins yet
    inv = w.req("Rahul", "POST", "/invites", {"group_id": g})
    w.req("Priya", "POST", "/invites/accept", {"token": inv["token"]})
    st, s = steps(w, "Rahul")
    assert s["roommates"] and st["group"]["invites_sent"] == 1 and st["coins_enabled"]
    e = w.expense("Rahul", g, 600)
    st, s = steps(w, "Rahul")
    assert s["expense"] and st["next_step"] == "confirm" and not st["activated"]
    assert st["waiting_expense_id"] == e and st["waiting_on"] == ["Priya"]
    # invitee sees the expense waiting on them: the fastest first win
    pst, _ = steps(w, "Priya")
    assert pst["confirm_expense_id"] == e and pst["first_win_coins"] == 50
    w.confirm("Priya", e)
    for n in ("Rahul", "Priya"):
        st, s = steps(w, n)
        assert st["activated"] and st["next_step"] is None
    with db.tx() as c:
        n = c.execute("SELECT count(*) c FROM analytics_events WHERE name='user_activated'").fetchone()["c"]
    assert n == 2
    steps(w, "Rahul")
    with db.tx() as c:  # logged once per user
        assert c.execute("SELECT count(*) c FROM analytics_events WHERE name='user_activated'").fetchone()["c"] == 2


def test_self_confirmation_does_not_activate(w):
    w.user("Rahul"); w.user("Priya")
    g = w.flat("Rahul", "Priya")
    w.expense("Rahul", g, 600)
    st, _ = steps(w, "Rahul")
    assert not st["activated"]


def test_starting_a_new_group_does_not_undo_activation(w):
    w.user("Aman"); w.user("Priya")
    g = w.flat("Aman", "Priya")
    e = w.expense("Aman", g, 300)
    w.confirm("Priya", e)
    assert w.req("Aman", "GET", "/me/activation")["activated"]
    w.req("Aman", "POST", "/groups", {"name": "Goa", "group_type": "TRIP"})   # newer, empty
    assert w.req("Aman", "GET", "/me/activation")["activated"]
