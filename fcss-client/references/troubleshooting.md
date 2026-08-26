# Troubleshooting

Every entry below is a real incident hit while building and operating this
pipeline, not a hypothetical. Where a bug has since been fixed in the
bundled scripts, it's kept here anyway — it explains *why* the script does
what it does, and matters again if you ever hand-run the underlying
commands or modify the scripts.

## Symptom → cause → fix

| Symptom | Cause | Fix |
|---|---|---|
| Prepared/uploaded data is a tiny fraction of the expected size, no error anywhere | Source directory looks full size in Finder/Explorer but the files aren't actually materialized on disk — see "Silent data loss" below | `du -sh` the source directory directly (not through an agent relay) and compare to the expected size before preparing |
| SP's downloads hang or time out intermittently, but a single manual request to the same URL works fine | Cloudflare R2's `pub-*.r2.dev` public URL is rate-limited and documented as dev-only | Front the bucket with a custom domain — see storage-backend-setup.md |
| `gaierror: Name or service not known` fetching a manifest | The manifest was served via a Cloudflare quick tunnel from an old version of this pipeline, and that tunnel's host (client's laptop) went offline — quick tunnels never reuse the same hostname on restart, so this is unrecoverable for that deal | Current versions of `prepare-filecoin-dataset.sh` upload to durable client-owned storage instead of tunneling, specifically because of this incident. If you see this, you're looking at a stale deployment — re-prepare with a current version, and note the affected deal's `manifest_location` cannot be changed on-chain (see below) |
| `duplicated key not allowed` when Singularity containers start against a fresh database | Two services running the Singularity image both auto-migrate the schema on startup, racing on an empty DB | The current compose file only runs one Singularity-image service (`singularity-api`) against the DB, so this shouldn't recur as shipped. If you add a second Singularity service (e.g. a custom content-provider), pass `--no-automigrate` to it |
| `storage with name X already exists: duplicate record` (HTTP 409) | Normal — Singularity's storage-create endpoint returns 409 for a name collision | Not an error to fix; the script's `ensure_storage` helper already treats this as success after confirming the existing path matches |
| Creating an already-existing preparation returns HTTP 500 `duplicated key not allowed`, not 409 | Singularity's preparation-create endpoint doesn't use the same 409 convention as storage-create — this is an API inconsistency, not a bug in the script | The script checks `GET /preparation/{name}` first and skips creation if it already exists, rather than trying to pattern-match error text |
| `PATCH /storage/{name}` doesn't seem to change anything | That endpoint only updates `config` fields — it cannot change `path` | Delete and recreate the storage with the correct path (the script's `ensure_storage` does this automatically when it detects a stale path) |
| Deleting a storage fails with `storage is still in use` (HTTP 400) | The storage is attached to an existing preparation | You cannot fix a storage's path once a preparation references it. Either re-run with the original source/output directories, or use a new `dataset_name` |
| rclone fails with an endpoint/URI parse error (`resolve endpoint: endpoint rule error, Custom endpoint ... was not a valid URI`) | rclone's on-the-fly connection-string syntax requires quoting any parameter value containing a colon — an `endpoint=https://host:port` value has two | The bundled script already quotes this correctly (`endpoint=\"${ENDPOINT}\"`). Only relevant if you hand-build an rclone remote spec |
| `propose-filecoin-deal.sh` stops silently mid-command with no error message — output just ends | A now-fixed bug: `yes \| some-command` under `set -euo pipefail` can silently abort the whole script even when `some-command` succeeds — see "The `yes \| ...` SIGPIPE bug" below | Fixed in the bundled script (`(yes 2>/dev/null \|\| true) \| ...`). If you see this on an unmodified copy, you're on a stale version — re-download |
| Testing `--storage-provider other-s3` against a self-hosted S3-compatible server (e.g. local MinIO) on the same machine, and the upload hangs indefinitely | `rclone` runs inside its own Docker container (the official `rclone/rclone` image) — `--endpoint http://localhost:PORT` refers to *that container's own* loopback, not the host machine, so it can never reach a server running on the host | Use `--endpoint http://host.docker.internal:PORT` instead of `localhost` when the endpoint is on the same machine running the script |
| A freshly generated wallet (never funded or used) prints `Filecoin.StateLookupID(...) failed: {'code': 11, 'message': 'actor not found'}` when checked | Expected for any address with zero on-chain history — Filecoin only assigns an Actor ID once something touches the address on-chain (e.g. receiving FIL) | Non-fatal — `client info`/`setup` still succeeds overall. Resolves itself once the wallet is funded and has at least one on-chain transaction |

