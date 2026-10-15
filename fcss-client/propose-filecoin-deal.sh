#!/usr/bin/env bash
# Proposes and completes TWO independent PoRep Market deals (two copies, two
# different storage-provider organizations) for a dataset already prepared
# by prepare-filecoin-dataset.sh, using
# https://github.com/fidlabs/filecoin-porep-market-tooling (pinned below).
#
# How PoRep Market v2 works (and why this script looks the way it does):
#   - `client propose-deal` matches the request against live SP offers
#     on-chain and creates the deal directly in ACCEPTED state, already
#     assigned to an SP. There is no "wait for the SP to accept" step, and
#     the client cannot pick the SP. If no offer matches, the transaction
#     reverts (NoOfferMatched) and nothing is created.
#   - The SPRegistry never matches the same SP *organization* twice for the
#     same client + manifest, so proposing the same manifest twice yields
#     two copies held by two independent organizations.
#   - After proposing, the client runs `init-deal` (validator, first-month
#     deposit, payment rail) and `make-allocations` (DataCap) per deal. Only
#     then can the SP download, seal, and claim; the deal turns ACTIVE when
#     its evidence is accepted.
#
# This script signs real mainnet transactions and moves real money. Modes:
#
#   setup    - install/verify the pinned tooling and the client wallet.
#   quote    - read-only: which SP organizations would match, and what both
#              copies cost. Includes a dry run of the real proposal.
#   execute  - propose (until two live copies exist), init-deal and
#              make-allocations for both. Resumable and safe to re-run: it
#              reads on-chain state first and only does what is missing.
#   status   - read-only: state of both copies and the FilecoinPay account.
#   fund     - deposit more months of payment into FilecoinPay.
#
# Whoever runs this (a human, or an agent on a human's behalf) must show the
# `quote` output to the account holder and get their explicit go-ahead before
# `execute` (and again before `fund`). The tooling's own per-transaction
# confirmation prompts are answered automatically here (piped "yes"), so
# nothing pauses for a second look once `execute` or `fund` starts.
set -euo pipefail

# filecoin-porep-market-tooling commit this script is written and verified
# against. Bump deliberately, after re-checking every command used below.
TOOLING_REPO="https://github.com/fidlabs/filecoin-porep-market-tooling.git"
TOOLING_REF="4c4bbbd77786aba4db652e50f873abdf6dce5938"

