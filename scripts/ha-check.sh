#!/usr/bin/env sh
# ha-check.sh — HA validation measured from the "client" (the repo manager):
# continuous traffic during a rollout + policy comparison between clusters.
# Turns the design's HA promise (rolling restart with no effective downtime)
# into measurable, repeatable evidence.
#
# Two modes:
#
# 1. TRAFFIC DURING ROLLOUT (default): sends authenticated GETs every 100 ms
#    against the endpoint the repo manager consumes (GET /left-pad with basic
#    auth) while triggering the restart with --restart-cmd (which runs in
#    BACKGROUND so measurement never stops during the cutover). Sequence:
#      1. 10 s of baseline (all 2xx or abort: the target is not healthy)
#      2. trigger the restart (kubectl rollout restart, docker restart, …
#         or omit --restart-cmd for a pure baseline measurement)
#      3. keep measuring until DURATION (TOTAL window, baseline included)
#      4. success criterion: 0 non-2xx across the whole window
#    A 502/503 during the rollout = the LB drains badly → FINDING (document
#    it in docs/ha-validation.md), not a script failure.
#
# 2. --compare-policy: asserts that both clusters serve THE SAME policy by
#    comparing presence/absence of specific versions — NEVER version counts
#    between instances (there is maxage skew with independent caches;
#    architecture, consistency #5):
#      - stable old version (lodash 4.17.21) present in BOTH
#      - young version (discovered on npmjs, like canary.sh) absent in BOTH
#
# Usage (secrets ALWAYS via env, never via args):
#   REGISTRY_URL=http://<LB> SERVICE_USER=... SERVICE_PASS=... [DURATION=120] \
#     ./scripts/ha-check.sh --restart-cmd 'kubectl rollout restart deploy/x'
#   REGISTRY_URL_A=http://... REGISTRY_URL_B=http://... \
#     SERVICE_USER=... SERVICE_PASS=... ./scripts/ha-check.sh --compare-policy
#
# Env (traffic mode):
#   REGISTRY_URL    proxy endpoint (LB in prod, local stack in dev)
#   SERVICE_USER    service account (basic auth)
#   SERVICE_PASS    account password
#   DURATION        TOTAL measurement window in s, baseline included (default 120)
#   --restart-cmd   command that restarts the target instance (runs in
#                   background during the measurement); empty/omitted = pure baseline
#
# Env (--compare-policy):
#   REGISTRY_URL_A/B  DIRECT endpoint of each cluster (if not reachable,
#                     via the LB in separate windows)
#   SERVICE_USER/PASS service account (basic auth)
#   CONFIG_FILE       source of minAgeDays (default: conf/config.yaml from the repo)
#   CANDIDATES        packages to search for a young version (default canary.sh)
#
# Exit codes: 0 = PASS (or justified skip) · 1 = measurable failure/assert ·
#             2 = bad config (incomplete or invalid env).
# Deps: curl, jq and GNU date/sleep (timestamps and pacing in ms).
# Stateless: writes only to its own mktemp (cleaned up on exit).
set -eu

PROGNAME="${0##*/}"
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

log() { echo "ha-check: $*"; }
err_config() { printf '%s: ERROR: %s\n' "$PROGNAME" "$1" >&2; exit 2; }