## Silent data loss: two ways a folder can lie about its size

Both of these produce the same misleading symptom: `du -sh` (and Finder/
Explorer) report the full expected size, Docker mounts the directory
successfully, Singularity scans it without error, and the resulting
manifest is real, valid, and tiny — because it faithfully packed the small
amount of data that was actually, physically present.

1. **Cloud-sync placeholder files.** iCloud Drive ("Optimize Mac Storage"),
   Dropbox Smart Sync, and Google Drive's streaming mode all show the full
   logical file size in the OS while the bytes are placeholder stubs, not
   downloaded content. `du -sh` (and even `du -sLh`, following symlinks)
   only counts what's physically on disk. Fix: force a full local download
   in whichever sync client owns the folder before pointing this pipeline
   at it.
2. **Un-pulled Git LFS objects.** A dataset checked out from a Hub that
   uses Git LFS (common for ML/dataset repos) shows symlinks named after
   the real files, pointing at `../../blobs/<hash>` — but if `git lfs pull`
   was never run (or the local blob cache was cleaned), those symlinks are
   dangling and the real content was never fetched. Diagnose with
   `git lfs status` inside the repo: entries showing `(LFS: <hash> -> File:
   deleted)` mean the actual bytes are missing locally. Fix: `git lfs pull`
   (or `git lfs fetch --all && git lfs checkout`), then re-verify with
   `du -sh` before re-running the prep script.

In both cases the fix is upstream of this pipeline entirely — nothing in
`prepare-filecoin-dataset.sh` can detect "this symlink target doesn't
really exist" versus "this is genuinely a small dataset." Always sanity
check the real, on-disk size directly on the machine holding the data
before preparing — not by relaying a number an agent computed on a
different machine.

## The manifest_location problem

A PoRep Market deal's `manifest_location` is set once at `propose-deal`
time and **cannot be changed afterward** — there is no update function
anywhere in the contract interface (`propose_deal`, `accept_deal`,
`complete_deal`, `terminate_deal`, `reject_deal`, `reject_accepted_deal`,
`update_rail_id`, `set_deal_completion_padding` were all checked; none
touch this field). If the host serving a manifest goes away permanently
after a deal has already been proposed against it (the tunnel-death
scenario above being the canonical example), that specific deal cannot be
repointed at a new location. The only paths forward are: get the original
host reachable again (impossible for an ephemeral Cloudflare quick tunnel,
since it never reuses a hostname), or reject/terminate the deal and
propose a fresh one — a decision for the client and storage provider to
make together, never something to do unilaterally on the client's behalf.

This is the whole reason the current pipeline uploads to client-owned
durable storage instead of serving from the client's own machine: the
window between proposing a deal and a storage provider completing
onboarding can span days, and nothing that depends on a laptop staying
online for that long is safe to bake into an immutable on-chain field.

## `filecoin-porep-market-tooling`-specific notes

