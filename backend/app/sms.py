"""OTP delivery. Logs the code in dev; sends through MSG91 or Twilio when configured."""
import logging
import os

import httpx

log = logging.getLogger("sms")
PROVIDER = os.getenv("SMS_PROVIDER", "")          # "msg91" or "twilio"


def send_otp(phone: str, code: str) -> bool:
    if PROVIDER == "msg91":
        r = httpx.post("https://control.msg91.com/api/v5/otp",
                       params={"template_id": os.environ["MSG91_TEMPLATE_ID"], "mobile": phone.lstrip("+"), "otp": code},
                       headers={"authkey": os.environ["MSG91_AUTH_KEY"]}, timeout=6)
        return r.status_code == 200
    if PROVIDER == "twilio":
        sid = os.environ["TWILIO_ACCOUNT_SID"]
        r = httpx.post(f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json",
                       data={"To": phone, "From": os.environ["TWILIO_FROM"],
                             "Body": f"{code} is your Squared code. It expires in 10 minutes."},
                       auth=(sid, os.environ["TWILIO_AUTH_TOKEN"]), timeout=6)
        return r.status_code in (200, 201)
    log.info("OTP for %s issued (no SMS provider configured; dev uses DEV_OTP)", phone[-4:])
    return True
