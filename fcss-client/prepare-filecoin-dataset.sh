#!/usr/bin/env bash
# Prepares a dataset into Filecoin-ready CAR files using Singularity, uploads
# the pieces and manifest to storage YOU own and control (S3, Cloudflare R2,
# GCS, or any S3-compatible bucket), verifies every piece is actually
# downloadable from there, and prints a MANIFEST_URL in the exact format the
# PoRep Market tooling expects (see
# https://github.com/fidlabs/filecoin-porep-market-tooling — the manifest
# must be the raw, unmodified `pieces` array Singularity returns).
#
# Why your own bucket, not a tunnel from this machine: SP-side tooling
# downloads pieces at {manifest_host}:{port}/piece/{pieceCid} — it derives
# this itself from the manifest URL's hostname, at whatever time the deal is
# actually onboarded, which can be days after you prepared the data. A
# tunnel only stays up while this machine does; a bucket doesn't care if
# your laptop is closed. Once the upload below finishes, this machine can go
# offline and the manifest keeps working.
#
# Plain bash + docker + curl + jq + rclone (dockerized, no local install
# needed) — runnable by any agent or human that can execute shell commands.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./prepare-filecoin-dataset.sh <dataset_name> <source_dir> <output_dir> --storage-provider <s3|r2|gcs|other-s3> [options...]

Positional arguments:
  dataset_name   Name for this dataset. Alphanumeric + hyphens, no spaces.
  source_dir     Path to the raw data to prepare. Must exist.
  output_dir     Path to write CAR files locally before upload. Created if missing.

Storage options (client-owned — you always control your own bucket/credentials):
  --storage-provider <s3|r2|gcs|other-s3>   Required.
  --bucket <name>                            Required for all providers.
  --public-base-url <url>                    Required. The URL prefix these
                                              objects will be publicly reachable
                                              at once uploaded, e.g.
                                              https://pub-xxxx.r2.dev or
                                              https://mybucket.s3.amazonaws.com
                                              or a custom domain fronting the bucket.

  s3 / r2 / other-s3 additionally need:
    --access-key-id <id>
    --secret-access-key <secret>
    --region <region>          s3 default: us-east-1. r2: always "auto" (set automatically).
                                other-s3: required.
    --endpoint <url>           r2 / other-s3: required (e.g. R2's
                                https://<account_id>.r2.cloudflarestorage.com).
                                s3: not used.

  gcs additionally needs:
    --gcs-service-account-json <path>   Path to a GCP service account JSON key
                                         with write access to the bucket.

Other optional flags:
  --db-port <port>    Default 5432 (auto-bumped to 5433 if taken).
  --api-port <port>   Default 9090.

Requires: docker, docker compose (v2), curl, jq. rclone runs via its
official Docker image — no local rclone install needed.

On success prints:
  MANIFEST_URL=<url>
Use that URL with propose-filecoin-deal.sh. Storage providers must pass
--port 443 to `sp onboard-data`: public buckets serve HTTPS on 443, and
onboard-data always appends a port (default 7777, Singularity's usual port),
even when --host is given.

A published manifest is never overwritten with different content: deals
commit to the exact manifest bytes. To prepare changed data, use a new
dataset_name.
USAGE
  exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

[ $# -ge 3 ] || usage

DATASET_NAME="$1"; shift
SOURCE_DIR="$1"; shift
OUTPUT_DIR="$1"; shift

DB_PORT=5432
API_PORT=9090
STORAGE_PROVIDER=""
BUCKET=""
PUBLIC_BASE_URL=""
ACCESS_KEY_ID=""
SECRET_ACCESS_KEY=""
REGION=""
ENDPOINT=""
GCS_SERVICE_ACCOUNT_JSON=""

while [ $# -gt 0 ]; do
  case "$1" in
    --storage-provider) STORAGE_PROVIDER="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --public-base-url) PUBLIC_BASE_URL="${2%/}"; shift 2 ;;
    --access-key-id) ACCESS_KEY_ID="$2"; shift 2 ;;
    --secret-access-key) SECRET_ACCESS_KEY="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --endpoint) ENDPOINT="${2%/}"; shift 2 ;;
    --gcs-service-account-json) GCS_SERVICE_ACCOUNT_JSON="$2"; shift 2 ;;
    --db-port) DB_PORT="$2"; shift 2 ;;
    --api-port) API_PORT="$2"; shift 2 ;;
    *) die "unknown argument: $1 (see --help / run with no arguments for usage)" ;;
  esac
