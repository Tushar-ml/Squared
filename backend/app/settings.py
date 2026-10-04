import os


class Settings:
    app_env = os.getenv("APP_ENV", "dev")
    database_url = os.getenv("DATABASE_URL", "postgresql://coins:coins@localhost:5433/coins")
    surprise_secret = os.getenv("SURPRISE_SECRET", "")
    invite_secret = os.getenv("INVITE_SECRET", "")
    voucher_key = os.getenv("VOUCHER_KEY", "")
    trust_proxy = os.getenv("TRUST_PROXY", "0") == "1"       # read the client IP from X-Forwarded-For (behind a load balancer)
    # sign-in
    google_client_ids = os.getenv("GOOGLE_CLIENT_IDS", "")   # comma-separated OAuth client IDs of the iOS app
    google_web_client_id = os.getenv("GOOGLE_WEB_CLIENT_ID", "")   # optional: Google button on the ops console
    ios_bundle_id = os.getenv("IOS_BUNDLE_ID", "app.squared.ios")   # also the Sign in with Apple audience
    apple_team_id = os.getenv("APPLE_TEAM_ID", "")           # Universal Links, Sign in with Apple revocation
    apple_signin_key_id = os.getenv("APPLE_SIGNIN_KEY_ID", "")
    apple_signin_private_key = os.getenv("APPLE_SIGNIN_PRIVATE_KEY", "")   # contents of the AuthKey_XXXX.p8
    ops_emails = os.getenv("OPS_EMAILS", "")                 # comma-separated; these accounts get the Ops role
    # storage
    storage_backend = os.getenv("STORAGE_BACKEND", "local")   # "local" or "s3" (S3, Cloudflare R2, DO Spaces)
    s3_bucket = os.getenv("S3_BUCKET", "")
    s3_endpoint_url = os.getenv("S3_ENDPOINT_URL", "")         # e.g. https://blr1.digitaloceanspaces.com
    s3_region = os.getenv("S3_REGION", "")
    # public pages
    support_email = os.getenv("SUPPORT_EMAIL", "")           # shown on the legal and support pages
    operator_name = os.getenv("OPERATOR_NAME", "Squared")
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
        for name in ("SURPRISE_SECRET", "INVITE_SECRET", "VOUCHER_KEY"):
            v = getattr(self, name.lower())
            if not v or v == "change-me" or len(v) < 24:
                out.append(f"{name} must be a random value of at least 24 characters")
        if not self.public_base_url.startswith("https://"):
            out.append("PUBLIC_BASE_URL must use https")
        if self.storage_backend != "s3" or not self.s3_bucket:
            out.append("STORAGE_BACKEND=s3 and S3_BUCKET are required: local disk doesn't survive deploys")
        if not self.support_email:
            out.append("SUPPORT_EMAIL is required: the privacy policy must give a contact for data requests")
        if not self.google_client_ids.strip():
            out.append("GOOGLE_CLIENT_IDS is required: without it nobody can sign in with Google")
        return out

    def production_warnings(self) -> list[str]:
        """Not unsafe, but something to finish before the App Store launch."""
        if self.is_dev:
            return []
        out = []
        if not self.apple_team_id:
            out.append("APPLE_TEAM_ID is not set: invite links open the web page instead of the app")
        if not (self.apple_signin_key_id and self.apple_signin_private_key):
            out.append("APPLE_SIGNIN_KEY_ID / APPLE_SIGNIN_PRIVATE_KEY are not set: deleting an account can't revoke "
                       "Sign in with Apple, which App Review requires")
        return out

    def assert_safe_for_production(self) -> None:
        import logging
        for w in self.production_warnings():
            logging.getLogger("settings").warning(w)
        problems = self.production_problems()
        if problems:
            raise RuntimeError("Refusing to start with APP_ENV=%s:\n- %s" % (self.app_env, "\n- ".join(problems)))


settings = Settings()
