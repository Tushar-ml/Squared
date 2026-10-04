"""Where bill photos live. Local disk for development; S3-compatible object storage in production
(AWS S3, Cloudflare R2, MinIO), because most hosts wipe the local disk on every deploy.

Objects stay private: the API checks group membership and streams the bytes, so the app keeps
sending only its own session token and never needs a storage URL.
"""
import pathlib

from .settings import settings

LOCAL_ROOT = pathlib.Path(__file__).resolve().parent.parent / "uploads"


class LocalStorage:
    def __init__(self, root: pathlib.Path = LOCAL_ROOT):
        self.root = root

    def put(self, key: str, data: bytes, content_type: str) -> None:
        path = self.root / key
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def get(self, key: str) -> bytes | None:
        path = self.root / key
        return path.read_bytes() if path.exists() else None

    def delete(self, key: str) -> None:
        (self.root / key).unlink(missing_ok=True)


class S3Storage:
    def __init__(self, bucket: str, endpoint_url: str | None = None, region: str | None = None, client=None):
        import boto3
        self.bucket = bucket
        self.s3 = client or boto3.client("s3", endpoint_url=endpoint_url or None, region_name=region or None)

    def put(self, key: str, data: bytes, content_type: str) -> None:
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=content_type)

    def get(self, key: str) -> bytes | None:
        try:
            return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()
        except self.s3.exceptions.NoSuchKey:
            return None

    def delete(self, key: str) -> None:
        self.s3.delete_object(Bucket=self.bucket, Key=key)


_backend = None


def backend():
    global _backend
    if _backend is None:
        if settings.storage_backend == "s3":
            _backend = S3Storage(settings.s3_bucket, settings.s3_endpoint_url, settings.s3_region)
        else:
            _backend = LocalStorage()
    return _backend


def use(b) -> None:
    """Swap the backend (tests)."""
    global _backend
    _backend = b