- **The upstream tool calls the payment token "USDC" everywhere in its own
  code and env vars** (`USDC_TOKEN`, the `USDCToken` class,
  `--price-per-sector-per-month`'s own help text) — **the actual mainnet
  token configured is USDFC** (Secured Finance's Filecoin-native,
  FIL-collateralized stablecoin), confirmed by checking the configured
  contract address (`USDC_TOKEN` in `.env.mainnet`) against Filecoin's own
  Filfox explorer, which identifies it as USDFC. This skill and its scripts
  say USDFC throughout; if you're reading the underlying tool's source or
  its own README and see "USDC", that's the upstream project's naming, not
  a different token. Don't assume it's interchangeable with Circle's USDC —
  Filecoin isn't among Circle's natively-issued USDC chains as of early
  2026, which is exactly why this distinction matters.
- **Every transaction needs two confirmations, always.** First, the
  command-level confirmation (e.g. `propose-deal-from-manifest` showing the
  computed deal terms and cost), then a second, lower-level "final
  confirmation" showing raw transaction parameters (from/to/gas/nonce)
  right before signing. `propose-filecoin-deal.sh execute` pipes `yes`
  through both — this is only safe because a human already saw the real
  cost via `preview` and explicitly agreed before `execute` ran. If you
  decline the low-level confirmation manually, the tool falls back to
  simulating the transaction rather than erroring — it does not abort with
  an exception.
- **`propose-deal-from-manifest` never returns a deal ID** — only a
  transaction hash. Since this pipeline always proposes two deals against
  the identical manifest URL, deal IDs are recovered afterward via
  `client get-deals proposed`, filtered by matching `manifest_location`,
  taking the two most recent (highest) IDs. If more than two proposed deals
  already share that exact manifest URL, `execute` will say so explicitly
  rather than guessing — check `client get-deals proposed` manually in that
  case.
- **`init-accepted-deals` requires sufficient USDFC balance up front** — it
  throws rather than partially completing if the wallet's balance is short
  of the calculated deposit. Check `client get-filecoinpay-account` before
  a large `execute` run, not after it fails partway through.
- **A deal only leaves `PROPOSED` state when a storage provider explicitly
  accepts it** — this is an external, asynchronous action outside anyone's
  control on the client side. `execute`'s polling loop can legitimately run
  for days; that is expected, not a hang.
- **A rejected deal is not an error to retry.** `execute` reports a
  `REJECTED`/`TERMINATED` deal plainly and moves on to complete whichever
  of the two deals (if any) was accepted. Proposing a replacement for the
  rejected one is a fresh decision, not an automatic retry.

## Maintainer notes (if modifying either bundled script)

- **The `yes | ...` SIGPIPE bug — the most severe one found while testing
  this skill end to end.** Every transactional command in
  `propose-filecoin-deal.sh` needs `yes` piped into it to answer the
  underlying CLI's interactive confirmation prompts. Under `set -euo
  pipefail`, plain `yes | some-command` is fundamentally broken: `yes`
  never terminates on its own, so the moment `some-command` finishes
  reading its input and exits, `yes` gets killed by `SIGPIPE` (exit 141) —
  and `pipefail` reports the *whole pipeline* as failed with that code,
  even when `some-command` itself succeeded perfectly. Combined with
  `set -e`, this aborts the entire script silently, with no error message,
  at exactly the point where a `yes | ...` line runs. Confirmed directly:
  ```bash
  set -euo pipefail
  yes | python3 -c "print(1)"
  echo "this line never runs"   # true — the script dies at the line above
  ```
  This bit `preview` mode specifically during testing: it silently stopped
  right after the wallet-check step, printing nothing further and no error,
  for exactly this reason. Fixed everywhere by wrapping `yes` so its own
  exit status always reads as 0 regardless of how it terminates —
  `(yes 2>/dev/null || true) | some-command` — which preserves real
  failures in `some-command` while masking only the spurious SIGPIPE. If
  you add any new `yes | ...` invocation to either script, use this same
  wrapped form, not plain `yes |`.
- **`set -o pipefail` will silently kill the whole script** if a pipeline's
  last-checked command is a `grep` that finds nothing (exit 1) inside a
  `$(...)` capture — this happened with an early version's `grep
  content-length:` header parse, which aborted with no error message at
  all when the header was absent. Always add `|| true` to a `grep` inside
  a capture unless its absence should genuinely abort the script.
- **Don't use bash 4+ features** (associative arrays, etc.) — macOS ships
  bash 3.2 by default, and these scripts are meant to run on whatever bash
  a client already has, not a Homebrew-updated one. An earlier version used
  `local -A` for tracking two deals' states; it was rewritten to use two
  plain scalar variables instead.
- **Content-Length can go missing on responses proxied through an
  intermediate hop** (this bit an earlier, now-removed tunnel-based
  architecture specifically) — a 1-byte range request and reading
  `Content-Range` instead is more robust for verifying a file's true size
  than trusting `Content-Length`, and is cheaper than downloading the whole
  file to check.