usage() {
  cat <<EOF
Usage:
  # Traffic mode: is there any downtime visible to the client during a rollout?
  env REGISTRY_URL=<url> SERVICE_USER=<u> SERVICE_PASS=<p> [DURATION=120] \\
      $PROGNAME [--restart-cmd '<command that restarts the instance>']

  # Compare policy between clusters (presence/absence, NOT counts):
  env REGISTRY_URL_A=<urlA> REGISTRY_URL_B=<urlB> \\
      SERVICE_USER=<u> SERVICE_PASS=<p> $PROGNAME --compare-policy

Traffic mode (default)
  Simulates the repo manager: GET /left-pad with basic auth every 100 ms
  (5 s timeout per request). Sequence: 10 s of baseline (all 2xx or abort)
  -> trigger --restart-cmd in BACKGROUND -> keep measuring until DURATION
  (TOTAL window including the baseline). Success criterion: 0 non-2xx.
  Per-request record: timestamp, http_code, latency_ms (curl -w). Report:
  total, 2xx, non-2xx, p50/p95/max (jq, over the 2xx) and first 10 errors
  with timestamp. Without --restart-cmd: pure baseline measurement (no
  rollout).

  DURATION      Total measurement window in seconds (default: 120). Must
                be > 10 s (the baseline).
  --restart-cmd Command that restarts the target instance. E.g.:
                  'kubectl rollout restart deployment/vmp-a-verdaccio'
                  'docker restart <container>'
                Runs in background: measurement does NOT pause while the
                command blocks. The script waits for it at the end.

--compare-policy mode
  Same policy on both clusters, compared by presence/absence of specific
  versions (never counts: maxage skew between independent caches):
    - lodash@4.17.21 (stable old version) PRESENT in the packument of BOTH
    - 1 young version (< minAgeDays, discovered on npmjs like canary.sh)
      ABSENT from the packument of BOTH (justified skip if there is none)

Environment variables:
  Required (traffic mode): REGISTRY_URL, SERVICE_USER, SERVICE_PASS
  Required (--compare-policy): REGISTRY_URL_A, REGISTRY_URL_B,
                SERVICE_USER, SERVICE_PASS
  Optional: DURATION (120), CONFIG_FILE (conf/config.yaml — source of
                minAgeDays), CANDIDATES ("typescript @types/node esbuild
                vite" — young version search)

Examples:
  # manual rollout on the clusters (series A -> B):
  REGISTRY_URL=https://lb.internal SERVICE_USER=u SERVICE_PASS=p DURATION=90 \\
    $PROGNAME --restart-cmd 'kubectl rollout restart deployment/vmp-a-verdaccio && \\
    kubectl rollout status deployment/vmp-a-verdaccio && \\
    kubectl rollout restart deployment/vmp-b-verdaccio && \\
    kubectl rollout status deployment/vmp-b-verdaccio'

  # local functional validation (compose stack, no LB):
  REGISTRY_URL=http://localhost:4873 SERVICE_USER=u SERVICE_PASS=p DURATION=25 \\
    $PROGNAME --restart-cmd 'docker restart <another-instance>'

  REGISTRY_URL_A=http://a:4873 REGISTRY_URL_B=http://b:4873 \\
    SERVICE_USER=u SERVICE_PASS=p $PROGNAME --compare-policy

Exit codes: 0 = PASS (or justified skip) · 1 = measurable failure/assert ·
            2 = bad config.
EOF
}

MODE=traffic
RESTART_CMD=''
while [ $# -gt 0 ]; do
  case "$1" in
    --compare-policy) MODE=compare ;;
    --restart-cmd)
      [ $# -ge 2 ] || err_config "--restart-cmd requires an argument (see --help)"
      RESTART_CMD=$2
      shift
      ;;
    -h | --help) usage; exit 0 ;;
    *) err_config "unsupported argument: $1 (see --help)" ;;
  esac
  shift
done

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || err_config "missing dependency: $dep"
done

TMP_WORK=$(mktemp -d)
trap 'rm -rf "$TMP_WORK"' EXIT INT TERM

# normalize_url <value> — prints the value without trailing slashes.
normalize_url() {
  while :; do
    case $1 in
      */) set -- "${1%/}" ;;
      *) printf '%s' "$1"; return ;;
    esac
  done
}

