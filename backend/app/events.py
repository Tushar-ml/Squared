"""Transactional outbox. Call emit() inside the same transaction as the core write."""
import json
import uuid

from . import clock


def emit(conn, event_type: str, **payload) -> str:
    event_id = str(uuid.uuid4())
    payload = {"event_id": event_id, "occurred_at": clock.now().isoformat(), **payload}
    conn.execute("INSERT INTO outbox_events (event_id, event_type, payload, occurred_at) VALUES (%s,%s,%s,%s)",
                 (event_id, event_type, json.dumps(payload, default=str), clock.now()))
    return event_id
