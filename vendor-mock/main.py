"""Mock voucher vendor (sandbox). Switch behaviour with POST /admin/mode {"mode": "ok|fail|timeout"}."""
import asyncio
import secrets

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Voucher vendor sandbox")
state = {"mode": "ok", "issued": {}}


class IssueReq(BaseModel):
    sku: str
    reference: str  # our redemption id; vendor dedupes on it


class ModeReq(BaseModel):
    mode: str


@app.post("/v1/vouchers")
async def issue(req: IssueReq):
    if state["mode"] == "timeout":
        await asyncio.sleep(30)
    if state["mode"] == "fail" or req.sku.endswith("-DISABLED"):
        raise HTTPException(502, "vendor unavailable")
    if req.reference in state["issued"]:  # duplicate call returns the same voucher
        return state["issued"][req.reference]
    out = {"vendor_ref": "VND-" + secrets.token_hex(4).upper(),
           "code": "-".join(secrets.token_hex(2).upper() for _ in range(3))}
    state["issued"][req.reference] = out
    return out


@app.post("/admin/mode")
def set_mode(req: ModeReq):
    if req.mode not in ("ok", "fail", "timeout"):
        raise HTTPException(400, "mode must be ok, fail or timeout")
    state["mode"] = req.mode
    return {"mode": state["mode"]}


@app.get("/health")
def health():
    return {"ok": True, "mode": state["mode"]}