if [ "$MODE" = traffic ]; then
  # ---------------------------------------------------------------- traffic --
  [ -n "${REGISTRY_URL:-}" ] || err_config "REGISTRY_URL is required (see --help)"
  [ -n "${SERVICE_USER:-}" ] || err_config "SERVICE_USER is required (see --help)"
  [ -n "${SERVICE_PASS:-}" ] || err_config "SERVICE_PASS is required (see --help)"
  REGISTRY_URL=$(normalize_url "$REGISTRY_URL")
  DURATION="${DURATION:-120}"
  case $DURATION in
    '' | *[!0-9]*) err_config "invalid DURATION='$DURATION' (expected integer seconds)" ;;
  esac
  [ "$DURATION" -gt 10 ] || err_config "DURATION must be > 10s (baseline included)"

  BASELINE_SECS=10
  REQUEST_INTERVAL_MS=100
  REQUEST_TIMEOUT_S=5
  URL="$REGISTRY_URL/left-pad"
  LOG="$TMP_WORK/traffic.log"
  RESTART_LOG="$TMP_WORK/restart.log"
  : > "$LOG"

  # do_request — 1 authenticated GET; logs "ts_iso8601 http_code latency_ms".
  # 000 = curl could not complete (conn refused, timeout >5s, …) = error.
  do_request() {
    _ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    _out=$(curl -sS -o /dev/null --max-time "$REQUEST_TIMEOUT_S" \
      -w '%{http_code} %{time_total}' \
      -u "$SERVICE_USER:$SERVICE_PASS" "$URL" 2>/dev/null) || :
    _code=${_out%% *}
    _lat=${_out##* }
    case $_code in
      '' | *[!0-9]*) _code=000; _lat=0 ;;
    esac
    _lat_ms=$(awk -v t="$_lat" 'BEGIN{printf "%.0f", t*1000}')
    printf '%s %s %s\n' "$_ts" "$_code" "$_lat_ms" >> "$LOG"
  }

  # run_traffic_phase <seconds> — one request every REQUEST_INTERVAL_MS (slot
  # pacing: if a request takes longer than its slot, the next one leaves at once).
  run_traffic_phase() {
    _end_ms=$(($(date +%s%3N) + $1 * 1000))
    while [ "$(date +%s%3N)" -lt "$_end_ms" ]; do
      _slot_ms=$(date +%s%3N)
      do_request
      _rem=$((_slot_ms + REQUEST_INTERVAL_MS - $(date +%s%3N)))
      if [ "$_rem" -gt 0 ] && [ "$_rem" -lt 1000 ]; then
        sleep "0.$(printf '%03d' "$_rem")"
      fi
    done
  }

  log "target: $URL (auth, 1 request/${REQUEST_INTERVAL_MS}ms, timeout ${REQUEST_TIMEOUT_S}s)"
  log "phase 1/3: baseline ${BASELINE_SECS}s (all 2xx or abort)"

  run_traffic_phase "$BASELINE_SECS"

  baseline_total=$(awk 'END{print NR}' "$LOG")
  baseline_errs=$(awk '$2 !~ /^2/ {n++} END{print n + 0}' "$LOG")
  if [ "$baseline_errs" -gt 0 ]; then
    printf 'ha-check: ERROR: baseline with %s non-2xx of %s requests — target not healthy BEFORE the rollout:\n' \
      "$baseline_errs" "$baseline_total" >&2
    awk '$2 !~ /^2/ {printf "  %s  HTTP %s  %s ms\n", $1, $2, $3}' "$LOG" | head -n 10 >&2
    printf 'ha-check: FAIL — fix the target before measuring HA (broken deploy? wrong URL/creds?)\n' >&2
    exit 1
  fi
  log "baseline OK: $baseline_total requests, 0 non-2xx"

  RESTART_PID=''
  if [ -n "$RESTART_CMD" ]; then
    log "phase 2/3: triggering restart (background): $RESTART_CMD"
    sh -c "$RESTART_CMD" > "$RESTART_LOG" 2>&1 &
    RESTART_PID=$!
  else
    log "phase 2/3: no --restart-cmd — pure baseline (no rollout triggered)"
  fi

  log "phase 3/3: measuring until DURATION=${DURATION}s total"
  run_traffic_phase $((DURATION - BASELINE_SECS))

  RESTART_RC=0
  if [ -n "$RESTART_PID" ]; then
    wait "$RESTART_PID" || RESTART_RC=$?
  fi

  # ---- report (one jq pass over the full log) ---------------------------------
  SUMMARY="$TMP_WORK/summary.json"
  jq -Rn '
    [ inputs
    | select(length > 0)
    | split(" ")
    | {ts: .[0], code: .[1], lat: (.[2] | tonumber)}
    ] as $r
    | [ $r[] | select(.code | test("^2")) ] as $ok
    | ( [ $ok[].lat ] | sort ) as $s
    | ($r | length) as $total
    | ($ok | length) as $n_ok
    | (if $n_ok > 0 then (((0.50 * $n_ok) | ceil) - 1) else null end) as $i50
    | (if $n_ok > 0 then (((0.95 * $n_ok) | ceil) - 1) else null end) as $i95
    | {
        total: $total,
        ok: $n_ok,
        err: ($total - $n_ok),
        err_lb: ([$r[] | select(.code == "502" or .code == "503")] | length),
        p50: (if $i50 != null then $s[$i50] else null end),
        p95: (if $i95 != null then $s[$i95] else null end),
        max: (if $n_ok > 0 then $s[$n_ok - 1] else null end)
      }
  ' "$LOG" > "$SUMMARY"

  TOTAL=$(jq -r .total "$SUMMARY")
  OK=$(jq -r .ok "$SUMMARY")
  ERR=$(jq -r .err "$SUMMARY")
  ERR_LB=$(jq -r .err_lb "$SUMMARY")
  P50=$(jq -r .p50 "$SUMMARY")
  P95=$(jq -r .p95 "$SUMMARY")
  MAXLAT=$(jq -r .max "$SUMMARY")

  if [ -n "$RESTART_CMD" ]; then
    RESTART_LINE="$RESTART_CMD (rc=$RESTART_RC)"
  else
    RESTART_LINE="(none — pure baseline)"
  fi

  SEP='--------------------------------------------------------------'
  printf '\n================ ha-check: traffic report ================\n'
  printf 'target          %s\n' "$URL"
  printf 'window          %ss (baseline %ss + %ss of measurement)\n' \
    "$DURATION" "$BASELINE_SECS" "$((DURATION - BASELINE_SECS))"
  printf 'restart-cmd     %s\n' "$RESTART_LINE"
  printf '%s\n' "$SEP"
  printf 'requests        %s\n' "$TOTAL"
  printf '2xx             %s\n' "$OK"
  printf 'non-2xx         %s\n' "$ERR"
  if [ "$OK" -gt 0 ]; then
    printf 'latency 2xx     p50=%sms p95=%sms max=%sms\n' "$P50" "$P95" "$MAXLAT"
  else
    printf 'latency 2xx     n/a (0 2xx requests)\n'
  fi
  printf 'first errors (max 10):\n'
  if [ "$ERR" -eq 0 ]; then
    printf '  (none)\n'
  else
    awk '$2 !~ /^2/ {printf "  %s  HTTP %s  %s ms\n", $1, $2, $3}' "$LOG" | head -n 10
    if [ "$ERR" -gt 10 ]; then
      printf '  … and %s more\n' "$((ERR - 10))"
    fi
  fi
  printf '%s\n' "$SEP"
  if [ -n "$RESTART_PID" ] && [ "$RESTART_RC" -ne 0 ]; then
    printf 'VERDICT         FAIL — restart command failed (rc=%s); the window does not validate a real rollout\n' \
      "$RESTART_RC"
    printf 'command output:\n'
    tail -n 10 "$RESTART_LOG" | sed 's/^/  /'
    exit 1
  fi

  if [ "$ERR" -eq 0 ]; then
    if [ -n "$RESTART_PID" ]; then
      VERDICT_MSG='rolling restart with no downtime (HA promise verified)'
    else
      VERDICT_MSG='stable baseline (no rollout triggered)'
    fi
    printf 'VERDICT         PASS — 0 non-2xx in %s requests: %s\n' "$TOTAL" "$VERDICT_MSG"
    exit 0
  fi

  printf 'VERDICT         FAIL — %s non-2xx of %s requests visible to the client\n' "$ERR" "$TOTAL"
  if [ "$ERR_LB" -gt 0 ]; then
    printf 'FINDING         %s x 502/503: the LB is not draining properly (readiness /-ping) — see docs/ha-validation.md §Findings\n' "$ERR_LB"
  fi
  exit 1
