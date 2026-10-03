import os


class Settings:
    app_env = os.getenv("APP_ENV", "dev")
    database_url = os.getenv("DATABASE_URL", "postgresql://coins:coins@localhost:5433/coins")
    dev_otp = os.getenv("DEV_OTP", "")
    surprise_secret = os.getenv("SURPRISE_SECRET", "")
    invite_secret = os.getenv("INVITE_SECRET", "")
    voucher_key = os.getenv("VOUCHER_KEY", "")
    vendor_url = os.getenv("VENDOR_URL", "http://localhost:8090")
    vendor_timeout = float(os.getenv("VENDOR_TIMEOUT_SECONDS", "3"))
    smtp_host = os.getenv("SMTP_HOST", "")
    smtp_port = int(os.getenv("SMTP_PORT", "1025"))
    public_base_url = os.getenv("PUBLIC_BASE_URL", "http://localhost:8080")
    worker_poll_seconds = float(os.getenv("WORKER_POLL_SECONDS", "0.5"))

    @property
    def is_dev(self) -> bool:
        return self.app_env in ("dev", "test")


settings = Settings()
