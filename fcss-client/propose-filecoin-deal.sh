#!/usr/bin/env bash
# Proposes and completes PoRep Market deals (two copies) for a dataset
# already prepared by prepare-filecoin-dataset.sh, using
# https://github.com/fidlabs/filecoin-porep-market-tooling
#
# This script signs real blockchain transactions and moves real money
# (USDFC deposits). It is split into two modes on purpose:
#
#   preview  - computes and prints the deal terms and estimated cost.
#              Touches nothing on-chain (runs the underlying CLI in its
#              own DRY_RUN mode). Safe to run as many times as you like.
#   execute  - actually proposes both deals, waits (polling, can take
#              hours to days) for the storage provider to accept them,
#              then completes the onboarding pipeline automatically.
#
# Whoever is running this (a human, or an agent on a human's behalf)
# should see the `preview` output and get an explicit go-ahead from the
# actual account holder before ever running `execute` — the underlying
# CLI's own per-transaction confirmation prompts are answered
# automatically here (piped "yes", same as the tool's own documented
# non-interactive usage), so nothing will pause for a second look once
# `execute` starts.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ./propose-filecoin-deal.sh setup
  ./propose-filecoin-deal.sh preview  <manifest_url> <retrievability_bps> <bandwidth_mbps> <duration_months> <latency_ms> <price_per_sector_per_month_usdfc> [indexing_pct]
  ./propose-filecoin-deal.sh execute  <manifest_url> <retrievability_bps> <bandwidth_mbps> <duration_months> <latency_ms> <price_per_sector_per_month_usdfc> [indexing_pct]

Modes:
  setup     Clone/update the tooling, install dependencies, and check that
            a client wallet is configured. Does not touch the chain. Run
            this first, or let preview/execute run it for you.
  preview   Shows the exact deal terms and estimated total cost (for BOTH
            copies) without proposing anything for real. Read this before
            ever running execute.
  execute   Proposes both deals for real, then waits for the storage
            provider to accept them (this can take a long time — the
            script polls in the background), then automatically completes
            the onboarding pipeline (init, DataCap allocation, deposit)
            once both deals resolve. Only run this after a human has seen
            the preview output and explicitly agreed to proceed.

Arguments:
  manifest_url                     MANIFEST_URL from prepare-filecoin-dataset.sh
  retrievability_bps               Retrievability guarantee in basis points (0-10000). 0 = don't care.
  bandwidth_mbps                   Bandwidth guarantee in Mbps (0-64000). 0 = don't care.
  duration_months                  Storage duration in months. Minimum 6.
  latency_ms                       Latency guarantee in milliseconds.
  price_per_sector_per_month_usdfc  Price per 32 GiB sector per month, in decimal USDFC (e.g. 2.5).
  indexing_pct                     Optional. IPNI indexing guarantee percentage (0-100). Default 0.

Requires: git, python3 (>= 3.10). The client wallet (private key or Lotus
wallet) must already be configured — see `setup` output if it isn't.
USAGE
  exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

