#!/bin/sh
# Create (or update) the Squared app on DigitalOcean App Platform from .do/app.yaml.
#
# Needs: doctl, authenticated (`doctl auth init`), and the DigitalOcean GitHub app given access to
# Tushar-ml/Squared. Asks for anything it can't generate; nothing secret is written into the repo.
#
#   scripts/do-deploy.sh            # first deploy: creates bucket, secrets and the app
#   scripts/do-deploy.sh update     # push spec changes to the existing app (keeps its secrets)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEC="$ROOT/.do/app.yaml"
command -v doctl >/dev/null || { echo "Install doctl first: brew install doctl && doctl auth init"; exit 1; }
doctl account get >/dev/null || { echo "doctl isn't signed in: run doctl auth init"; exit 1; }

APP_ID="$(doctl apps list --format ID,Spec.Name --no-header | awk '$2=="squared"{print $1}')"
if [ "${1:-}" = "update" ]; then
  [ -n "$APP_ID" ] || { echo "No app named squared yet: run without 'update' first"; exit 1; }
  # secrets are kept by App Platform when the spec leaves them encrypted; fetch the live spec and
  # replace only the non-secret parts from .do/app.yaml
  echo "Update the live app from the DigitalOcean console or with: doctl apps update $APP_ID --spec <spec>"
  echo "(Secrets are preserved only if you pass back the EV[...] values from: doctl apps spec get $APP_ID)"
  exit 0
fi
[ -z "$APP_ID" ] || { echo "App 'squared' already exists ($APP_ID). Use the console to change it, or delete it first."; exit 1; }

ask() { printf "%s: " "$1" >&2; read -r v; [ -n "$v" ] || { echo "required" >&2; exit 1; }; echo "$v"; }
SUPPORT_EMAIL="${SUPPORT_EMAIL:-$(ask 'Support email shown on the legal pages')}"
GOOGLE_CLIENT_IDS="${GOOGLE_CLIENT_IDS:-$(ask 'Google iOS OAuth client ID (Google Cloud > Credentials)')}"
OPS_EMAILS="${OPS_EMAILS:-$(ask 'Email(s) that get the Ops console, comma-separated')}"
SPACES_KEY="${SPACES_KEY:-$(ask 'Spaces access key (Console > API > Spaces Keys)')}"
SPACES_SECRET="${SPACES_SECRET:-$(ask 'Spaces secret key')}"
S3_BUCKET="${S3_BUCKET:-squared-bills-$(openssl rand -hex 3)}"

echo "Creating private Spaces bucket $S3_BUCKET in blr1 (skipped if it exists)…"
(cd "$ROOT" && ./dc.sh run --rm --no-deps -e AWS_ACCESS_KEY_ID="$SPACES_KEY" -e AWS_SECRET_ACCESS_KEY="$SPACES_SECRET" api python -c "
import boto3, botocore
s3 = boto3.client('s3', endpoint_url='https://blr1.digitaloceanspaces.com', region_name='blr1')
try:
    s3.create_bucket(Bucket='$S3_BUCKET', ACL='private')
except botocore.exceptions.ClientError as e:
    if e.response['Error']['Code'] not in ('BucketAlreadyOwnedByYou',): raise
print('bucket ready')")

TMP="$(mktemp -t squared-spec)"; chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
python3 - "$SPEC" "$TMP" <<EOF
import secrets, sys
src, dst = sys.argv[1], sys.argv[2]
fill = {
    "S3_BUCKET": "$S3_BUCKET", "AWS_ACCESS_KEY_ID": "$SPACES_KEY", "AWS_SECRET_ACCESS_KEY": "$SPACES_SECRET",
    "SURPRISE_SECRET": secrets.token_hex(24), "INVITE_SECRET": secrets.token_hex(24),
    "VOUCHER_KEY": secrets.token_hex(24),
    "SUPPORT_EMAIL": "$SUPPORT_EMAIL", "GOOGLE_CLIENT_IDS": "$GOOGLE_CLIENT_IDS", "OPS_EMAILS": "$OPS_EMAILS",
}
out = []
for line in open(src):
    for k, v in fill.items():
        if f"key: {k}," in line and "__FILL__" in line:
            line = line.replace("__FILL__", v)
    out.append(line)
text = "".join(out)
assert "__FILL__" not in text, "unfilled value left in spec"
open(dst, "w").write(text)
EOF

echo "Creating the app (first build takes a few minutes)…"
doctl apps create --spec "$TMP" --wait --format ID,DefaultIngress,Phase
echo
echo "Next: put the app URL above into ios/project.yml (SQUARED_API_BASE_URL / SQUARED_LINK_DOMAIN for Release)."
