# Storage Backend Setup

`prepare-filecoin-dataset.sh` uploads to a bucket the client already owns
and controls — this skill never provisions storage on their behalf. Whoever
runs the client through this needs to walk them through one of these
one-time setups first (or confirm they've already done it).

**Whichever backend, the end state needed is the same three things:**
1. A bucket.
2. Credentials with write access to it (or a service account key, for GCS).
3. The bucket (or at least its `piece/` and `<dataset_name>/` prefixes)
   publicly readable, at a known public URL prefix. That URL must answer
   directly, with no redirect (the PoRep Market tooling doesn't follow
   redirects), and resolve to a public IP address.

`prepare-filecoin-dataset.sh` verifies #3 itself at the end of a run — if
it isn't public yet, the run fails with the exact URL that didn't resolve,
rather than silently producing a manifest nobody can use.

## Cloudflare R2 (`--storage-provider r2`)

Recommended default if the client doesn't already have one of the others —
no egress fees matter a lot here, since storage providers will pull
potentially many gigabytes per piece.

1. Cloudflare dashboard → R2 → Create bucket. Note the bucket name.
2. **Public access:** R2 buckets are private by default. Two options:
   - *Quick start, not for this use case in production:* enable the
     bucket's "Public Development URL" — this gives you a `pub-<hash>.r2.dev`
     URL immediately, but Cloudflare's own docs state it "is rate-limited
     and should only be used for development purposes" and that it's an
     "unsupported access path" with no reliability guarantee. **A storage
     provider's downloader opens multiple concurrent connections per file
     and will intermittently hang against this URL** — confirmed by
     directly testing it. Fine for a first dry run, not for a real deal.
   - *What to actually use:* Bucket → Settings → Custom Domains → connect a
     domain or subdomain you control. This routes traffic through
     Cloudflare's normal CDN path instead of the throttled dev endpoint.
     Your `--public-base-url` becomes `https://your-domain`.
3. **Credentials:** R2 → Manage API Tokens → Create API Token → permissions
   scoped to object read/write on this bucket. This gives you an Access Key
   ID and Secret Access Key (S3-compatible).
4. **Endpoint:** `https://<account_id>.r2.cloudflarestorage.com` — the
   account ID is in the Cloudflare dashboard URL or the R2 overview page.
5. Region is always `auto` for R2 — the script sets this automatically for
   `--storage-provider r2`, no flag needed.

```bash
--storage-provider r2 \
--bucket my-bucket \
--endpoint https://abc123.r2.cloudflarestorage.com \
--public-base-url https://your-custom-domain.example.com \
--access-key-id <access_key_id> \
--secret-access-key <secret_access_key>
```

## AWS S3 (`--storage-provider s3`)

More setup ceremony than R2 (IAM users/roles, bucket policy JSON), and S3
charges for egress — worth it mainly if the client already has AWS
infrastructure and credentials in place.

1. Create a bucket (any region).
2. Bucket → Permissions → uncheck "Block all public access", then add a
   bucket policy granting `s3:GetObject` to `*` (public read) — scope it to
   the `piece/*` and `<dataset_name>/*` prefixes specifically if you'd
   rather not make the whole bucket public.
3. IAM → create a user (or role) with a policy allowing `s3:PutObject` /
   `s3:GetObject` on this bucket, and generate an access key for it.
4. `--public-base-url` is `https://<bucket>.s3.amazonaws.com` (virtual-
   hosted style) unless you've put a CDN/custom domain in front of it.

```bash
--storage-provider s3 \
--bucket my-bucket \
--region us-east-1 \
--public-base-url https://my-bucket.s3.amazonaws.com \
--access-key-id <access_key_id> \
--secret-access-key <secret_access_key>
```

## Google Cloud Storage (`--storage-provider gcs`)

1. Create a bucket.
2. IAM & Admin → Service Accounts → create one, grant it
   `roles/storage.objectAdmin` scoped to this bucket (or the project, if
   that's an acceptable blast radius).
3. Create and download a JSON key for that service account — this is the
   `--gcs-service-account-json` path. Treat this file like a password.
4. Bucket → Permissions → grant `allUsers` the `Storage Object Viewer` role
   for public read (again, scope to specific prefixes if preferred).
5. `--public-base-url` is `https://storage.googleapis.com/<bucket>` unless
   fronted by a custom domain/CDN.

```bash
--storage-provider gcs \
--bucket my-bucket \
--public-base-url https://storage.googleapis.com/my-bucket \
--gcs-service-account-json /path/to/service-account.json
```

## Any other S3-compatible backend (`--storage-provider other-s3`)

Backblaze B2, MinIO, Wasabi, a self-hosted deployment, etc. — anything
speaking the S3 API. Needs the same fields as `s3` plus an explicit
`--endpoint`:

```bash
--storage-provider other-s3 \
--bucket my-bucket \
--endpoint https://s3.us-west-002.backblazeb2.com \
--region us-west-002 \
--public-base-url https://f002.backblazeb2.com/file/my-bucket \
--access-key-id <key_id> \
--secret-access-key <application_key>
```

Consult the specific provider's docs for their exact endpoint format,
region naming, and public-URL scheme — these vary more between S3-compatible
providers than the S3 API surface itself does.
