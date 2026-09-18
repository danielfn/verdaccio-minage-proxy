#!/usr/bin/env sh
# Policy canary: proves that the quarantine (minAgeDays) is still enforced
# end-to-end. Discovers on npmjs a real version published less than the
# window ago and asserts that the proxy hides it (404 on resolve, absent
# from the packument, tarball 404), with a positive control (lodash@4.17.21
# still served) and an auth control (anonymous → 401). A silent filter
# failure (e.g. after an image upgrade) is detected within hours, not at
# the next incident.
#
# Usage (secrets ALWAYS via env, never via args):
#   REGISTRY_URL=http://localhost:4873 \
#   SERVICE_USER=svc-repo-manager SERVICE_PASS='...' \
#   ./scripts/canary.sh
#
# Env:
#   REGISTRY_URL   proxy endpoint (LB or local stack). Required to verify
#                  (not for discovery, which goes directly to npmjs).
#   SERVICE_USER   service account (basic auth).
#   SERVICE_PASS   account password.
#   CONFIG_FILE    source of minAgeDays (default: conf/config.yaml from the
#                  repo — the window is NEVER hardcoded here).
#   CANDIDATES     packages to search for a young version, space separated
#                  (default: "typescript @types/node esbuild vite").
#
# Exit codes: 0 = policy OK (or justified skip) · 1 = assert failed ·
#             2 = bad config (incomplete or invalid env/config).
#
# Stateless: writes nothing outside its own mktemp (cleaned up on exit).
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/../conf/config.yaml}"
CANDIDATES="${CANDIDATES:-typescript @types/node esbuild vite}"
NPMJS_URL="https://registry.npmjs.org"
# Margin against exact-cutoff flapping: a version <1.2 h away from meeting
# the window is not considered "young" (the script's and the filter's clocks
# are not synchronized; avoids false alerts at the boundary).
BOUNDARY_MARGIN_DAYS=0.05

show_help() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) show_help; exit 0 ;;
esac

log() { echo "canary: $*"; }
die_config() { echo "canary: ERROR: $*" >&2; exit 2; }

for dep in curl jq; do
  command -v "$dep" >/dev/null 2>&1 || die_config "missing dependency: $dep"
done

# --- 1. Quarantine window: ALWAYS read from the config (source of truth) ------
[ -r "$CONFIG_FILE" ] || die_config "cannot read CONFIG_FILE=$CONFIG_FILE"
if command -v yq >/dev/null 2>&1; then
  MIN_AGE_DAYS=$(yq '.filters."@verdaccio/package-filter".minAgeDays' "$CONFIG_FILE")
else
  # Fallback (e.g. CI runners without yq): the single "minAgeDays: N" line of the file.
  MIN_AGE_DAYS=$(grep -E '^[[:space:]]*minAgeDays:[[:space:]]*[0-9]+' "$CONFIG_FILE" \
    | head -n 1 | tr -dc '0-9')
fi
case $MIN_AGE_DAYS in
  ''|*[!0-9]*)
    die_config "invalid minAgeDays='$MIN_AGE_DAYS' in $CONFIG_FILE (expected non-negative integer)" ;;
esac
CUTOFF=$(awk -v m="$MIN_AGE_DAYS" -v g="$BOUNDARY_MARGIN_DAYS" 'BEGIN{printf "%.4f", m - g}')

TMP_WORK=$(mktemp -d)
trap 'rm -rf "$TMP_WORK"' EXIT INT TERM
PKG_FILE=$TMP_WORK/npmjs-packument
BODY_FILE=$TMP_WORK/body

# fetch <url> [auth] — does a GET (with/without basic auth) and leaves the
# status in CODE (000 if curl could not even connect) and the body in $BODY_FILE.
fetch() {
  _url=$1
  _auth=${2:-}
  : > "$BODY_FILE"
  if [ "$_auth" = "auth" ]; then
    CODE=$(curl -sS --compressed --max-time 120 -o "$BODY_FILE" -w '%{http_code}' \
      -u "$SERVICE_USER:$SERVICE_PASS" "$_url") || CODE=000
  else
    CODE=$(curl -sS --compressed --max-time 120 -o "$BODY_FILE" -w '%{http_code}' "$_url") || CODE=000
  fi
}

body_head() { tr '\n\r' '  ' < "$BODY_FILE" | cut -c 1-120; }

# --- 2. Discovery of a young version (directly against npmjs) -----------------
NOW=$(date -u +%s)
log "quarantine window: minAgeDays=$MIN_AGE_DAYS (from $CONFIG_FILE)"
log "discovering a version younger than ${MIN_AGE_DAYS}d among: $CANDIDATES"

YOUNG_PKG=''
YOUNG_VER=''
YOUNG_DATE=''
YOUNG_AGE=''

# shellcheck disable=SC2086  # intentional word-splitting: CANDIDATES is a list
for pkg in $CANDIDATES; do
  code=$(curl -sS --compressed --max-time 120 -o "$PKG_FILE" -w '%{http_code}' "$NPMJS_URL/$pkg") || code=000
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
    | @tsv' "$PKG_FILE" 2>/dev/null) || row=''
  if [ -z "$row" ]; then
    log "  $pkg: no parseable release times — skipped"
    continue
  fi
  ver=$(printf '%s\n' "$row" | cut -f1)
  published=$(printf '%s\n' "$row" | cut -f2)
  age=$(printf '%s\n' "$row" | cut -f3)
  if [ "$(awk -v a="$age" -v c="$CUTOFF" 'BEGIN{print (a < c) ? "yes" : "no"}')" = "yes" ]; then
    YOUNG_PKG=$pkg
    YOUNG_VER=$ver
    YOUNG_DATE=$published
    YOUNG_AGE=$age
    break
  fi
  log "  $pkg: newest $ver is ${age}d old — outside window"