done

[ -n "$STORAGE_PROVIDER" ] || usage
[ -n "$BUCKET" ] || die "--bucket is required"
[ -n "$PUBLIC_BASE_URL" ] || die "--public-base-url is required"

case "$STORAGE_PROVIDER" in
  s3)
    [ -n "$ACCESS_KEY_ID" ] || die "--access-key-id is required for s3"
    [ -n "$SECRET_ACCESS_KEY" ] || die "--secret-access-key is required for s3"
    REGION="${REGION:-us-east-1}"
    ;;
  r2)
    [ -n "$ACCESS_KEY_ID" ] || die "--access-key-id is required for r2"
    [ -n "$SECRET_ACCESS_KEY" ] || die "--secret-access-key is required for r2"
    [ -n "$ENDPOINT" ] || die "--endpoint is required for r2 (https://<account_id>.r2.cloudflarestorage.com)"
    REGION="auto"
    ;;
  other-s3)
    [ -n "$ACCESS_KEY_ID" ] || die "--access-key-id is required for other-s3"
    [ -n "$SECRET_ACCESS_KEY" ] || die "--secret-access-key is required for other-s3"
    [ -n "$ENDPOINT" ] || die "--endpoint is required for other-s3"
    [ -n "$REGION" ] || die "--region is required for other-s3"
    ;;
  gcs)
    [ -n "$GCS_SERVICE_ACCOUNT_JSON" ] || die "--gcs-service-account-json is required for gcs"
    [ -f "$GCS_SERVICE_ACCOUNT_JSON" ] || die "gcs service account file not found: $GCS_SERVICE_ACCOUNT_JSON"
    ;;
  *) die "--storage-provider must be one of: s3, r2, gcs, other-s3 (got: $STORAGE_PROVIDER)" ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

command -v docker >/dev/null 2>&1 || die "docker not found in PATH"
docker compose version >/dev/null 2>&1 || die "docker compose (v2) not found"
command -v curl >/dev/null 2>&1 || die "curl not found in PATH"
command -v jq >/dev/null 2>&1 || die "jq not found in PATH (brew install jq / apt install jq)"

docker info >/dev/null 2>&1 || die "Docker daemon is not running. Start Docker Desktop (or dockerd), then re-run."

[ -d "$SOURCE_DIR" ] || die "source directory does not exist: $SOURCE_DIR"

mkdir -p "$OUTPUT_DIR"

SOURCE_SIZE_KB=$(du -sk "$SOURCE_DIR" | cut -f1)
AVAIL_KB=$(df -k "$OUTPUT_DIR" | tail -1 | awk '{print $4}')
if [ "$AVAIL_KB" -lt "$SOURCE_SIZE_KB" ]; then
  die "not enough free space at $OUTPUT_DIR (need ~${SOURCE_SIZE_KB}KB, have ${AVAIL_KB}KB)"
fi

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -i ":$1" >/dev/null 2>&1
  else
    return 1  # cannot check without lsof; docker compose up will fail loudly later if the port is taken
  fi
}

# Only enforce free-port checks on a fresh start. If this directory's own compose
# project already has containers up (a prior run of this script), the ports are
# almost certainly already owned by those containers — `docker compose up -d` will
# just reuse them. Checking globally here would false-positive on our own stack.
EXISTING_CONTAINERS=$(docker compose ps -q 2>/dev/null || true)
if [ -z "$EXISTING_CONTAINERS" ]; then
  if port_in_use "$DB_PORT"; then
    echo "Port $DB_PORT is in use, switching db_port to 5433"
    DB_PORT=5433
    port_in_use "$DB_PORT" && die "fallback port 5433 is also in use; pass a free --db-port explicitly"
  fi
  port_in_use "$API_PORT" && die "port $API_PORT is in use; pass a free --api-port explicitly"
else
  echo "Existing stack detected in this directory — reusing running containers where possible."
fi

echo "Dataset:  $DATASET_NAME"
echo "Source:   $SOURCE_DIR"
echo "Output:   $OUTPUT_DIR"
echo "Storage:  $STORAGE_PROVIDER -> bucket=$BUCKET"
echo "Ports:    db=$DB_PORT api=$API_PORT"
echo