usage() {
  cat <<'USAGE'
Usage:
  ./propose-filecoin-deal.sh setup
  ./propose-filecoin-deal.sh quote   <deal flags>
  ./propose-filecoin-deal.sh execute <deal flags>
  ./propose-filecoin-deal.sh status  --manifest-url <url>
  ./propose-filecoin-deal.sh fund    --manifest-url <url> (--months <n> | --whole-deal)

Modes:
  setup     Clone the pinned tooling, install dependencies, check that a
            client wallet is configured. Touches nothing on-chain.
  quote     Read-only. Lists the SP organizations whose live offers match
            these terms, the expected and maximum cost of BOTH copies, and
            dry-runs the real proposal. Needs at least two matching
            organizations. Read this before ever running execute.
  execute   Proposes copies until two live copies of this manifest exist,
            then runs init-deal (validator, first-month deposit, payment
            rail) and make-allocations (DataCap) for each. Resumable: re-run
            the same command after any failure. Only run this after a human
            has seen the quote output and explicitly agreed to it.
  status    Read-only. Shows both copies' deal state, SP, organization,
            payment rail, and the FilecoinPay account balance.
  fund      Deposits enough into FilecoinPay to cover <n> months (or the
            whole deal) for ALL of this wallet's deals that are ready for
            deposit. Moves real money; needs its own explicit go-ahead.

Deal flags (quote / execute):
  --manifest-url <url>                 MANIFEST_URL from prepare-filecoin-dataset.sh.
  --deal-type <public|private>         Required, no default: always ask the client.
                                         public  = anyone can retrieve the data.
                                         private = retrieval limited to the client and
                                                   wallets it later authorizes with
                                                   `client sign-retrieval-voucher`.
  --retrievability-pct <0-100>         Retrievability guarantee. 0 = don't care.
  --bandwidth-mbps <0-64000>           Bandwidth guarantee. 0 = don't care.
  --latency-ms <n>                     Latency guarantee. 0 = don't care. Any value
                                         above 0 only matches offers that publish a
                                         latency; check `quote` before using one.
  --indexing-pct <0-100>               Optional. IPNI indexing guarantee. Default 0.
  --duration-months <n>                Storage duration. Minimum 6.
  --max-price-per-tib-per-month <dec>  Highest price the client accepts, per TiB per
                                         month, in decimal tokens (e.g. 4 or 4.5). The
                                         deal is billed at the matched offer's price,
                                         which can be lower. Applies to each copy.
  --payment-token <0x address>         Optional. Default: USDC_TOKEN from the pinned
                                         tooling config, which is USDFC on mainnet.

Requires: git, python3 (>= 3.10), curl. The client wallet (private key or
Lotus wallet) must already be configured; `setup` explains how if it isn't.
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
LOG_DIR="$SCRIPT_DIR/logs"

# ---------------------------------------------------------------------------
# Running the tooling
# ---------------------------------------------------------------------------

# Contract addresses come from the pinned .env.mainnet and are exported so
# they win over whatever an older local .env holds (python-dotenv never
# overrides variables that are already set). A .env created by an earlier
# version of this skill has an empty POREP_MARKET_VIEW_HELPER, which breaks
# every command. Secrets stay in .env, which this script never reads beyond
# checking that a wallet key name is present.
pinned_config_env() {
  local key value
  for key in FILECOIN_PAY POREP_MARKET_VIEW_HELPER USDC_TOKEN; do
    value=$(grep -E "^${key}=" "$TOOLING_DIR/.env.mainnet" | head -1 | cut -d= -f2- || true)
    [ -n "$value" ] && printf '%s=%s\n' "$key" "$value"
  done
}

# SKIP_SELF_UPDATE=true matters: before most write commands the tooling
# offers to pull a newer version of itself, and with "yes" piped in it
# would pull, print "run the command again", and exit 0 having done
# nothing, which looks exactly like success.
tooling() {
  local dry_run="$1"; shift
  local env_args=()
  local line
  while IFS= read -r line; do
    env_args+=("$line")
  done < <(pinned_config_env)

  # ${arr[@]+...}: bash 3.2 (macOS default) treats an empty array as unbound
  # under `set -u`.
  ( cd "$TOOLING_DIR" && env SKIP_SELF_UPDATE=true DRY_RUN="$dry_run" ${env_args[@]+"${env_args[@]}"} \
      "$VENV_DIR/bin/python" porep_tooling_cli.py "$@" )
}

# Read-only commands. stdin is closed so a surprise prompt fails instead of
# hanging.
cli_read() { tooling false "$@" </dev/null; }

# Transactional commands, with the tooling's confirmation prompts answered
# "yes". Plain `yes | cmd` is broken under `set -o pipefail`: `yes` is killed
# by SIGPIPE (exit 141) when cmd exits, and pipefail reports the pipeline as
# failed even though cmd succeeded, silently aborting the script.
# `(yes ... || true)` forces that stage's status to 0, so only a real failure
# in cmd trips pipefail.
cli_yes() { (yes 2>/dev/null || true) | tooling false "$@"; }
cli_yes_dry_run() { (yes 2>/dev/null || true) | tooling true "$@"; }

# Runs a transactional command with its full output shown and also kept in
# logs/, so a failure can be diagnosed afterwards.
cli_yes_logged() {
  mkdir -p "$LOG_DIR"
  local log="$LOG_DIR/$(date +%Y%m%d-%H%M%S)-$1-$2.log"
  echo "    (full output also saved to ${log#"$SCRIPT_DIR"/})"
  cli_yes "$@" 2>&1 | tee "$log"
}

# Parses the first JSON document in the tooling's output into `d`, then runs
# the given python code against it.
pyjson() {
  python3 -c '
import json, sys
s = sys.stdin.read()
starts = [p for p in (s.find("["), s.find("{")) if p >= 0]
if not starts:
    sys.exit("no JSON found in tooling output:\n" + s[-2000:])
d, _ = json.JSONDecoder().raw_decode(s[min(starts):])
exec(sys.argv[1])
' "$1"
}

# ---------------------------------------------------------------------------
# setup — pinned tooling, dependencies, wallet check. Touches nothing on-chain.
# ---------------------------------------------------------------------------

run_setup() {
  command -v git >/dev/null 2>&1 || die "git not found in PATH"
  command -v curl >/dev/null 2>&1 || die "curl not found in PATH"
  command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "python3 >= 3.10 required"

  if [ -d "$TOOLING_DIR/.git" ]; then
    if [ "$(git -C "$TOOLING_DIR" rev-parse HEAD)" != "$TOOLING_REF" ]; then
      [ -z "$(git -C "$TOOLING_DIR" status --porcelain --untracked-files=no)" ] \
        || die "$TOOLING_DIR has local modifications; refusing to switch it to the pinned version. Move it aside and re-run setup."
      echo "==> Switching filecoin-porep-market-tooling to pinned ${TOOLING_REF:0:8}"
      git -C "$TOOLING_DIR" fetch --quiet origin
      git -C "$TOOLING_DIR" -c advice.detachedHead=false checkout --quiet --detach "$TOOLING_REF"
    fi
  else
    echo "==> Cloning filecoin-porep-market-tooling (pinned ${TOOLING_REF:0:8})"
    git clone --quiet "$TOOLING_REPO" "$TOOLING_DIR"
    git -C "$TOOLING_DIR" -c advice.detachedHead=false checkout --quiet --detach "$TOOLING_REF"
  fi

  if [ ! -x "$VENV_DIR/bin/python" ]; then
    echo "==> Creating virtualenv"
    python3 -m venv "$VENV_DIR"
  fi

  echo "==> Installing dependencies"
  "$VENV_DIR/bin/python" -m pip install -q -r "$TOOLING_DIR/requirements.txt"

  if [ ! -f "$TOOLING_DIR/.env" ]; then
    cp "$TOOLING_DIR/.env.mainnet" "$TOOLING_DIR/.env"
  fi
  chmod 600 "$TOOLING_DIR/.env"

  if ! grep -qE '^CLIENT_PRIVATE_KEY=.+' "$TOOLING_DIR/.env" \
     && ! grep -qE '^CLIENT_LOTUS_WALLET=.+' "$TOOLING_DIR/.env"; then
    cat >&2 <<EOF

No client wallet is configured yet. This is required before any deal can
be proposed, since proposing and completing deals means signing real
blockchain transactions and moving real USDFC.

This script will not generate or choose a wallet for you. Set one up
yourself:

  Option A: Lotus wallet (recommended; the private key never leaves
  the wallet):
    lotus wallet new delegated
    lotus auth create-token --perm sign
    Put both in ${TOOLING_DIR}/.env as:
      CLIENT_LOTUS_WALLET=<f410 or 0x wallet address from above>
      CLIENT_LOTUS_TOKEN=<token from above>

  Option B: raw private key:
    Use any existing EVM-compatible wallet (PoRep Market runs on FEVM).
    Put its private key in ${TOOLING_DIR}/.env as:
      CLIENT_PRIVATE_KEY=0x<your 32-byte hex private key>

Either way, that address needs:
  - enough FIL to cover gas fees, and
  - enough USDFC for the first month of BOTH copies (init-deal deposits it),
    plus later monthly top-ups. This script's "quote" mode shows the amounts.

Treat ${TOOLING_DIR}/.env like a password file. Never share it or its
contents with anyone, including an AI agent. Nothing in it should ever need
to be pasted into a chat.

Once configured, re-run this script.
EOF
    exit 1
  fi

  echo "==> Verifying the wallet resolves to a usable address"
  cli_read client info --test-keys
}

ensure_setup() {
  if [ ! -x "$VENV_DIR/bin/python" ] \
     || [ "$(git -C "$TOOLING_DIR" rev-parse HEAD 2>/dev/null)" != "$TOOLING_REF" ]; then
    run_setup
  fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_decimal() { printf '%s' "$1" | grep -qE '^[0-9]+(\.[0-9]+)?$'; }

parse_deal_flags() {
  MANIFEST_URL=""; DEAL_TYPE=""; RETRIEVABILITY_PCT=""; BANDWIDTH_MBPS=""
  LATENCY_MS=""; INDEXING_PCT="0"; DURATION_MONTHS=""; MAX_PRICE_PER_TIB=""
  PAYMENT_TOKEN=""

  while [ $# -gt 0 ]; do
    [ $# -ge 2 ] || die "$1 needs a value"
    case "$1" in
      --manifest-url) MANIFEST_URL="$2" ;;
      --deal-type) DEAL_TYPE=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]') ;;
      --retrievability-pct) RETRIEVABILITY_PCT="$2" ;;
      --bandwidth-mbps) BANDWIDTH_MBPS="$2" ;;
      --latency-ms) LATENCY_MS="$2" ;;
      --indexing-pct) INDEXING_PCT="$2" ;;
      --duration-months) DURATION_MONTHS="$2" ;;
      --max-price-per-tib-per-month) MAX_PRICE_PER_TIB="$2" ;;
      --payment-token) PAYMENT_TOKEN="$2" ;;
      *) die "unknown argument: $1 (run with no arguments for usage)" ;;
    esac
    shift 2
  done

  [ -n "$MANIFEST_URL" ] || die "--manifest-url is required"
  case "$DEAL_TYPE" in
    public|private) ;;
    "") die "--deal-type is required (public or private). There is no default: ask the client which one they want." ;;
    *) die "--deal-type must be public or private (got: $DEAL_TYPE)" ;;
  esac
  is_uint "$RETRIEVABILITY_PCT" && [ "$RETRIEVABILITY_PCT" -le 100 ] \
    || die "--retrievability-pct must be an integer 0-100"
  is_uint "$BANDWIDTH_MBPS" && [ "$BANDWIDTH_MBPS" -le 64000 ] \
    || die "--bandwidth-mbps must be an integer 0-64000"
  is_uint "$LATENCY_MS" || die "--latency-ms must be a non-negative integer (0 = don't care)"
  is_uint "$INDEXING_PCT" && [ "$INDEXING_PCT" -le 100 ] \
    || die "--indexing-pct must be an integer 0-100"
  is_uint "$DURATION_MONTHS" && [ "$DURATION_MONTHS" -ge 6 ] \
    || die "--duration-months must be an integer >= 6"
  is_decimal "$MAX_PRICE_PER_TIB" \
    || die "--max-price-per-tib-per-month must be a plain decimal (e.g. 4 or 4.5)"
  python3 -c 'import sys; p = float(sys.argv[1]); sys.exit(0 if 0 < p <= 100 else 1)' "$MAX_PRICE_PER_TIB" \
    || die "--max-price-per-tib-per-month must be > 0 and <= 100 (decimal tokens per TiB per month, not smallest units)"

  if [ -z "$PAYMENT_TOKEN" ]; then
    PAYMENT_TOKEN=$(grep -E '^USDC_TOKEN=' "$TOOLING_DIR/.env.mainnet" | head -1 | cut -d= -f2-)
  fi
  printf '%s' "$PAYMENT_TOKEN" | grep -qE '^0x[0-9a-fA-F]{40}$' \
    || die "--payment-token must be a 0x address (got: $PAYMENT_TOKEN)"
}

