# Wallet Setup

`propose-filecoin-deal.sh setup` checks for a configured client wallet and
stops with these same instructions if none is found. This skill never
generates, chooses, or asks to see a private key — wallet custody is
entirely the client's decision, made by the client, on their own machine.

## What's needed

- **A wallet** — either a raw private key, or a Lotus wallet (the private
  key never leaves the wallet in that mode, which is why
  `filecoin-porep-market-tooling`'s own docs recommend it).
- **FIL**, to pay gas for every transaction (proposing deals, allocating
  DataCap, depositing funds).
- **USDFC** — Secured Finance's FIL-collateralized, USD-pegged,
  Filecoin-native stablecoin — to actually pay for storage over a deal's
  duration. (The upstream tooling's own code and env vars still call this
  token "USDC" — see the naming note below. It's the same token either way,
  just an upstream naming quirk.)

There is no testnet deployment today — every wallet configured here is a
mainnet wallet handling real value.

## A naming note, so this isn't confusing later

`filecoin-porep-market-tooling` names its payment-token config `USDC_TOKEN`
and its code class `USDCToken`, and its own `--price-per-sector-per-month`
help text says "USDC smallest units." That's the upstream project's own
generic/legacy naming — **the actual mainnet contract address it's
configured to use is USDFC**, confirmed by checking that address
(`grep USDC_TOKEN filecoin-porep-market-tooling/.env.mainnet`) against
Filecoin's Filfox block explorer, which identifies it as USDFC. This skill
and its bundled scripts say USDFC throughout for that reason. Don't assume
it's fungible with Circle's USDC from another chain — Filecoin isn't among
Circle's natively-issued USDC chains as of early 2026, which is exactly why
the distinction matters here: acquiring the wrong stablecoin under the
"USDC" label and sending it to this wallet would not fund it correctly.

## Configuring the wallet

Set exactly one of these in `filecoin-porep-market-tooling/.env` (created
from `.env.mainnet` by `setup` on first run):

```bash
# Option A — raw private key (simplest)
CLIENT_PRIVATE_KEY=0x<32-byte hex private key>

# Option B — Lotus wallet (recommended; the private key never leaves it)
CLIENT_LOTUS_WALLET=<wallet address>
CLIENT_LOTUS_TOKEN=<from `lotus auth create-token --perm sign`>
```

For Option B, create the wallet first if the client doesn't have one:

```bash
lotus wallet new delegated
lotus auth create-token --perm sign
```

**Treat this `.env` file like a password.** Never `cat`, print, echo,
commit, screen-share, or paste its contents anywhere — including into a
chat with an AI agent. `propose-filecoin-deal.sh` only ever reads it
locally to run the underlying CLI; nothing about it should ever need to
leave the client's machine. Use a wallet dedicated to this purpose, not one
holding unrelated funds.

Once configured, re-run `setup` — it validates the wallet resolves to a
usable address (`client info --test-keys`) before saying it's ready.

## Funding

**Gas (FIL):** needs are small relative to storage costs — a modest amount
of FIL covers many operations. Any exchange or bridge that can send FIL to
a standard `0x`/`f410` address works; check that a chosen exchange
specifically supports withdrawing to that address format before assuming
it does.

**Storage payments (USDFC):** USDFC is a well-established part of the
Filecoin ecosystem (also used by FOC/Synapse-based tooling), with several
documented acquisition routes:

1. **Bridge/swap from another chain** with [Squid Router](https://app.squidrouter.com)
   — simplest if funds currently live elsewhere.
2. **Swap FIL → USDFC on SushiSwap V3** (a FIL/USDFC pool exists on
   Filecoin) — simplest if FIL is already held.
3. **Mint against FIL collateral** at Secured Finance's
   [USDFC app](https://app.usdfc.net) — deposit FIL into a "Trove" and mint
   USDFC against it. This is a DeFi collateralized-debt position, not a
   purchase: verify the current minimum collateral ratio and minimum
   borrow amount in [Secured Finance's docs](https://docs.secured.finance/usdfc-stablecoin/overview)
   before minting, and understand liquidation risk — if FIL's price drops,
   an under-collateralized position can be liquidated.

For most clients, options 1 or 2 (swapping) are the right choice; minting
(3) is worth it mainly if the client specifically wants FIL-collateralized
leverage rather than just acquiring USDFC outright.

**Verify what you actually hold before depositing.** `client
get-filecoinpay-account` reports the live token address, symbol, and
balance together — cross-check the address against
`filecoin-porep-market-tooling/.env.mainnet`'s `USDC_TOKEN` value so a
mismatch is caught before a transaction, not during one.

## After funding

```bash
./propose-filecoin-deal.sh setup                              # confirms wallet resolves correctly
# then, from filecoin-porep-market-tooling directly, to check balances before a large operation:
python3 porep_tooling_cli.py client info                      # FIL balance, derived address
python3 porep_tooling_cli.py client get-filecoinpay-account    # USDFC balance + token identity
```

Check both before running `propose-filecoin-deal.sh execute` on anything
sizeable — `init-accepted-deals` throws rather than partially completing if
the USDFC balance is short of the calculated deposit (see
[troubleshooting.md](troubleshooting.md)).