# ---------------------------------------------------------------------------
# Step 1 — compose file (Singularity + Postgres only — no tunnel, no gateway;
# uploading to your own bucket in Step 5 removes the need for either)
# ---------------------------------------------------------------------------

cat > docker-compose.yml <<EOF
services:
  singularity-db:
    image: postgres:16
    environment:
      POSTGRES_DB: singularity
      POSTGRES_USER: singularity
      POSTGRES_PASSWORD: singularity
    ports:
      - "${DB_PORT}:5432"
    volumes:
      - singularity_db:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U singularity"]
      interval: 5s
      timeout: 5s
      retries: 10
  singularity-api:
    image: ghcr.io/data-preservation-programs/singularity:main
    command: run api --bind :9090
    environment:
      DATABASE_CONNECTION_STRING: postgres://singularity:singularity@singularity-db:5432/singularity
    ports:
      - "${API_PORT}:9090"
    volumes:
      - ${SOURCE_DIR}:/source:ro
      - ${OUTPUT_DIR}:/output
    depends_on:
      singularity-db:
        condition: service_healthy
volumes:
  singularity_db:
EOF

# ---------------------------------------------------------------------------
# Step 2 — start stack
# ---------------------------------------------------------------------------

echo "==> Starting stack"
docker compose up -d

BASE="http://localhost:${API_PORT}/api"

echo "==> Waiting for API"
api_ready=false
for _ in $(seq 1 30); do
  if curl -sf "$BASE/preparation" >/dev/null 2>&1; then
    api_ready=true
    break
  fi
  sleep 2
done
if [ "$api_ready" != true ]; then
  docker compose logs
  die "API did not become ready after 60s"
fi
echo "API ready."

DB_CONN="postgres://singularity:singularity@singularity-db:5432/singularity"

# ---------------------------------------------------------------------------
# Step 3a — init db
# ---------------------------------------------------------------------------

echo "==> Initializing database"
docker compose exec -T singularity-api /app/singularity \
  --database-connection-string "$DB_CONN" admin init >/dev/null

# ---------------------------------------------------------------------------
# Helpers: idempotent create-or-verify for storages and preparations.
# ---------------------------------------------------------------------------

# There is no GET /storage/{name} single-item lookup (that route 405s) — only
# GET /storage (list all). And error bodies/status codes for "already exists"
# are inconsistent across endpoints (storage: 409; preparation: 500 with a
# different message), so pattern-matching error text is fragile. Instead,
# check actual current state first and only create/fix what's needed.

ensure_storage() {
  local name="$1" want_path="$2" actual_path http_code resp_file
  actual_path=$(curl -sf "$BASE/storage" | jq -r --arg n "$name" '.[] | select(.name==$n) | .path')

  if [ "$actual_path" = "$want_path" ]; then
    echo "  storage $name already correct ($want_path)"
    return 0
  fi

  if [ -n "$actual_path" ]; then
    echo "  storage $name has stale path '$actual_path', attempting to fix to '$want_path'"
    resp_file=$(mktemp)
    http_code=$(curl -s -o "$resp_file" -w '%{http_code}' -X DELETE "$BASE/storage/${name}")
    if [ "$http_code" != "200" ] && [ "$http_code" != "204" ]; then
      cat "$resp_file" >&2
      rm -f "$resp_file"
      echo "storage '$name' points at '$actual_path' but should point at '$want_path', and cannot be deleted because it is still attached to an existing preparation." >&2
      echo "This usually means dataset '$DATASET_NAME' was already prepared with different source/output directories." >&2
      echo "Either re-run with the original directories, or pick a different dataset_name." >&2
      return 1
    fi
    rm -f "$resp_file"
  fi

  resp_file=$(mktemp)
  http_code=$(curl -s -o "$resp_file" -w '%{http_code}' -X POST "${BASE}/storage/local" \
    -H "Content-Type: application/json" -d "{\"name\":\"${name}\",\"path\":\"${want_path}\"}")
  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    echo "failed to create storage $name (HTTP $http_code):" >&2
    cat "$resp_file" >&2
    rm -f "$resp_file"
    return 1
  fi
  rm -f "$resp_file"
}

