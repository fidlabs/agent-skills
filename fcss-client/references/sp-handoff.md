# Storage Provider Handoff

After `propose-filecoin-deal.sh execute`, the client side of both copies is
done. Each copy now sits with a different storage-provider organization, and
the rest happens on the SP's own infrastructure, with the SP's own keys.
**This skill never runs `sp ...` commands** — not even if the client also
operates an SP. Give the client this information to pass on, then track
progress with `status`.

## What each SP needs

`execute` prints one block per deal. Each SP needs:

- **Its deal ID** — the SP can also find it with `sp get-deals`.
- **The commands**, run from their own `filecoin-porep-market-tooling`
  checkout:

  ```bash
  # DataCap deals (the current mainnet setup):
  python3 porep_tooling_cli.py sp onboard-data <deal-id> --output-dir <dir> --port 443 --claim-allocations <curio|boost>

  # SECTOR_PLACEMENT deals (only if `execute` said the market uses it):
  python3 porep_tooling_cli.py sp onboard-data <deal-id> --output-dir <dir> --port 443
  python3 porep_tooling_cli.py sp get-piece-notifications <deal-id>
  ```

- **Why `--port 443`:** `onboard-data` builds every download URL as
  `<scheme>://<manifest host>:<port>/piece/<pieceCid>`, with the port
  defaulting to `7777` (Singularity's own server). The pieces live in the
  client's public bucket, which only serves HTTPS on `443`. Passing `--host`
  does not change this — the port is still appended.

## Timing the client should expect

- **Start promptly.** `make-allocations` gives each DataCap allocation an
  expiration about 30 days out. If an SP hasn't claimed its allocations by
  then, they expire and the client has to sort it out with the market
  operator.
- **Sealing takes time.** Downloading and sealing tens of TiB typically takes
  days to weeks. The deal stays `ACCEPTED` the whole time; that is normal.
- **Done means `ACTIVE`.** A copy is stored when `status` shows its deal
  `ACTIVE` with evidence covering all requested bytes. From then on the SP is
  paid from the client's FilecoinPay deposit, which the client keeps funded
  with `fund`.

## What the client keeps doing

- Keep the bucket online and public, and never change the manifest or the
  pieces — the SP may re-download at any point during onboarding.
- Check `status` periodically (daily is plenty) rather than polling tightly.
- Top up payment with `fund` before the first month's deposit runs out.

## How to reach an SP

The chain records the SP's provider ID and organization address (both shown
by `status`), not contact details. If the client has no direct channel to
the SPs, the PoRep Market / FCSS operator coordinates SP onboarding — point
the client there rather than guessing contact details.