fi

# ---------------------------------------------------------------- compare ----
[ -n "${REGISTRY_URL_A:-}" ] || err_config "REGISTRY_URL_A is required (see --help)"
[ -n "${REGISTRY_URL_B:-}" ] || err_config "REGISTRY_URL_B is required (see --help)"
[ -n "${SERVICE_USER:-}" ] || err_config "SERVICE_USER is required (see --help)"
[ -n "${SERVICE_PASS:-}" ] || err_config "SERVICE_PASS is required (see --help)"
REGISTRY_URL_A=$(normalize_url "$REGISTRY_URL_A")
REGISTRY_URL_B=$(normalize_url "$REGISTRY_URL_B")
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../conf/config.yaml}"
CANDIDATES="${CANDIDATES:-typescript @types/node esbuild vite}"
NPMJS_URL="https://registry.npmjs.org"
OLD_PKG=lodash
OLD_VER=4.17.21
# Same anti-flapping boundary margin as canary.sh.
BOUNDARY_MARGIN_DAYS=0.05

# Window ALWAYS read from the config (source of truth, not hardcoded).
[ -r "$CONFIG_FILE" ] || err_config "cannot read CONFIG_FILE=$CONFIG_FILE"
if command -v yq >/dev/null 2>&1; then
  MIN_AGE_DAYS=$(yq '.filters."@verdaccio/package-filter".minAgeDays' "$CONFIG_FILE")