ensure_preparation() {
  local name="$1" source_storage="$2" output_storage="$3" http_code resp_file
  http_code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/preparation/${name}")
  if [ "$http_code" = "200" ]; then
    echo "  preparation $name already exists"
    return 0
  fi

  resp_file=$(mktemp)
  http_code=$(curl -s -o "$resp_file" -w '%{http_code}' -X POST "${BASE}/preparation" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"${name}\",\"sourceStorages\":[\"${source_storage}\"],\"outputStorages\":[\"${output_storage}\"]}")
  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    echo "failed to create preparation $name (HTTP $http_code):" >&2
    cat "$resp_file" >&2
    rm -f "$resp_file"
    return 1
  fi
  rm -f "$resp_file"
}

# ---------------------------------------------------------------------------
# Step 3b — storages
# ---------------------------------------------------------------------------

SOURCE_STORAGE="source-${DATASET_NAME}"
OUTPUT_STORAGE="output-${DATASET_NAME}"

echo "==> Ensuring source storage: $SOURCE_STORAGE -> /source"
ensure_storage "$SOURCE_STORAGE" "/source" || die "failed to set up source storage"

echo "==> Ensuring output storage: $OUTPUT_STORAGE -> /output"
ensure_storage "$OUTPUT_STORAGE" "/output" || die "failed to set up output storage"

# ---------------------------------------------------------------------------
# Step 3c — preparation
# ---------------------------------------------------------------------------

echo "==> Ensuring preparation: $DATASET_NAME"
ensure_preparation "$DATASET_NAME" "$SOURCE_STORAGE" "$OUTPUT_STORAGE" || die "failed to set up preparation"

# ---------------------------------------------------------------------------
# Step 3d — scan + pack (background, polled — can take hours at 100GB+)
# ---------------------------------------------------------------------------

echo "==> Starting scan"
curl -sf -X POST "$BASE/preparation/${DATASET_NAME}/source/${SOURCE_STORAGE}/start-scan" >/dev/null

echo "==> Running scan/pack worker in background"
docker compose exec -d singularity-api /app/singularity \
  --database-connection-string "$DB_CONN" \
  run dataset-worker --exit-on-complete --exit-on-error

while docker compose top singularity-api 2>/dev/null | grep -q dataset-worker; do
  sleep 30
  count=$(curl -sf "$BASE/preparation/${DATASET_NAME}/piece" | jq '[.[].pieces[]] | length')
  echo "  still packing... ($count pieces so far)"
done
echo "Scan/pack phase finished."

# ---------------------------------------------------------------------------
# Step 3e — daggen (background, polled)
# ---------------------------------------------------------------------------

echo "==> Starting DAG generation"
curl -sf -X POST "$BASE/preparation/${DATASET_NAME}/source/${SOURCE_STORAGE}/start-daggen" >/dev/null

docker compose exec -d singularity-api /app/singularity \
  --database-connection-string "$DB_CONN" \
  run dataset-worker --exit-on-complete --exit-on-error

while docker compose top singularity-api 2>/dev/null | grep -q dataset-worker; do
  sleep 30
  echo "  still generating DAGs..."
done
echo "DAG phase finished."

# ---------------------------------------------------------------------------
# Step 4 — fetch pieces and validate against the exact PoRep Market schema
# ---------------------------------------------------------------------------
#
# Schema enforced by filecoin-porep-market-tooling's _validate_manifest():
#   - top level is a JSON array of length exactly 1
#   - manifest[0] is an object containing a "pieces" array
#   - every piece has: pieceCid, pieceType, pieceSize, fileSize,
#     preparationId, attachmentId, storagePath
#   - exactly one piece has pieceType "dag"; the rest are "data"
#   - all pieces share the same preparationId and attachmentId
#   - the dag piece's pieceSize is >= 1 MiB
# This is exactly what GET /preparation/{name}/piece already returns — the
# manifest we publish must be that response, unmodified. Do not flatten it,
# strip fields, or add fields; downstream tooling validates the shape exactly.

echo "==> Fetching and validating pieces"
RESULT=$(curl -sf "$BASE/preparation/${DATASET_NAME}/piece")