done

if [ -z "$YOUNG_PKG" ]; then
  log "no young version available to test (window ok) — nothing to assert, exit 0"
  exit 0
fi

log "young version: $YOUNG_PKG@$YOUNG_VER (published $YOUNG_DATE, age ${YOUNG_AGE}d < ${MIN_AGE_DAYS}d)"

# --- 3. Asserts against the proxy ---------------------------------------------
[ -n "${REGISTRY_URL:-}" ] || die_config "REGISTRY_URL is required to verify the proxy"
[ -n "${SERVICE_USER:-}" ] || die_config "SERVICE_USER is required to verify the proxy"
[ -n "${SERVICE_PASS:-}" ] || die_config "SERVICE_PASS is required to verify the proxy"
REGISTRY_URL=${REGISTRY_URL%/}
log "verifying quarantine at: $REGISTRY_URL"

FAILED=0
RESULTS=''

record() { # desc expected got status
  RESULTS="$RESULTS$1|$2|$3|$4
"
}

# check_code <desc> <expected> — uses CODE/BODY_FILE from the last fetch()
check_code() {
  if [ "$CODE" = "$2" ]; then
    record "$1" "$2" "$CODE" PASS
  else
    record "$1" "$2" "$CODE" FAIL
    FAILED=$((FAILED + 1))
    printf '         expected HTTP %s, got %s — body: %s\n' "$2" "$CODE" "$(body_head)"
  fi
}

# Assert 1: direct resolution of the young version → 404.
fetch "$REGISTRY_URL/$YOUNG_PKG/$YOUNG_VER" auth
check_code "resolve $YOUNG_PKG@$YOUNG_VER is blocked" 404

# Assert 2: packument WITHOUT that version in .versions.
fetch "$REGISTRY_URL/$YOUNG_PKG" auth
if [ "$CODE" = "200" ]; then
  present=$(jq -r --arg v "$YOUNG_VER" '.versions | has($v)' "$BODY_FILE" 2>/dev/null) || present='unparseable'
  if [ "$present" = "false" ]; then
    record "packument omits $YOUNG_VER" absent absent PASS
  else
    record "packument omits $YOUNG_VER" absent "$present" FAIL
    FAILED=$((FAILED + 1))
    printf "         expected version ABSENT from .versions, got: %s — policy not applied?\n" "$present"
  fi
else
  record "packument omits $YOUNG_VER" '200+absent' "$CODE" FAIL
  FAILED=$((FAILED + 1))
  printf '         expected HTTP 200 (packument), got %s — body: %s\n' "$CODE" "$(body_head)"
fi

# Assert 3: direct tarball → 404. NOTE: scoped packages use @scope/name/-/name-x.y.z.tgz
# (the filename does NOT include the scope) — normalize.
case $YOUNG_PKG in
  @*/*) tar_base=${YOUNG_PKG#*/} ;;
  *)    tar_base=$YOUNG_PKG ;;
esac
fetch "$REGISTRY_URL/$YOUNG_PKG/-/$tar_base-$YOUNG_VER.tgz" auth
check_code "tarball $YOUNG_PKG@$YOUNG_VER is blocked" 404

# Positive control: a known old version is still served (the proxy is not
# down nor over-blocking — tells "policy works" apart from "everything 404").
fetch "$REGISTRY_URL/lodash" auth
if [ "$CODE" = "200" ]; then
  has=$(jq -r '.versions | has("4.17.21")' "$BODY_FILE" 2>/dev/null) || has='unparseable'
  if [ "$has" = "true" ]; then
    record "control: lodash@4.17.21 still served" present present PASS
  else
    record "control: lodash@4.17.21 still served" present "$has" FAIL
    FAILED=$((FAILED + 1))
    printf "         expected lodash 4.17.21 PRESENT in packument, got: %s — proxy over-blocking or broken?\n" "$has"
  fi
else
  record "control: lodash@4.17.21 still served" '200+present' "$CODE" FAIL
  FAILED=$((FAILED + 1))
  printf '         expected HTTP 200 (lodash), got %s — body: %s\n' "$CODE" "$(body_head)"
fi

# Auth control: anonymous → 401.
fetch "$REGISTRY_URL/lodash" anon
check_code "control: anonymous access denied" 401

# --- 4. Summary table + verdict ------------------------------------------------
printf '\ncanary target: %s (window minAgeDays=%sd, candidate %s@%s age %sd)\n\n' \
  "$REGISTRY_URL" "$MIN_AGE_DAYS" "$YOUNG_PKG" "$YOUNG_VER" "$YOUNG_AGE"
printf '%-52s %-12s %-12s %s\n' 'CHECK' 'EXPECTED' 'GOT' 'RESULT'
printf '%s\n' '---------------------------------------------------------------------------------------'
printf '%s\n' "$RESULTS" | while IFS='|' read -r desc expected got status; do
  [ -n "$desc" ] || continue
  printf '%-52s %-12s %-12s %s\n' "$desc" "$expected" "$got" "$status"
done

if [ "$FAILED" -gt 0 ]; then
  printf '\ncanary: FAIL — %s check(s) failed. Policy regression? Triage: README "Operations" -> "Canary".\n' "$FAILED"
  exit 1
fi
printf '\ncanary: PASS — quarantine (minAgeDays=%sd) is enforced end-to-end at %s\n' "$MIN_AGE_DAYS" "$REGISTRY_URL"
