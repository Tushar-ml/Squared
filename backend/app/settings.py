import os


class Settings:
    app_env = os.getenv("APP_ENV", "dev")
    database_url = os.getenv("DATABASE_URL", "postgresql://coins:coins@localhost:5433/coins")
    dev_otp = os.getenv("DEV_OTP", "")
    surprise_secret = os.getenv("SURPRISE_SECRET", "")
    invite_secret = os.getenv("INVITE_SECRET", "")
    voucher_key = os.getenv("VOUCHER_KEY", "")
    otp_secret = os.getenv("OTP_SECRET", "")
    trust_proxy = os.getenv("TRUST_PROXY", "0") == "1"   # read the client IP from X-Forwarded-For (behind a load balancer)
    vendor_url = os.getenv("VENDOR_URL", "http://localhost:8090")
    vendor_timeout = float(os.getenv("VENDOR_TIMEOUT_SECONDS", "3"))
    smtp_host = os.getenv("SMTP_HOST", "")
    smtp_port = int(os.getenv("SMTP_PORT", "1025"))
    public_base_url = os.getenv("PUBLIC_BASE_URL", "http://localhost:8080")
    worker_poll_seconds = float(os.getenv("WORKER_POLL_SECONDS", "0.5"))

    @property
    def is_dev(self) -> bool:
        return self.app_env in ("dev", "test")

    def production_problems(self) -> list[str]:
        """Settings that are fine on a laptop but unsafe with real users."""
        if self.is_dev:
            return []
        out = []
        if self.dev_otp:
            out.append("DEV_OTP must be empty: it lets anyone sign in as any phone number")
        for name in ("SURPRISE_SECRET", "INVITE_SECRET", "VOUCHER_KEY", "OTP_SECRET"):
            v = getattr(self, name.lower())
            if not v or v == "change-me" or len(v) < 24:
                out.append(f"{name} must be a random value of at least 24 characters")
        if not self.public_base_url.startswith("https://"):
            out.append("PUBLIC_BASE_URL must use https")
        return out

    def assert_safe_for_production(self) -> None:
        problems = self.production_problems()
        if problems:
            raise RuntimeError("Refusing to start with APP_ENV=%s:\n- %s" % (self.app_env, "\n- ".join(problems)))


settings = Settings()