MINIMUM_DAG_PIECE_SIZE_BYTES=1048576
VALIDATION=$(echo "$RESULT" | jq -r --argjson min_dag "$MINIMUM_DAG_PIECE_SIZE_BYTES" '
  if (type != "array") or (length != 1) then "top level must be an array of length 1"
  elif (.[0] | type != "object") or (.[0] | has("pieces") | not) then "manifest[0] must be an object with a pieces key"
  elif (.[0].pieces | type != "array") or (.[0].pieces | length == 0) then "pieces must be a non-empty array"
  elif ([.[0].pieces[] | select((has("pieceCid") and has("pieceType") and has("pieceSize") and has("fileSize") and has("preparationId") and has("attachmentId") and has("storagePath")) | not)] | length > 0) then "every piece must have pieceCid, pieceType, pieceSize, fileSize, preparationId, attachmentId, storagePath"
  elif ([.[0].pieces[] | select(.pieceType == "dag")] | length != 1) then "must contain exactly one dag piece"
  elif ([.[0].pieces[] | select(.pieceType == "data")] | length) != ((.[0].pieces | length) - 1) then "all non-dag pieces must have pieceType data"
  elif ([.[0].pieces[] | .preparationId] | unique | length != 1) then "all pieces must share the same preparationId"
  elif ([.[0].pieces[] | .attachmentId] | unique | length != 1) then "all pieces must share the same attachmentId"
  elif ([.[0].pieces[] | select(.pieceType == "dag")][0].pieceSize < $min_dag) then "dag piece must be at least 1 MiB"
  else "ok"
  end
')

[ "$VALIDATION" = "ok" ] || { docker compose logs singularity-api; die "manifest failed PoRep Market schema validation: $VALIDATION"; }

DATA_PIECE_COUNT=$(echo "$RESULT" | jq '[.[0].pieces[] | select(.pieceType=="data")] | length')
echo "Valid manifest: $DATA_PIECE_COUNT data piece(s) + 1 dag piece."

# ---------------------------------------------------------------------------
# Step 5 — upload pieces + manifest to your storage, verify, publish
# ---------------------------------------------------------------------------
#
# Downstream SP tooling does not read any URL field from the manifest — it
# always constructs {manifest_host}:{port}/piece/{pieceCid} itself. So every
# piece must be uploaded to a key of exactly "piece/<pieceCid>" (no file
# extension) at the BUCKET ROOT — not nested under any per-dataset prefix —
# regardless of where the manifest.json itself lives, since the SP tool
# discards the manifest URL's path when building the download host. pieceCids
# are content-addressed, so multiple datasets safely sharing one bucket's
# piece/ prefix is not a collision risk.

case "$STORAGE_PROVIDER" in
  # Note: endpoint values contain "://" and a port (colons), which rclone's
  # on-the-fly connection-string syntax requires to be double-quoted, or it
  # mis-parses at the first colon (confirmed by testing against real MinIO).
  s3)      RCLONE_REMOTE=":s3,provider=AWS,access_key_id=${ACCESS_KEY_ID},secret_access_key=${SECRET_ACCESS_KEY},region=${REGION}:${BUCKET}" ;;
  r2)      RCLONE_REMOTE=":s3,provider=Cloudflare,access_key_id=${ACCESS_KEY_ID},secret_access_key=${SECRET_ACCESS_KEY},endpoint=\"${ENDPOINT}\",region=auto:${BUCKET}" ;;
  other-s3) RCLONE_REMOTE=":s3,provider=Other,access_key_id=${ACCESS_KEY_ID},secret_access_key=${SECRET_ACCESS_KEY},endpoint=\"${ENDPOINT}\",region=${REGION}:${BUCKET}" ;;
  gcs)     RCLONE_REMOTE=":gs,service_account_file=/creds/sa.json:${BUCKET}" ;;
esac

rclone_upload() {
  local local_file="$1" remote_key="$2"
  local gcs_mount=()
  [ "$STORAGE_PROVIDER" = "gcs" ] && gcs_mount=(-v "$(cd "$(dirname "$GCS_SERVICE_ACCOUNT_JSON")" && pwd)/$(basename "$GCS_SERVICE_ACCOUNT_JSON"):/creds/sa.json:ro")

  docker run --rm \
    -v "$(cd "$(dirname "$local_file")" && pwd)/$(basename "$local_file"):/upload/$(basename "$local_file"):ro" \
    "${gcs_mount[@]}" \
    rclone/rclone:latest \
    copyto "/upload/$(basename "$local_file")" "${RCLONE_REMOTE}/${remote_key}" >/dev/null
}