parse_manifest_flag() {
  MANIFEST_URL=""
  [ $# -ge 2 ] && [ "$1" = "--manifest-url" ] || die "--manifest-url <url> is required"
  MANIFEST_URL="$2"
}

# The tooling fetches the manifest with redirects disabled and, on a network
# error, asks "Retry?", which piped "yes" answers forever. Checking here
# first turns both into one clear error.
check_manifest_url() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$MANIFEST_URL" || true)
  [ "$code" = "200" ] \
    || die "manifest URL must answer HTTP 200 directly, without redirects (got: ${code:-no response}): $MANIFEST_URL"
}

# ---------------------------------------------------------------------------
# On-chain lookups
# ---------------------------------------------------------------------------

# Prints one line per live copy (ACCEPTED or ACTIVE deal of this client whose
# manifest_location is MANIFEST_URL):
#   deal_id state provider_id organization rail_id validator evidence_result
# The tooling stores no state locally, and neither does this script: the
# chain is the only record of which copies exist.
list_live_copies() {
  local ids id
  ids=$(cli_read client get-deals | pyjson '
for deal in d:
    if deal["state"] in ("ACCEPTED", "ACTIVE"):
        print(deal["deal_id"])
')
  for id in $ids; do
    cli_read client get-deal "$id" | FCSS_MANIFEST_URL="$MANIFEST_URL" pyjson '
import os
url = "".join(os.environ["FCSS_MANIFEST_URL"].split())
if d["data"]["manifest_location"] == url:
    print(d["deal"]["deal_id"], d["deal"]["state"], d["deal"]["provider_id"],
          d["provider_organization_address"], d["deal"]["rail_id"],
          d["deal"]["validator_address"], d["evidence_status"]["result"])
'
  done
}

global_evidence_type() {
  cli_read client info | sed -n 's/^EVIDENCE_ADAPTER=.*(\(.*\))$/\1/p'
}

# ---------------------------------------------------------------------------
# quote — read-only matching and cost. Touches nothing on-chain.
# ---------------------------------------------------------------------------

run_quote() {
  parse_deal_flags "$@"
  ensure_setup
  check_manifest_url

  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT

  echo "==> Validating the manifest with the tooling's own checks"
  # Its only prompt is "Show manifest?"; answer no.
  printf 'no\n' | tooling false client validate-manifest "$MANIFEST_URL"

  echo "==> Reading live offers, providers, tokens, wallet and existing copies"
  curl -sf --max-time 60 "$MANIFEST_URL" > "$work/manifest.json"
  cli_read admin get-offers > "$work/offers.txt"
  cli_read admin get-sps > "$work/sps.txt"
  cli_read admin get-payment-tokens > "$work/tokens.txt"
  cli_read client get-filecoinpay-account "$PAYMENT_TOKEN" > "$work/account.txt"
  list_live_copies > "$work/copies.txt"

  echo
  if FCSS_WORK="$work" FCSS_TOKEN="$PAYMENT_TOKEN" FCSS_DURATION="$DURATION_MONTHS" \
  FCSS_MAX_PRICE="$MAX_PRICE_PER_TIB" FCSS_RET="$RETRIEVABILITY_PCT" FCSS_BW="$BANDWIDTH_MBPS" \
  FCSS_LAT="$LATENCY_MS" FCSS_IDX="$INDEXING_PCT" python3 - > "$work/quote.txt" <<'PY'
import json, os, sys
from decimal import ROUND_UP, Decimal

work = os.environ["FCSS_WORK"]

def load(name):
    s = open(os.path.join(work, name)).read()
    starts = [p for p in (s.find("["), s.find("{")) if p >= 0]
    return json.JSONDecoder().raw_decode(s[min(starts):])[0]

SECTOR = 32 * 1024 ** 3
TIB = 1024 ** 4
EPOCHS_PER_DAY = 2880

manifest = json.load(open(os.path.join(work, "manifest.json")))
size = sum(p.get("pieceSize", 0) for p in manifest[0]["pieces"])
offers, sps, tokens, account = load("offers.txt"), load("sps.txt"), load("tokens.txt"), load("account.txt")
token = os.environ["FCSS_TOKEN"].lower()
symbol, decimals = account["token"]["symbol"], int(account["token"]["decimals"])
months = int(os.environ["FCSS_DURATION"])
max_price_tib = float(os.environ["FCSS_MAX_PRICE"])
# Same conversion the tooling uses for --price-per-tib-per-month.
max_price_sector = int(max_price_tib * (10 ** decimals)) // (TIB // SECTOR)
req = dict(ret=int(os.environ["FCSS_RET"]) * 100, bw=int(os.environ["FCSS_BW"]) * 125_000,
           lat=int(os.environ["FCSS_LAT"]), idx=int(os.environ["FCSS_IDX"]))

copies = [line.split() for line in open(os.path.join(work, "copies.txt")) if line.strip()]
taken_orgs = {c[3].lower() for c in copies}
providers = {p["provider_id"]: p for p in sps}
token_cfg = {t["token_address"].lower(): t["config"] for t in tokens}

def tokens_str(wei, cents=False):
    amount = Decimal(wei) / Decimal(10 ** decimals)
    if cents:
        return f"{amount.quantize(Decimal('0.01'), rounding=ROUND_UP):f}"
    return f"{amount.normalize():f}"

def per_month(price_sector):
    # Same rounding as the tooling's calculate_deposit_amount: ceil, in smallest units.
    return -(-size * price_sector // SECTOR)

# Mirrors SPRegistry._checkOfferEligibility (porep-market v2.0.2).
eligible, reasons = [], {}
for o in offers:
    why = None
    p = providers.get(o["provider_id"])
    s, t = o["slis"], o["terms"]
    pay = next((x for x in o["payments"] if x["token"].lower() == token), None)
    cfg = token_cfg.get(token)
    days = months * 30
    if not o["active"]:
        why = "offer inactive"
    elif p is None or p["blocked"]:
        why = "provider blocked/unknown"
    elif p["paused"]:
        why = "provider paused"
    elif p["organization_address"].lower() in taken_orgs:
        why = "organization already holds a copy"
    elif size < t["min_size_bytes"] or (t["max_size_bytes"] and size > t["max_size_bytes"]):
        why = "dataset size outside offer bounds"
    elif days * EPOCHS_PER_DAY < t["min_duration_epochs"] or (t["max_duration_epochs"] and days * EPOCHS_PER_DAY > t["max_duration_epochs"]):
        why = f"duration outside offer bounds ({t['min_duration_epochs'] // EPOCHS_PER_DAY}-{t['max_duration_epochs'] // EPOCHS_PER_DAY} days)"
    elif req["ret"] and s["retrievability_bps"] < req["ret"]:
        why = f"retrievability {s['retrievability_bps'] / 100:g}% < required"
    elif req["bw"] and s["bandwidth_bytes_per_second"] < req["bw"]:
        why = f"bandwidth {s['bandwidth_bytes_per_second'] / 125_000:g} Mbps < required"
    elif req["lat"] and (s["latency_ms"] == 0 or s["latency_ms"] > req["lat"]):
        why = "offer publishes no latency" if s["latency_ms"] == 0 else f"latency {s['latency_ms']} ms > required"
    elif req["idx"] and s["indexing_pct"] < req["idx"]:
        why = f"indexing {s['indexing_pct']}% < required"
    elif not cfg or not cfg["allowed"] or not pay or not pay["active"]:
        why = f"does not accept {symbol}"
    elif pay["price_per_32_gib_per_month"] < max(cfg["min_price_per_32_gib_per_month"], 1):
        why = "price below token minimum"
    elif pay["price_per_32_gib_per_month"] > max_price_sector:
        why = f"price {tokens_str(pay['price_per_32_gib_per_month'] * 32)} {symbol}/TiB/month > your max"
    elif p["available_bytes"] - p["committed_bytes"] - p["pending_bytes"] < size:
        why = "not enough free capacity"
    if why:
        reasons.setdefault(why, []).append(f"{o['provider_id']}#{o['offer_id']}")
    else:
        eligible.append((pay["price_per_32_gib_per_month"], p["organization_address"], o["provider_id"], o["offer_id"]))

print(f"Dataset: {size / TIB:.4f} TiB ({size / SECTOR:.2f} sectors of 32 GiB), from {len(manifest[0]['pieces'])} pieces")
print(f"Terms per copy: retrievability {os.environ['FCSS_RET']}%, bandwidth {os.environ['FCSS_BW']} Mbps, "
      f"latency {os.environ['FCSS_LAT'] or 0} ms, indexing {os.environ['FCSS_IDX']}%, {months} months, "
      f"max {max_price_tib:g} {symbol}/TiB/month")
print()

if copies:
    print(f"Live copies of this manifest already on-chain: {len(copies)}")
    for c in copies:
        print(f"  deal {c[0]}: {c[1]}, provider {c[2]}, organization {c[3]}")
    print()

best_by_org = {}
for price, org, prov, offer_id in sorted(eligible):
    best_by_org.setdefault(org.lower(), (price, org, prov, offer_id))
ranked = sorted(best_by_org.values())
needed = max(0, 2 - len(copies))

print(f"Organizations that can take a new copy under these terms: {len(ranked)}")
for price, org, prov, offer_id in ranked:
    print(f"  {org}  cheapest: provider {prov} offer {offer_id} at {tokens_str(price * 32)} {symbol}/TiB/month")
if reasons:
    print("Offers that do not match, and why:")
    for why, which in sorted(reasons.items()):
        print(f"  {why}: {', '.join(which)}")
print()

if len(ranked) < needed:
    print(f"RESULT: NOT ENOUGH MATCHES. {needed} more cop{'y' if needed == 1 else 'ies'} needed, only {len(ranked)} organization(s) match.")
    print("Proposing now would fail (NoOfferMatched) for at least one copy. Adjust the terms using the reasons above")
    print("(most often: latency_ms must be 0, or the max price is below what a second organization charges).")
    print("QUOTE_OK=false")
    sys.exit(0)

if needed == 0:
    print("RESULT: two live copies already exist; execute will only finish init-deal / make-allocations for them.")
    print("QUOTE_OK=true")
    sys.exit(0)

# The registry picks among offers within 1% of the cheapest, preferring the
# least-loaded provider, so the expected price is the cheapest per organization.
expected_month = sum(per_month(r[0]) for r in ranked[:needed])
max_month = per_month(max_price_sector) * needed
balance = Decimal(account["token"]["balance"].split()[0])
print(f"Cost for the {needed} new cop{'y' if needed == 1 else 'ies'} (each billed at its matched offer's price):")
print(f"  expected: ~{tokens_str(expected_month, True)} {symbol}/month, ~{tokens_str(expected_month * months, True)} {symbol} over {months} months")
print(f"  ceiling:   {tokens_str(max_month, True)} {symbol}/month,  {tokens_str(max_month * months, True)} {symbol} over {months} months (at your max price)")
print(f"  due up front: the first month of each copy, deposited by init-deal (up to {tokens_str(max_month, True)} {symbol});")
print( "  later months must be topped up with `fund` before the deposit runs out.")
print(f"Wallet {account['owner']}: {balance:f} {symbol}. Also needs FIL for gas.")
if balance * 10 ** decimals < max_month:
    print(f"WARNING: the wallet holds less than the up-front deposit (up to {tokens_str(max_month, True)} {symbol}). "
          f"init-deal will refuse to run for a copy it cannot fund.")
print("QUOTE_OK=true")
PY
  then
    cat "$work/quote.txt"
  else
    cat "$work/quote.txt"
    die "could not compute the quote (see above)"
  fi
  if grep -q '^QUOTE_OK=false' "$work/quote.txt"; then
    exit 1
  fi

  echo
  local copies_count
  copies_count=$(grep -c . "$work/copies.txt" || true)
  if [ "$copies_count" -lt 2 ]; then
    echo "==> Dry run of the next real proposal (nothing is sent)"
    if ! cli_yes_dry_run client propose-deal "$MANIFEST_URL" \
        --price-per-tib-per-month "$MAX_PRICE_PER_TIB" \
        --duration-months "$DURATION_MONTHS" \
        --payment-token "$PAYMENT_TOKEN" \
        --deal-type "$DEAL_TYPE" \
        --retrievability-pct "$RETRIEVABILITY_PCT" \
        --bandwidth-mbps "$BANDWIDTH_MBPS" \
        --latency-ms "$LATENCY_MS" \
        --indexing-pct "$INDEXING_PCT" > "$work/dry-run.txt" 2>&1; then
      tail -20 "$work/dry-run.txt"
      echo
      echo "The dry run FAILED: the next proposal would not go through as specified. See the error above."
      exit 1
    fi
    grep -E 'This will cost you|Found [0-9]+ data piece|evidence adapter' "$work/dry-run.txt" || true
    echo "Dry run OK. (The tooling's figures above are for ONE copy at your max price.)"
  fi

  echo
  echo "Nothing has been proposed. Re-run with 'execute' (same flags) only after"
  echo "a human has reviewed this and explicitly agreed to it."
}

# ---------------------------------------------------------------------------
# execute — propose until two live copies exist, then init + allocate both.
# Resumable: every step checks on-chain state first.
# ---------------------------------------------------------------------------

run_execute() {
  parse_deal_flags "$@"
  ensure_setup
  check_manifest_url

  local copies count before attempt
  copies=$(list_live_copies)
  count=$(printf '%s\n' "$copies" | grep -c . || true)

  attempt=0
  while [ "$count" -lt 2 ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -le 2 ] || die "proposed twice but still see only $count live copies. Check 'status' before doing anything else."
    echo "==> Proposing copy $((count + 1)) of 2"
    before=$count
    cli_yes_logged client propose-deal "$MANIFEST_URL" \
      --price-per-tib-per-month "$MAX_PRICE_PER_TIB" \
      --duration-months "$DURATION_MONTHS" \
      --payment-token "$PAYMENT_TOKEN" \
      --deal-type "$DEAL_TYPE" \
      --retrievability-pct "$RETRIEVABILITY_PCT" \
      --bandwidth-mbps "$BANDWIDTH_MBPS" \
      --latency-ms "$LATENCY_MS" \
      --indexing-pct "$INDEXING_PCT" \
      || die "proposing copy $((count + 1)) failed (see output above). NoOfferMatched means no remaining organization matches these terms: run 'quote' again. Copies already created are kept; re-running execute resumes."
    copies=$(list_live_copies)
    count=$(printf '%s\n' "$copies" | grep -c . || true)
    [ "$count" -gt "$before" ] \
      || die "the proposal reported success but no new live copy is visible on-chain. Check 'status' before retrying."
  done

  if [ "$count" -gt 2 ]; then
    echo "NOTE: $count live deals already reference this manifest URL. All of them are completed below; review them with 'status'."
  fi

  local orgs distinct_orgs
  orgs=$(printf '%s\n' "$copies" | awk 'NF {print tolower($4)}')
  distinct_orgs=$(printf '%s\n' "$orgs" | sort -u | grep -c . || true)
  if [ "$distinct_orgs" -lt "$count" ]; then
    die "two live copies are held by the same SP organization, so they are not independent. This can only happen if the manifest at this URL changed between proposals. Stop and review with 'status'."
  fi

  echo
  echo "Live copies:"
  printf '%s\n' "$copies" | awk 'NF {printf "  deal %s: %s, provider %s, organization %s\n", $1, $2, $3, $4}'

  local evidence_type id
  evidence_type=$(global_evidence_type)

  for id in $(printf '%s\n' "$copies" | awk 'NF && $2 == "ACCEPTED" {print $1}'); do
    echo
    echo "==> init-deal $id (validator, first-month deposit, payment rail)"
    cli_yes_logged client init-deal "$id" \
      || die "init-deal $id failed (see output above). Fix the cause (often: not enough ${PAYMENT_TOKEN} balance or FIL for gas), then re-run execute."

    if [ "$evidence_type" = "SECTOR_PLACEMENT" ]; then
      echo "    Market uses SECTOR_PLACEMENT evidence: no DataCap allocations for deal $id."
      continue
    fi
    echo "==> make-allocations $id (DataCap)"
    cli_yes_logged client make-allocations "$id" \
      || die "make-allocations $id failed (see output above). Re-running execute resumes from the remaining batches."
  done

  echo
  echo "==================================================================="
  echo "Client side complete for both copies. Each SP must now download,"
  echo "seal, and claim its copy; the deal turns ACTIVE when that lands."
  echo "The SPs run their own tooling. Send each one its deal ID and this:"
  echo
  printf '%s\n' "$copies" | awk 'NF {print $1, $3}' | while read -r id provider; do
    echo "  Deal $id (provider $provider):"
    if [ "$evidence_type" = "SECTOR_PLACEMENT" ]; then
      echo "    python3 porep_tooling_cli.py sp onboard-data $id --output-dir <dir> --port 443"
      echo "    python3 porep_tooling_cli.py sp get-piece-notifications $id"
    else
      echo "    python3 porep_tooling_cli.py sp onboard-data $id --output-dir <dir> --port 443 --claim-allocations <curio|boost>"
    fi
  done
  echo
  echo "--port 443 is required because pieces are served from a public HTTPS"
  echo "bucket, and onboard-data always appends a port (default 7777), even with"
  echo "--host. DataCap allocations expire about 30 days after make-allocations,"
  echo "so the SPs should start promptly."
  echo
  echo "Track progress with:"
  echo "  ./propose-filecoin-deal.sh status --manifest-url $MANIFEST_URL"
  echo "init-deal deposited the first month of each copy. Top up later months with 'fund'."
  echo "==================================================================="
}

# ---------------------------------------------------------------------------
# status — read-only.
# ---------------------------------------------------------------------------

run_status() {
  parse_manifest_flag "$@"
  ensure_setup

  local copies id
  copies=$(list_live_copies)
  if [ -z "$copies" ]; then
    echo "No live (ACCEPTED/ACTIVE) deals of this wallet reference $MANIFEST_URL"
    return 0
  fi

  local token account symbol decimals
  token=$(cli_read client get-deal "$(printf '%s\n' "$copies" | awk 'NF {print $1; exit}')" \
    | pyjson 'print(d["payment"]["payment_token"])')
  account=$(cli_read client get-filecoinpay-account "$token")
  symbol=$(printf '%s' "$account" | pyjson 'print(d["token"]["symbol"])')
  decimals=$(printf '%s' "$account" | pyjson 'print(d["token"]["decimals"])')

  for id in $(printf '%s\n' "$copies" | awk 'NF {print $1}'); do
    cli_read client get-deal "$id" | FCSS_SYMBOL="$symbol" FCSS_DECIMALS="$decimals" pyjson '
import os
from decimal import Decimal
dl, ev, pay = d["deal"], d["evidence_status"], d["payment"]
per_tib = Decimal(pay["price_per_32_gib_per_month"] * 32) / Decimal(10 ** int(os.environ["FCSS_DECIMALS"]))
print("Deal %s: %s (%s)" % (dl["deal_id"], dl["state"], dl["deal_type"]))
print("  provider %s, organization %s" % (dl["provider_id"], d["provider_organization_address"]))
print("  payment rail: %s, validator: %s" % (dl["rail_id"] or "not initialized", dl["validator_address"]))
print("  price: %s %s/TiB/month" % (format(per_tib.normalize(), "f"), os.environ["FCSS_SYMBOL"]))
print("  evidence: %s, %s of %s bytes covered" % (ev["result"], ev["active_covered_bytes"], d["terms"]["requested_size_bytes"]))
'
  done

  echo
  echo "FilecoinPay account:"
  printf '%s' "$account" | pyjson '
print("  wallet %s holds %s" % (d["owner"], d["token"]["balance"]))
print("  FilecoinPay funds: %s (lockup: %s smallest units)" % (d["account"]["funds"], d["account"]["account"].get("lockup_current")))
'
}

# ---------------------------------------------------------------------------
# fund — deposit more months. Moves real money.
# ---------------------------------------------------------------------------

run_fund() {
  [ $# -ge 2 ] && [ "$1" = "--manifest-url" ] || die "--manifest-url <url> is required"
  MANIFEST_URL="$2"; shift 2
  local months=""
  case "${1:-}" in
    --months) [ $# -ge 2 ] || die "--months needs a value"; months="$2" ;;
    --whole-deal) months="whole" ;;
    *) die "pass --months <n> or --whole-deal" ;;
  esac
  ensure_setup

  local copies first
  copies=$(list_live_copies)
  [ -n "$copies" ] || die "no live deals of this wallet reference $MANIFEST_URL"

  if [ "$months" = "whole" ]; then
    first=$(printf '%s\n' "$copies" | awk 'NF {print $1; exit}')
    months=$(cli_read client get-deal "$first" | pyjson 'print(d["terms"]["duration_epochs"] // 86400)')
  fi
  is_uint "$months" && [ "$months" -ge 1 ] || die "--months must be a positive integer"

  echo "==> Depositing enough to cover $months month(s) for every deal of this wallet that is ready for deposit"
  echo "    (a deal is ready once init-deal ran and, for DataCap deals, make-allocations finished)."
  cli_yes_logged client deposit-for-deals --months "$months" \
    || die "deposit failed (see output above)"
}

# ---------------------------------------------------------------------------

case "$MODE" in
  setup) run_setup ;;
  quote) run_quote "$@" ;;
  execute) run_execute "$@" ;;
  status) run_status "$@" ;;
  fund) run_fund "$@" ;;
  *) usage ;;
esac