else
  MIN_AGE_DAYS=$(grep -E '^[[:space:]]*minAgeDays:[[:space:]]*[0-9]+' "$CONFIG_FILE" \
    | head -n 1 | tr -dc '0-9')
fi
case $MIN_AGE_DAYS in
  '' | *[!0-9]*) err_config "invalid minAgeDays='$MIN_AGE_DAYS' in $CONFIG_FILE" ;;
esac
CUTOFF=$(awk -v m="$MIN_AGE_DAYS" -v g="$BOUNDARY_MARGIN_DAYS" 'BEGIN{printf "%.4f", m - g}')

BODY_FILE="$TMP_WORK/body"

# fetch <url> — GET with basic auth; leaves the status in CODE (000 if curl
# cannot connect) and the body in $BODY_FILE.
fetch() {
  : > "$BODY_FILE"
  CODE=$(curl -sS --compressed --max-time 120 -o "$BODY_FILE" -w '%{http_code}' \
    -u "$SERVICE_USER:$SERVICE_PASS" "$1") || CODE=000
}

# --- discovery of 1 young version on npmjs (canary.sh pattern) -----------------
NOW=$(date -u +%s)
log "quarantine window: minAgeDays=$MIN_AGE_DAYS (from $CONFIG_FILE)"
log "A=$REGISTRY_URL_A  B=$REGISTRY_URL_B"
log "discovering a version younger than ${MIN_AGE_DAYS}d among: $CANDIDATES"