echo "==> Uploading pieces to $STORAGE_PROVIDER bucket $BUCKET"
while read -r piece; do
  piece_cid=$(echo "$piece" | jq -r '.pieceCid')
  storage_path=$(echo "$piece" | jq -r '.storagePath')
  local_path="${OUTPUT_DIR}/${storage_path}"

  [ -f "$local_path" ] || die "expected piece file not found on disk: $local_path"

  echo "  uploading $storage_path -> piece/${piece_cid}"
  rclone_upload "$local_path" "piece/${piece_cid}"
done < <(echo "$RESULT" | jq -c '.[0].pieces[]')

echo "==> Verifying each piece is downloadable via $PUBLIC_BASE_URL"

# Public buckets on S3/R2/GCS serve Content-Range correctly (unlike the
# quick-tunnel path this replaced), but a 1-byte range request is still used
# here: it's the cheapest possible way to confirm both reachability and the
# real total size without downloading the full piece (which could be many GB).

while read -r piece; do
  piece_cid=$(echo "$piece" | jq -r '.pieceCid')
  expected_size=$(echo "$piece" | jq -r '.fileSize')
  url="${PUBLIC_BASE_URL}/piece/${piece_cid}"

  head=$(curl -sI -r 0-0 "$url" || true)
  status_line=$(echo "$head" | head -1)
  content_range=$(echo "$head" | grep -i '^content-range:' | awk -F/ '{print $2}' | tr -d '\r' || true)

  echo "$status_line" | grep -q " 206\| 200" \
    || die "download check failed for $piece_cid: HTTP status was '$status_line' (url: $url)"
  [ -n "$content_range" ] \
    || die "download check failed for $piece_cid: no content-range in response, cannot verify size (url: $url)"
  [ "$content_range" = "$expected_size" ] \
    || die "download check failed for $piece_cid: reported total size $content_range != expected $expected_size (url: $url)"

  echo "  OK: $piece_cid ($content_range bytes)"
done < <(echo "$RESULT" | jq -c '.[0].pieces[]')

echo "All pieces verified downloadable."

# Write the manifest EXACTLY as returned — no modification — so it validates
# against the PoRep Market schema unchanged.
MANIFEST_FILE=$(mktemp)
echo "$RESULT" | jq '.' > "$MANIFEST_FILE"

MANIFEST_URL="${PUBLIC_BASE_URL}/${DATASET_NAME}/manifest.json"

# A deal commits on-chain to a hash of the exact manifest bytes at its URL,
# and the client cannot repoint it (only the market admin can, and only
# before the SP submits evidence). Overwriting a published manifest with
# different bytes would leave any deal already proposed against it pointing
# at data that no longer matches. Re-uploading identical bytes is harmless.
PUBLISHED_FILE=$(mktemp)
published_code=$(curl -s -o "$PUBLISHED_FILE" -w '%{http_code}' --max-time 30 "$MANIFEST_URL" || true)
if [ "$published_code" = "200" ]; then
  if cmp -s "$MANIFEST_FILE" "$PUBLISHED_FILE"; then
    echo "==> Manifest already published with identical content; leaving it as is"
  else
    rm -f "$MANIFEST_FILE" "$PUBLISHED_FILE"
    die "a different manifest is already published at $MANIFEST_URL. Deals may already reference it, so it will not be overwritten. Prepare the changed data under a new dataset_name."
  fi
else
  echo "==> Uploading manifest"
  rclone_upload "$MANIFEST_FILE" "${DATASET_NAME}/manifest.json"
fi
rm -f "$MANIFEST_FILE" "$PUBLISHED_FILE"

# The PoRep Market tooling fetches the manifest without following redirects.
manifest_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$MANIFEST_URL" || true)
[ "$manifest_code" = "200" ] \
  || die "manifest must answer HTTP 200 directly at $MANIFEST_URL, without redirects (got: ${manifest_code:-no response}). Check --public-base-url."

echo
echo "MANIFEST_URL=${MANIFEST_URL}"
echo
echo "IMPORTANT: storage providers must pass --port 443 to \`sp onboard-data\`."
echo "Public buckets serve HTTPS on 443, and onboard-data always appends a"
echo "port (default 7777), even when --host is given."
echo
echo "This data now lives in your own bucket, not on this machine. You can"
echo "close this laptop, shut down Docker, whatever you like — the manifest"
echo "and pieces stay reachable independent of this machine being online."
