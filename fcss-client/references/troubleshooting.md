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
| `gaierror: Name or service not known` fetching a manifest | The manifest was served via a Cloudflare quick tunnel from an old version of this pipeline, and that tunnel's host (client's laptop) went offline — quick tunnels never reuse the same hostname on restart, so this is unrecoverable for that deal | Current versions of `prepare-filecoin-dataset.sh` upload to durable client-owned storage instead of tunneling, specifically because of this incident. If you see this, you're looking at a stale deployment — re-prepare with a current version, and note the client cannot change the affected deal's `manifest_location` itself (see below) |
| `duplicated key not allowed` when Singularity containers start against a fresh database | Two services running the Singularity image both auto-migrate the schema on startup, racing on an empty DB | The current compose file only runs one Singularity-image service (`singularity-api`) against the DB, so this shouldn't recur as shipped. If you add a second Singularity service (e.g. a custom content-provider), pass `--no-automigrate` to it |
| `storage with name X already exists: duplicate record` (HTTP 409) | Normal — Singularity's storage-create endpoint returns 409 for a name collision | Not an error to fix; the script's `ensure_storage` helper already treats this as success after confirming the existing path matches |
| Creating an already-existing preparation returns HTTP 500 `duplicated key not allowed`, not 409 | Singularity's preparation-create endpoint doesn't use the same 409 convention as storage-create — this is an API inconsistency, not a bug in the script | The script checks `GET /preparation/{name}` first and skips creation if it already exists, rather than trying to pattern-match error text |
| `PATCH /storage/{name}` doesn't seem to change anything | That endpoint only updates `config` fields — it cannot change `path` | Delete and recreate the storage with the correct path (the script's `ensure_storage` does this automatically when it detects a stale path) |
| Deleting a storage fails with `storage is still in use` (HTTP 400) | The storage is attached to an existing preparation | You cannot fix a storage's path once a preparation references it. Either re-run with the original source/output directories, or use a new `dataset_name` |
| rclone fails with an endpoint/URI parse error (`resolve endpoint: endpoint rule error, Custom endpoint ... was not a valid URI`) | rclone's on-the-fly connection-string syntax requires quoting any parameter value containing a colon — an `endpoint=https://host:port` value has two | The bundled script already quotes this correctly (`endpoint=\"${ENDPOINT}\"`). Only relevant if you hand-build an rclone remote spec |
| `propose-filecoin-deal.sh` stops silently mid-command with no error message — output just ends | A now-fixed bug: `yes \| some-command` under `set -euo pipefail` can silently abort the whole script even when `some-command` succeeds — see "The `yes \| ...` SIGPIPE bug" below | Fixed in the bundled script (`(yes 2>/dev/null \|\| true) \| ...`). If you see this on an unmodified copy, you're on a stale version — re-download |
| Testing `--storage-provider other-s3` against a self-hosted S3-compatible server (e.g. local MinIO) on the same machine, and the upload hangs indefinitely | `rclone` runs inside its own Docker container (the official `rclone/rclone` image) — `--endpoint http://localhost:PORT` refers to *that container's own* loopback, not the host machine, so it can never reach a server running on the host | Use `--endpoint http://host.docker.internal:PORT` instead of `localhost` when the endpoint is on the same machine running the script |
| A freshly generated wallet (never funded or used) prints `Filecoin.StateLookupID(...) failed: {'code': 11, 'message': 'actor not found'}` when checked | Expected for any address with zero on-chain history — Filecoin only assigns an Actor ID once something touches the address on-chain (e.g. receiving FIL) | Non-fatal — `client info`/`setup` still succeeds overall. Resolves itself once the wallet is funded and has at least one on-chain transaction |
| `quote` says NOT ENOUGH MATCHES, or `propose-deal` fails with `NoOfferMatched` | No eligible offer from an organization that doesn't already hold a copy. `quote` lists every offer with the reason it doesn't match | Change the terms the reasons point at. Most common: `--latency-ms` above 0 (an offer with no published latency never satisfies a latency requirement, and as of 2026-10-15 no offer publishes one), or a max price below what a second organization charges |
| `propose-deal` for copy 2 fails after copy 1 succeeded | Only one organization matched these terms (the registry never gives the same organization two copies of one manifest) | Copy 1 is kept. Adjust the terms with the client, re-run `quote`, then re-run `execute` — it proposes only the missing copy |
| `init-deal` fails with `... balance ... is less than required deposit` | Wallet holds less USDFC than the first month of that copy | Nothing was sent. Top up the wallet, re-run `execute` |
| `manifest URL must answer HTTP 200 directly, without redirects` | The public URL redirects (e.g. http→https, a CDN rule) or isn't public yet. The tooling fetches manifests with redirects disabled | Use the final URL as `--public-base-url`, or fix the bucket/CDN so the manifest answers 200 directly |
| `Manifest URL resolves to a disallowed IP address` | The tooling refuses manifest hosts that resolve to private, loopback, or reserved addresses (SSRF guard) | Serve the manifest from a public host. Local test setups are not supported by this skill |
| `a different manifest is already published at ...` from the prep script | Re-ran prep with changed data under an existing `dataset_name` | Use a new `dataset_name`. Deals may already reference the published bytes |
| `execute` stops with `two live copies are held by the same SP organization` | Two deals reference the same manifest URL but were proposed against different manifest bytes (the URL's content changed between proposals), so the registry treated them as different datasets | Stop. Review with `status`; the client decides with the market operator what to do with the duplicate |
| `make-allocations` fails with `Some allocations claimed but deal still in ACCEPTED state` | Re-ran after the SP already started claiming, before DataCap posting was finished | Don't retry blindly. Check `status`; if DataCap posting is incomplete, contact the market operator |
| Internal error `Precision lost: ... has remainder` when proposing | The max price per TiB isn't representable per 32 GiB sector in the token's smallest units (more likely with 6-decimal tokens), or float rounding of an unusual decimal | Use a simpler price, e.g. `4` or `4.5` |
| A tooling command prints `Please run the command again to use the updated version` and exits 0 | The tooling's self-update prompt was answered "yes" | `propose-filecoin-deal.sh` sets `SKIP_SELF_UPDATE=true` and pins a commit, so this shouldn't happen through it. If you ran the tooling by hand, re-run the command, then re-run `setup` to return to the pinned commit |
| Tooling errors about `POREP_MARKET_VIEW_HELPER` or contract addresses when run by hand | `.env` was created from an older `.env.mainnet` (by an earlier version of this skill) | `propose-filecoin-deal.sh` exports the pinned contract addresses itself. When running the tooling by hand, copy those three values from `.env.mainnet` into `.env` |

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

A deal's manifest URL (`manifest_location`) and the hash of the manifest's
bytes are set when it is proposed. **The client cannot change them.** In
PoRep Market v2 the market admin can (`updateManifestLocation`), but only
while the deal is `ACCEPTED` and before the SP has submitted any evidence.
If the host serving a manifest goes away permanently (the tunnel-death
scenario above being the canonical example), the paths forward are: get the
original URL serving the same bytes again, ask the market operator to
repoint the deal while that is still allowed, or have the deal terminated
and propose a fresh one — decisions for the client to make with the market
operator, never something to do unilaterally on the client's behalf.

This is why the pipeline uploads to client-owned durable storage instead of
serving from the client's machine, and why the prep script refuses to
overwrite a published manifest with different bytes: weeks can pass between
proposing a deal and an SP finishing onboarding, and the URL must keep
serving exactly what the deal committed to.

## `filecoin-porep-market-tooling`-specific notes

Verified against the commit pinned in `propose-filecoin-deal.sh`
(`TOOLING_REF`) and PoRep Market contracts v2.0.2.

- **Deals are matched, not accepted.** `client propose-deal` sends a request
  (manifest hash and URL, size, SLA thresholds, max price, token, duration,
  deal type); the SPRegistry picks an eligible offer on-chain and the deal is
  created directly in `ACCEPTED`. Among eligible offers it prefers the
  cheapest (within a 1% band), then the least-loaded provider. There is no
  `PROPOSED` waiting period and no client-side SP choice; only admins can
  propose against a specific offer.
- **Two copies are enforced per organization.** The registry records which
  organizations already hold a deal for a given client and manifest hash and
  skips them when matching. That's what makes the second proposal land with
  a different, independent organization. It is keyed on the manifest
  *hash*: change the manifest bytes and the registry treats it as a new
  dataset.
- **The upstream tool calls the payment token "USDC"** (`USDC_TOKEN`,
  `USDCToken`, help texts). The configured mainnet address is USDFC. The
  registry also allows axlUSDC; see [wallet-setup.md](wallet-setup.md).
- **Price is a per-TiB maximum in decimal tokens.** `--price-per-tib-per-month`
  is converted by the tooling to smallest units per 32 GiB sector and
  rejected above 100. The deal is billed at the matched offer's price.
- **Every transaction needs two confirmations.** First a command-level one
  (e.g. `propose-deal` showing the computed terms and maximum cost), then a
  "final confirmation" with raw transaction parameters. `propose-filecoin-deal.sh`
  pipes `yes` through both — only safe because a human already approved the
  `quote`. If the final confirmation is declined, the tool falls back to
  simulating the transaction rather than erroring.
- **Dry runs still estimate gas.** With `DRY_RUN=true` the transaction is
  built (which runs gas estimation against the chain, so a `NoOfferMatched`
  revert shows up) and signed, but not sent. A dry run can only check the
  *next* proposal: copy 2's match depends on copy 1's organization being
  reserved first, which is why `quote` also evaluates offers itself.
- **`propose-deal` prints the new deal ID**; `client get-deals` lists deals
  without their manifest URL, so `propose-filecoin-deal.sh` matches copies by
  reading each deal with `client get-deal` (`data.manifest_location`).
- **`init-deal` deposits money.** Besides the validator and payment rail, it
  deposits the first month for that deal into FilecoinPay and approves the
  validator as operator. It checks the wallet balance before sending
  anything.
- **`make-allocations` only applies to DataCap deals** (evidence type
  `VERIF_REG_CLAIMS`, the current mainnet global adapter — see `client
  info`). Under `SECTOR_PLACEMENT` there are no allocations; the SP proves
  placement when sealing. Allocations expire about 30 days after they're
  made.
- **`deposit-for-deals` is wallet-wide.** Without a deal ID it covers every
  ready deal of the wallet; with one it still nets against the whole
  FilecoinPay account balance. `propose-filecoin-deal.sh fund` uses the
  wallet-wide form so two deals aren't under-funded.
- **The tooling self-updates** from its tracking branch unless
  `SKIP_SELF_UPDATE=true`, and with piped "yes" an update exits 0 without
  running the command. The pinned, detached checkout plus that variable
  prevents this.

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
  This bit the old `preview` mode specifically during testing: it silently stopped
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
  plain scalar variables instead. Also under bash 3.2, `"${arr[@]}"` on an
  empty array fails under `set -u`; use `${arr[@]+"${arr[@]}"}`.
- **Never close stdin on a tooling command that may prompt.** Read-only
  calls run with `</dev/null` so a surprise prompt fails instead of hanging,
  which is why `client validate-manifest` (it asks "Show manifest?") is fed
  an explicit `no` instead.
- **Content-Length can go missing on responses proxied through an
  intermediate hop** (this bit an earlier, now-removed tunnel-based
  architecture specifically) — a 1-byte range request and reading
  `Content-Range` instead is more robust for verifying a file's true size
  than trusting `Content-Length`, and is cheaper than downloading the whole
  file to check.