YOUNG_PKG=''
YOUNG_VER=''
YOUNG_AGE=''
# shellcheck disable=SC2086  # intentional word-splitting: CANDIDATES is a list
for pkg in $CANDIDATES; do
  code=$(curl -sS --compressed --max-time 120 -o "$TMP_WORK/npmjs-packument" \
    -w '%{http_code}' "$NPMJS_URL/$pkg") || code=000
  if [ "$code" != "200" ]; then
    log "  $pkg: npmjs packument HTTP $code — skipped"
    continue
  fi
  row=$(jq -r --argjson now "$NOW" '
    def ts: sub("\\.[0-9]+"; "") | fromdateiso8601?;
    .time | to_entries
    | map(select(.key != "created" and .key != "modified"))
    | map(select(.value | ts))
    | max_by(.value | ts)
    | select(. != null)
    | [ .key, .value, ((($now - (.value | ts)) / 86400 * 100 | floor) / 100) ]
    | @tsv' "$TMP_WORK/npmjs-packument" 2>/dev/null) || row=''
  if [ -z "$row" ]; then
    log "  $pkg: no parseable release times — skipped"
    continue
  fi
  ver=$(printf '%s\n' "$row" | cut -f1)
  age=$(printf '%s\n' "$row" | cut -f3)
  if [ "$(awk -v a="$age" -v c="$CUTOFF" 'BEGIN{print (a < c) ? "yes" : "no"}')" = yes ]; then
    YOUNG_PKG=$pkg
    YOUNG_VER=$ver
    YOUNG_AGE=$age
    break
  fi
  log "  $pkg: newest $ver is ${age}d old — outside window"
done

if [ -n "$YOUNG_PKG" ]; then
  log "young version: $YOUNG_PKG@$YOUNG_VER (age ${YOUNG_AGE}d < ${MIN_AGE_DAYS}d)"
else
  log "no young version available (window ok) — young assert skipped, old assert still runs"
fi

FAILED=0
RESULTS=''
record() { # desc expected got status
  RESULTS="$RESULTS$1|$2|$3|$4
"
}
fail_msg() { printf '         %s\n' "$1"; }

# check_old <label> <url> — stable old version PRESENT in the packument
# (positive control: the proxy serves, does not over-block).
check_old() {
  fetch "$2/$OLD_PKG"
  if [ "$CODE" = 200 ]; then
    has=$(jq -r --arg v "$OLD_VER" '.versions | has($v)' "$BODY_FILE" 2>/dev/null) || has=unparseable
    if [ "$has" = true ]; then
      record "$1: $OLD_PKG@$OLD_VER present" present present PASS
    else
      record "$1: $OLD_PKG@$OLD_VER present" present "$has" FAIL
      FAILED=$((FAILED + 1))
      fail_msg "expected $OLD_VER PRESENT in packument, got: $has — proxy over-blocking or broken?"
    fi
  else
    record "$1: $OLD_PKG@$OLD_VER present" '200+present' "$CODE" FAIL
    FAILED=$((FAILED + 1))
    fail_msg "expected HTTP 200 (lodash packument), got $CODE"
  fi
}

# check_young <label> <url> — young version ABSENT from the packument
# (serve-time quarantine applied). Compares presence/absence, NOT counts
# (maxage skew).
check_young() {
  fetch "$2/$YOUNG_PKG"
  if [ "$CODE" = 200 ]; then
    has=$(jq -r --arg v "$YOUNG_VER" '.versions | has($v)' "$BODY_FILE" 2>/dev/null) || has=unparseable
    if [ "$has" = false ]; then
      record "$1: $YOUNG_PKG@$YOUNG_VER absent" absent absent PASS
    else
      record "$1: $YOUNG_PKG@$YOUNG_VER absent" absent "$has" FAIL
      FAILED=$((FAILED + 1))
      fail_msg "expected version ABSENT from .versions, got: $has — policy not applied in $1?"
    fi
  else
    record "$1: $YOUNG_PKG@$YOUNG_VER absent" '200+absent' "$CODE" FAIL
    FAILED=$((FAILED + 1))
    fail_msg "expected HTTP 200 (packument of $YOUNG_PKG), got $CODE — is $1 down?"
  fi
}

check_old "cluster A" "$REGISTRY_URL_A"
check_old "cluster B" "$REGISTRY_URL_B"
if [ -n "$YOUNG_PKG" ]; then
  check_young "cluster A" "$REGISTRY_URL_A"
  check_young "cluster B" "$REGISTRY_URL_B"
else
  record "young (none < ${MIN_AGE_DAYS}d on npmjs)" - - SKIP
fi

printf '\n'
printf '%-48s %-12s %-12s %s\n' 'CHECK' 'EXPECTED' 'GOT' 'RESULT'
printf '%s\n' '---------------------------------------------------------------------------------------'
printf '%s\n' "$RESULTS" | while IFS='|' read -r desc expected got status; do
  [ -n "$desc" ] || continue
  printf '%-48s %-12s %-12s %s\n' "$desc" "$expected" "$got" "$status"
done

if [ "$FAILED" -gt 0 ]; then
  printf '\nha-check: FAIL — %s assert(s) failed: the clusters do NOT serve the same policy. Triage: README "Operations" -> "Canary".\n' "$FAILED"
  exit 1
fi
printf '\nha-check: PASS — same policy on both clusters (compared by presence/absence of specific versions; counts NOT compared due to maxage skew)\n'
