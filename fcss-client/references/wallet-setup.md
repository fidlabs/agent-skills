# Wallet Setup

`propose-filecoin-deal.sh setup` checks for a configured client wallet and
stops with these same instructions if none is found. This skill never
generates, chooses, or asks to see a private key — wallet custody is
entirely the client's decision, made by the client, on their own machine.

## What's needed

- **A wallet** — either a Lotus wallet (the private key never leaves the
  wallet, which is why `filecoin-porep-market-tooling`'s own docs recommend
  it) or a raw private key. The address must be a delegated `f410` address
  or a standard `0x` EVM address, and must already exist on-chain (have
  received something) before it can send transactions.
- **FIL**, to pay gas for every transaction (proposing, `init-deal`,
  DataCap allocation batches, deposits).
- **USDFC** — Secured Finance's FIL-collateralized, USD-pegged,
  Filecoin-native stablecoin — to pay for storage. `init-deal` deposits the
  **first month of each copy** up front; later months are deposited with
  `propose-filecoin-deal.sh fund`.

Use a wallet dedicated to FCSS, not one holding unrelated funds. `fund`
covers every deal of the wallet that is ready for deposit, so a dedicated
wallet also keeps that predictable.

There is no testnet deployment today — every wallet configured here is a
mainnet wallet handling real value.

## Which token, exactly

`filecoin-porep-market-tooling` names its payment-token setting
`USDC_TOKEN` and its help texts say "USDC", but the mainnet address it is
configured with (`0x80B98d3aa09ffff255c3ba4A241111Ff1262F045`) is **USDFC**
(on-chain symbol `USDFC`, 18 decimals; verified directly against the token
contract). This skill and its scripts say USDFC for that reason, and
default to it.

The market also allows **axlUSDC** (Axelar-wrapped USDC,
`0xEB466342C4d449BC9f53A865D5Cb90586f405215`, 6 decimals) as a payment
token, but as of 2026-10-15 no storage-provider offer accepts it. A deal can
only match offers that accept its token, so stick with USDFC unless
`quote` shows offers for another token and the client explicitly wants it.
Neither is interchangeable with Circle's native USDC on other chains —
sending the wrong token to this wallet will not fund it.

## Configuring the wallet

Set exactly one of these in `filecoin-porep-market-tooling/.env` (created
from `.env.mainnet`, and restricted to the owner with `chmod 600`, by
`setup` on first run):

```bash
# Option A — Lotus wallet (recommended; the private key never leaves it)
CLIENT_LOTUS_WALLET=<f410 or 0x wallet address>
CLIENT_LOTUS_TOKEN=<from `lotus auth create-token --perm sign`>

# Option B — raw private key
CLIENT_PRIVATE_KEY=0x<32-byte hex private key>
```

For Option A, create the wallet first if the client doesn't have one:

```bash
lotus wallet new delegated
lotus auth create-token --perm sign
```

**Treat this `.env` file like a password.** Never `cat`, print, echo,
commit, screen-share, or paste its contents anywhere — including into a
chat with an AI agent. `propose-filecoin-deal.sh` only ever checks that a
wallet setting is present; nothing in the file should ever need to leave
the client's machine.

Once configured, re-run `setup` — it validates that the wallet resolves to a
usable address (`client info --test-keys`) before saying it's ready.

## Funding

**Gas (FIL):** needs are small relative to storage costs. Any exchange or
bridge that can send FIL to a standard `0x`/`f410` address works; check that
a chosen exchange specifically supports withdrawing to that address format
before assuming it does.

**Storage payments (USDFC):** several documented acquisition routes:

1. **Bridge/swap from another chain** with [Squid Router](https://app.squidrouter.com)
   — simplest if funds currently live elsewhere.
2. **Swap FIL → USDFC on SushiSwap V3** (a FIL/USDFC pool exists on
   Filecoin) — simplest if FIL is already held.
3. **Mint against FIL collateral** at Secured Finance's
   [USDFC app](https://app.usdfc.net) — deposit FIL into a "Trove" and mint
   USDFC against it. This is a DeFi collateralized-debt position, not a
   purchase: verify the current minimum collateral ratio and minimum
   borrow amount in [Secured Finance's docs](https://docs.secured.finance/usdfc-stablecoin/overview)
   before minting, and understand liquidation risk.

For most clients, options 1 or 2 (swapping) are the right choice.

**How much:** `quote` prints the monthly cost of both copies, the up-front
amount (first month of each copy), and the wallet's current USDFC balance,
and warns if the balance can't cover the up-front deposit. `init-deal`
refuses to run for a copy it can't fund, before sending anything, so a
shortfall stops `execute` cleanly; top up and re-run it.

## After funding

```bash
./propose-filecoin-deal.sh setup     # confirms the wallet resolves correctly
./propose-filecoin-deal.sh quote ... # shows USDFC balance against what the deals need
./propose-filecoin-deal.sh status --manifest-url <url>   # FilecoinPay balance once deals exist
```

Keep FilecoinPay funded month to month with `fund --months <n>` (or
`--whole-deal` to prepay the full duration). Each `fund` run moves real
money and needs the client's explicit approval.