[ $# -ge 1 ] || usage
MODE="$1"; shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TOOLING_DIR="$SCRIPT_DIR/filecoin-porep-market-tooling"
VENV_DIR="$TOOLING_DIR/.venv"

# ---------------------------------------------------------------------------
# setup — clone/update tooling, install deps, verify wallet is configured.
# Does not touch the chain. Safe and idempotent to re-run.
# ---------------------------------------------------------------------------

run_setup() {
  command -v git >/dev/null 2>&1 || die "git not found in PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "python3 >= 3.10 required"

  if [ -d "$TOOLING_DIR/.git" ]; then
    echo "==> Updating filecoin-porep-market-tooling"
    git -C "$TOOLING_DIR" pull --ff-only
  else
    echo "==> Cloning filecoin-porep-market-tooling"
    git clone https://github.com/fidlabs/filecoin-porep-market-tooling.git "$TOOLING_DIR"
  fi

  if [ ! -d "$VENV_DIR" ]; then
    echo "==> Creating virtualenv"
    python3 -m venv "$VENV_DIR"
  fi

  echo "==> Installing dependencies"
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  pip install -q -r "$TOOLING_DIR/requirements.txt"

  if [ ! -f "$TOOLING_DIR/.env" ]; then
    cp "$TOOLING_DIR/.env.mainnet" "$TOOLING_DIR/.env"
  fi

  if ! grep -qE '^CLIENT_PRIVATE_KEY=.+' "$TOOLING_DIR/.env" \
     && ! grep -qE '^CLIENT_LOTUS_WALLET=.+' "$TOOLING_DIR/.env"; then
    cat >&2 <<EOF

No client wallet is configured yet — this is required before any deal can
be proposed, since proposing and completing deals means signing real
blockchain transactions and moving real USDFC.

This script will not generate or choose a wallet for you. Set one up
yourself:

  Option A — raw private key (simplest):
    Use any existing EVM-compatible wallet (PoRep Market runs on FEVM).
    Put its private key in:
      ${TOOLING_DIR}/.env
    as:
      CLIENT_PRIVATE_KEY=0x<your 32-byte hex private key>

  Option B — Lotus wallet (recommended; the private key never leaves
  the wallet):
    lotus wallet new delegated
    lotus auth create-token --perm sign
    Put both in ${TOOLING_DIR}/.env as:
      CLIENT_LOTUS_WALLET=<wallet address from above>
      CLIENT_LOTUS_TOKEN=<token from above>

Either way, that address needs:
  - enough FIL to cover gas fees, and
  - enough USDFC to cover deal deposits (this script's "preview" mode will
    show you the estimated amount once a wallet is configured).

Treat ${TOOLING_DIR}/.env like a password file — never share it or its
contents with anyone, including an AI agent. This script only reads it
locally; nothing in it should ever need to be pasted into a chat.

Once configured, re-run this script.
EOF
    exit 1
  fi

  echo "==> Verifying wallet resolves to a usable address"
  (yes 2>/dev/null || true) | python3 "$TOOLING_DIR/porep_tooling_cli.py" client info --test-keys
}

# ---------------------------------------------------------------------------
# Shared arg parsing for preview/execute
# ---------------------------------------------------------------------------

parse_deal_args() {
  [ $# -ge 6 ] || usage
  MANIFEST_URL="$1"
  RETRIEVABILITY_BPS="$2"
  BANDWIDTH_MBPS="$3"
  DURATION_MONTHS="$4"
  LATENCY_MS="$5"
  PRICE_PER_SECTOR_PER_MONTH_USDFC="$6"
  INDEXING_PCT="${7:-0}"
}

client_cli() {
  # shellcheck disable=SC1091
  source "$VENV_DIR/bin/activate"
  python3 "$TOOLING_DIR/porep_tooling_cli.py" client "$@"
}

# Converts a decimal USDFC amount to the smallest-unit integer the contract
# expects, using the token's real on-chain decimals (never hardcoded).
# Note: filecoin-porep-market-tooling's own CLI/code names this token
# "USDC" throughout (USDC_TOKEN env var, USDCToken class, --price-per-
# sector-per-month help text) — that's the upstream tool's own generic/
# legacy naming, not a different token. The configured mainnet address is
# actually USDFC (Secured Finance's Filecoin-native stablecoin); verified
# on-chain, not just going by the variable name.
usdfc_to_smallest_units() {
  local decimal_amount="$1"
  local decimals
  decimals=$(client_cli get-filecoinpay-account 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"]["decimals"])')
  python3 -c "import sys; print(int(round(float(sys.argv[1]) * (10 ** int(sys.argv[2])))))" "$decimal_amount" "$decimals"
}

# ---------------------------------------------------------------------------
# preview — dry-run cost/terms breakdown. Touches nothing on-chain.
# ---------------------------------------------------------------------------

run_preview() {
  parse_deal_args "$@"
  run_setup

  local price_smallest_units
  price_smallest_units=$(usdfc_to_smallest_units "$PRICE_PER_SECTOR_PER_MONTH_USDFC")

  echo
  echo "==> Estimating cost for ONE copy (dry run — nothing will be proposed)"
  echo
  (yes 2>/dev/null || true) | DRY_RUN=true client_cli propose-deal-from-manifest \
    --retrievability-bps "$RETRIEVABILITY_BPS" \
    --bandwidth-mbps "$BANDWIDTH_MBPS" \
    --duration-months "$DURATION_MONTHS" \
    --latency-ms "$LATENCY_MS" \
    --indexing-pct "$INDEXING_PCT" \
    --price-per-sector-per-month "$price_smallest_units" \
    "$MANIFEST_URL" || true

  echo
  echo "==================================================================="
  echo "The numbers above are for ONE copy. This dataset will be proposed as"
  echo "TWO independent deals (two copies), so double the monthly and total"
  echo "cost shown above to get the real total commitment."
  echo "==================================================================="
  echo
  echo "Nothing has been proposed. Re-run with 'execute' (same arguments)"
  echo "only after a human has reviewed this and explicitly agreed to it."
}

# ---------------------------------------------------------------------------
# execute — propose both deals for real, wait for acceptance, complete.
# ---------------------------------------------------------------------------

# client_cli wraps `python3 ... client`, but we need `yes` piped into it to
# answer its interactive confirmation prompts non-interactively. Plain
# `yes | client_cli ...` is broken under `set -o pipefail` + `set -e`:
# `yes` never terminates on its own, so it gets SIGPIPE'd (exit 141) the
# moment the downstream command finishes reading and exits — and pipefail
# then reports the PIPELINE as failed with that code even when the actual
# command succeeded, silently aborting the whole script right there.
# Confirmed by testing directly: `set -euo pipefail; yes | cmd` aborts
# immediately after cmd succeeds, with no error message. `(yes ... || true)`
# forces that stage's own exit status to always read as 0, so pipefail is
# only ever tripped by a REAL failure in the command being piped into.

propose_one_copy() {
  (yes 2>/dev/null || true) | client_cli propose-deal-from-manifest \
    --retrievability-bps "$RETRIEVABILITY_BPS" \
    --bandwidth-mbps "$BANDWIDTH_MBPS" \
    --duration-months "$DURATION_MONTHS" \
    --latency-ms "$LATENCY_MS" \
    --indexing-pct "$INDEXING_PCT" \
    --price-per-sector-per-month "$1" \
    "$MANIFEST_URL"
}

get_deal_state() {
  client_cli get-deal "$1" 2>/dev/null | python3 -c 'import json, sys; print(json.load(sys.stdin)["state"])'
}

run_execute() {
  parse_deal_args "$@"
  run_setup

  local price_smallest_units
  price_smallest_units=$(usdfc_to_smallest_units "$PRICE_PER_SECTOR_PER_MONTH_USDFC")

  echo "==> Proposing copy 1 of 2"
  propose_one_copy "$price_smallest_units"

  echo "==> Proposing copy 2 of 2"
  propose_one_copy "$price_smallest_units"

  echo "==> Identifying the two deal IDs just created"
  local matches
  matches=$(client_cli get-deals proposed 2>/dev/null | python3 -c "
import json, sys
deals = json.load(sys.stdin)
matches = [d for d in deals if d.get('manifest_location') == '$MANIFEST_URL']
matches.sort(key=lambda d: d['deal_id'], reverse=True)
for d in matches:
    print(d['deal_id'])
")
  local match_count
  match_count=$(echo "$matches" | grep -c . || true)

  if [ "$match_count" -lt 2 ]; then
    die "expected at least 2 PROPOSED deals matching this manifest, found $match_count. Check 'client get-deals proposed' manually before retrying."
  fi

  DEAL_ID_1=$(echo "$matches" | sed -n '1p')
  DEAL_ID_2=$(echo "$matches" | sed -n '2p')

  if [ "$match_count" -gt 2 ]; then
    echo "NOTE: found $match_count PROPOSED deals matching this manifest (not just the 2 just created)."
    echo "Proceeding with the 2 most recent: $DEAL_ID_1, $DEAL_ID_2. Review the rest manually if that's unexpected."
  fi

  echo
  echo "DEAL_ID_1=${DEAL_ID_1}"
  echo "DEAL_ID_2=${DEAL_ID_2}"
  echo
  echo "Both deals proposed. Waiting for the storage provider to accept them —"
  echo "this can take anywhere from minutes to days. Polling every 5 minutes."
  echo "Do not close this process; it will complete the rest of the pipeline"
  echo "automatically once both deals resolve."

  # Deliberately not using bash 4+ associative arrays here (macOS ships
  # bash 3.2 by default) — just two named deals, tracked as plain scalars.
  DEAL_1_RESOLVED=0; DEAL_1_ACCEPTED=0
  DEAL_2_RESOLVED=0; DEAL_2_ACCEPTED=0

  while true; do
    local all_resolved=1

    if [ "$DEAL_1_RESOLVED" = "0" ]; then
      local state1
      state1=$(get_deal_state "$DEAL_ID_1")
      case "$state1" in
        ACCEPTED) echo "  Deal $DEAL_ID_1: ACCEPTED"; DEAL_1_RESOLVED=1; DEAL_1_ACCEPTED=1 ;;
        REJECTED|TERMINATED) echo "  Deal $DEAL_ID_1: $state1 — will not be completed"; DEAL_1_RESOLVED=1 ;;
        *) echo "  Deal $DEAL_ID_1: still $state1"; all_resolved=0 ;;
      esac
    fi

    if [ "$DEAL_2_RESOLVED" = "0" ]; then
      local state2
      state2=$(get_deal_state "$DEAL_ID_2")
      case "$state2" in
        ACCEPTED) echo "  Deal $DEAL_ID_2: ACCEPTED"; DEAL_2_RESOLVED=1; DEAL_2_ACCEPTED=1 ;;
        REJECTED|TERMINATED) echo "  Deal $DEAL_ID_2: $state2 — will not be completed"; DEAL_2_RESOLVED=1 ;;
        *) echo "  Deal $DEAL_ID_2: still $state2"; all_resolved=0 ;;
      esac
    fi

    [ "$all_resolved" = "1" ] && break
    sleep 300
  done

  local to_complete=()
  [ "$DEAL_1_ACCEPTED" = "1" ] && to_complete+=("$DEAL_ID_1")
  [ "$DEAL_2_ACCEPTED" = "1" ] && to_complete+=("$DEAL_ID_2")

  if [ "${#to_complete[@]}" -eq 0 ]; then
    die "neither deal was accepted — nothing to complete. See states above."
  fi

  echo
  echo "==> Completing onboarding for accepted deal(s): ${to_complete[*]}"

  for id in "${to_complete[@]}"; do
    echo "==> Initializing deal $id (validator + FileCoinPay rail)"
    (yes 2>/dev/null || true) | client_cli init-accepted-deals "$id"
  done

  for id in "${to_complete[@]}"; do
    echo "==> Making DataCap allocations for deal $id"
    (yes 2>/dev/null || true) | client_cli make-allocations "$id"
  done

  for id in "${to_complete[@]}"; do
    echo "==> Depositing USDFC funds for deal $id"
    (yes 2>/dev/null || true) | client_cli deposit-for-deals "$id"
  done

  echo
  echo "All done. Completed deal(s): ${to_complete[*]}"
  if [ "${#to_complete[@]}" -lt 2 ]; then
    echo "The other deal was rejected/terminated and was not completed — see log above."
  fi
}

# ---------------------------------------------------------------------------

case "$MODE" in
  setup) run_setup ;;
  preview) run_preview "$@" ;;
  execute) run_execute "$@" ;;
  *) usage ;;
esac
