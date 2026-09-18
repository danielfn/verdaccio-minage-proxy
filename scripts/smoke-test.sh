#!/usr/bin/env sh
# smoke-test.sh — verification suite for the verdaccio proxy (minAgeDays quarantine).
#
# Consumers: the post-deploy pipeline, the policy canary and HA validation.
# Runnable by hand against the local reference
# stack (docker compose up -d) or against the LB endpoint in a cluster.
#
# Usage (everything via environment variables — secrets NEVER as arguments):
#   REGISTRY_URL=http://localhost:4873 \
#   SERVICE_USER=svc-repo-manager \
#   SERVICE_PASS='…' \
#   [BLOCKED_PKG=typescript BLOCKED_VERSION=7.1.0-dev.20260814.1] \
#   ./scripts/smoke-test.sh
#
# SKIP_AUTH_CHECKS=1 — "via repo manager" mode: skips checks 1-2 (anonymous
# ping/401, which do not apply against a repo manager with its OWN auth in
# front of the proxy) and makes SERVICE_USER/SERVICE_PASS optional: without
# them the GETs of checks 3-5 are anonymous; with them, basic auth. Without
# the variable, behavior is the classic one (5 checks, mandatory credentials).
#
# Checks (in order; stops at the first failure):
#   1. GET /-/ping anonymous → 200 (LB healthcheck)         [skipped with SKIP_AUTH_CHECKS=1]
#   2. GET /left-pad anonymous → 401 (mandatory basic auth) [skipped with SKIP_AUTH_CHECKS=1]
#   3. GET /lodash auth → 200 + non-empty .versions + dist-tags.latest exists
#   4. GET /lodash/-/lodash-4.17.21.tgz auth → 200 (the proxy serves tarballs)
#   5. only with BLOCKED_PKG+BLOCKED_VERSION (version younger than the window):
#      GET /<pkg>/<version> auth → 404, version ABSENT from the packument and
#      tarball → 404 (serve-time quarantine active)
#
# Exit codes: 0 OK · 1 check failed · 2 bad config (incomplete env).
# Requires: curl and jq in PATH.
set -eu

PROGNAME="${0##*/}"

usage() {
    cat <<EOF
Usage:
  env REGISTRY_URL=<url> SERVICE_USER=<user> SERVICE_PASS=<pass> \\
      [BLOCKED_PKG=<pkg> BLOCKED_VERSION=<version>] $PROGNAME

  # via repo manager (it does its own auth in front of the proxy):
  env REGISTRY_URL=<repo-manager-url> SKIP_AUTH_CHECKS=1 \\
      [SERVICE_USER=<user> SERVICE_PASS=<pass>] \\
      [BLOCKED_PKG=<pkg> BLOCKED_VERSION=<version>] $PROGNAME

Smoke suite for the verdaccio proxy: healthcheck, basic auth, packument/
tarball proxying and (optional) quarantine of young versions.

Environment variables (required):
  REGISTRY_URL      Registry base URL (e.g. http://localhost:4873 or the LB one)
  SERVICE_USER      Service account (basic auth)
  SERVICE_PASS      Account password — ONLY via env var, never an argument
                    (SERVICE_USER and SERVICE_PASS are OPTIONAL with SKIP_AUTH_CHECKS=1)

Optional (via repo manager mode):
  SKIP_AUTH_CHECKS  When set to 1 skips checks 1-2 (GET /-/ping and the
                    anonymous GET expecting 401: they do not apply against a
                    repo manager, it authenticates on its own) and makes
                    SERVICE_USER/SERVICE_PASS optional — without them the
                    GETs are anonymous; with them, basic auth. Without this
                    variable (or empty) the behavior is the classic one:
                    5 checks, mandatory credentials.

Optional (enable check 5, quarantine; both or neither):
  BLOCKED_PKG       Package with a version published less than minAgeDays ago.
                    Typical candidate: the latest typescript nightly:
                      curl -s https://registry.npmjs.org/typescript \\
                        | jq -r '.time | to_entries[]
                                   | select(.key | test("^7\\.1\\.0-dev\\."))
                                   | "\\(.value) \\(.key)"' | sort | tail
  BLOCKED_VERSION   Version expected to be blocked

Examples:
  REGISTRY_URL=http://localhost:4873 SERVICE_USER=u SERVICE_PASS=p $PROGNAME
  REGISTRY_URL=https://lb.internal SERVICE_USER=u SERVICE_PASS=p \\
    BLOCKED_PKG=typescript BLOCKED_VERSION=7.1.0-dev.20260814.1 $PROGNAME
  REGISTRY_URL=http://repo-manager.internal SKIP_AUTH_CHECKS=1 \\
    BLOCKED_PKG=typescript BLOCKED_VERSION=7.1.0-dev.20260814.1 $PROGNAME

Exit codes: 0 OK · 1 check failed · 2 bad config.
Note: the check 5 tarball assumes an unscoped package (name
<package>-<version>.tgz), like typescript/esbuild; for scoped packages
the tarball name differs.
EOF
}

pass() { printf 'ok    %s\n' "$1"; }
skip() { printf 'skip  %s\n' "$1"; }
fail() { printf 'SMOKE FAIL: %s\n' "$1" >&2; exit 1; }

for arg in "$@"; do
    case "$arg" in
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf '%s: unsupported argument: %s (input via env vars, see --help)\n' \
                "$PROGNAME" "$arg" >&2
            exit 2
            ;;
    esac
done

SKIP_AUTH_CHECKS="${SKIP_AUTH_CHECKS:-}"
case "$SKIP_AUTH_CHECKS" in
    "" | 1) ;;
    *)
        printf '%s: SKIP_AUTH_CHECKS only accepts 1 (or empty); got: %s (see --help)\n' \
            "$PROGNAME" "$SKIP_AUTH_CHECKS" >&2
        exit 2
        ;;
esac

if [ "$SKIP_AUTH_CHECKS" = "1" ]; then
    # Via repo manager mode: only the URL is required; credentials (if
    # provided) are used as basic auth against the target.
    if [ -z "${REGISTRY_URL:-}" ]; then
        printf '%s: missing required variable: REGISTRY_URL (see --help)\n' \
            "$PROGNAME" >&2
        exit 2
    fi
    SERVICE_USER="${SERVICE_USER:-}"
    SERVICE_PASS="${SERVICE_PASS:-}"
elif [ -z "${REGISTRY_URL:-}" ] || [ -z "${SERVICE_USER:-}" ] || [ -z "${SERVICE_PASS:-}" ]; then
    printf '%s: missing required variables: REGISTRY_URL, SERVICE_USER, SERVICE_PASS (see --help)\n' \
        "$PROGNAME" >&2
    exit 2
fi

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '%s: dependency not found in PATH: %s\n' "$PROGNAME" "$cmd" >&2
        exit 2
    fi
done

# Normalize the base URL without a trailing slash.
while :; do
    case "$REGISTRY_URL" in
        */) REGISTRY_URL="${REGISTRY_URL%/}" ;;
        *) break ;;
    esac
done

BLOCKED_PKG="${BLOCKED_PKG:-}"
BLOCKED_VERSION="${BLOCKED_VERSION:-}"
if [ -n "$BLOCKED_PKG$BLOCKED_VERSION" ] && { [ -z "$BLOCKED_PKG" ] || [ -z "$BLOCKED_VERSION" ]; }; then
    printf '%s: BLOCKED_PKG and BLOCKED_VERSION are set together or neither\n' "$PROGNAME" >&2
    exit 2
fi

TOTAL_CHECKS=4
if [ -n "$BLOCKED_PKG" ]; then
    TOTAL_CHECKS=5
fi
if [ "$SKIP_AUTH_CHECKS" = "1" ]; then
    TOTAL_CHECKS=$((TOTAL_CHECKS - 2))
fi

# Common curl: silent but with visible errors and bounded timeouts (CI-friendly).
http() {
    curl -sS --connect-timeout 5 --max-time 120 "$@"
}

# GETs of checks 3-5: basic auth, or anonymous if SKIP_AUTH_CHECKS=1 was used
# without credentials (the target —repo manager— does its own auth).
http_auth() {
    if [ -n "$SERVICE_USER" ] && [ -n "$SERVICE_PASS" ]; then
        http --user "$SERVICE_USER:$SERVICE_PASS" "$@"
    else
        http "$@"
    fi
}

# Label for check 3-5 messages: "auth" (classic, or repo manager mode with
# credentials) or "anonymous" (repo manager mode without credentials).
AUTH_MODE="auth"
if [ "$SKIP_AUTH_CHECKS" = "1" ] && [ -z "$SERVICE_USER" ]; then
    AUTH_MODE="anonymous"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM
BODY="$WORKDIR/body.json"

# --- check 1: healthcheck -----------------------------------------------------
if [ "$SKIP_AUTH_CHECKS" = "1" ]; then
    skip "1. GET /-/ping anonymous — skipped with SKIP_AUTH_CHECKS=1 (target auth handled by the repo manager)"
else
    code="$(http -o /dev/null -w '%{http_code}' "$REGISTRY_URL/-/ping")" ||
        fail "check 1: curl could not connect to $REGISTRY_URL/-/ping"
    [ "$code" = "200" ] || fail "check 1: GET /-/ping anonymous: expected 200, got $code"
    pass "1. GET /-/ping anonymous → 200"
fi

# --- check 2: mandatory basic auth --------------------------------------------
if [ "$SKIP_AUTH_CHECKS" = "1" ]; then
    skip "2. GET /left-pad anonymous → 401 — skipped with SKIP_AUTH_CHECKS=1 (the repo manager does not require 401 for anonymous)"
else
    code="$(http -o /dev/null -w '%{http_code}' "$REGISTRY_URL/left-pad")" ||
        fail "check 2: curl could not connect to $REGISTRY_URL/left-pad"
    [ "$code" = "401" ] || fail "check 2: GET /left-pad anonymous: expected 401, got $code (auth disabled?)"
    pass "2. GET /left-pad anonymous → 401"
fi

# --- check 3: authenticated packument -----------------------------------------
code="$(http_auth -o "$BODY" -w '%{http_code}' \
    "$REGISTRY_URL/lodash")" ||
    fail "check 3: curl could not connect to $REGISTRY_URL/lodash"
[ "$code" = "200" ] || fail "check 3: GET /lodash $AUTH_MODE: expected 200, got $code"
jq -e '(.versions | length) > 0' "$BODY" >/dev/null 2>&1 ||
    fail "check 3: lodash packument has no versions (unexpected response)"
jq -e '.["dist-tags"] | has("latest")' "$BODY" >/dev/null 2>&1 ||
    fail "check 3: lodash packument missing dist-tags.latest"
pass "3. GET /lodash $AUTH_MODE → 200, $(jq '.versions | length' "$BODY") versions, latest=$(jq -r '.["dist-tags"].latest' "$BODY")"

# --- check 4: authenticated tarball -------------------------------------------
code="$(http_auth -o /dev/null -w '%{http_code}' \
    "$REGISTRY_URL/lodash/-/lodash-4.17.21.tgz")" ||
    fail "check 4: curl could not connect (lodash tarball)"
[ "$code" = "200" ] || fail "check 4: GET /lodash/-/lodash-4.17.21.tgz $AUTH_MODE: expected 200, got $code"
pass "4. GET /lodash/-/lodash-4.17.21.tgz $AUTH_MODE → 200"

# --- check 5 (optional): quarantine of young versions -------------------------
if [ -n "$BLOCKED_PKG" ]; then
    # 5a. the young version is not served by its endpoint.
    code="$(http_auth -o /dev/null -w '%{http_code}' \
        "$REGISTRY_URL/$BLOCKED_PKG/$BLOCKED_VERSION")" ||
        fail "check 5: curl could not connect (endpoint of $BLOCKED_PKG)"
    [ "$code" = "404" ] ||
        fail "check 5: GET /$BLOCKED_PKG/$BLOCKED_VERSION $AUTH_MODE: expected 404 (quarantine), got $code — is minAgeDays not filtering?"

    # 5b. the packument does not list the version (serve-time filter).
    code="$(http_auth -o "$BODY" -w '%{http_code}' \
        "$REGISTRY_URL/$BLOCKED_PKG")" ||
        fail "check 5: curl could not connect (packument of $BLOCKED_PKG)"
    [ "$code" = "200" ] || fail "check 5: GET /$BLOCKED_PKG $AUTH_MODE: expected 200, got $code"
    jq -e --arg v "$BLOCKED_VERSION" '(.versions | has($v)) | not' "$BODY" >/dev/null 2>&1 ||
        fail "check 5: $BLOCKED_VERSION appears in the packument of $BLOCKED_PKG (it should be hidden)"

    # 5c. the direct tarball of the young version neither (pruned _distfiles).
    code="$(http_auth -o /dev/null -w '%{http_code}' \
        "$REGISTRY_URL/$BLOCKED_PKG/-/$BLOCKED_PKG-$BLOCKED_VERSION.tgz")" ||
        fail "check 5: curl could not connect (tarball of $BLOCKED_PKG)"
    [ "$code" = "404" ] ||
        fail "check 5: GET /$BLOCKED_PKG/-/$BLOCKED_PKG-$BLOCKED_VERSION.tgz $AUTH_MODE: expected 404, got $code"

    pass "5. quarantine: $BLOCKED_PKG@$BLOCKED_VERSION → endpoint 404 + absent from the packument + tarball 404"
fi

printf 'SMOKE OK: %s checks passed\n' "$TOTAL_CHECKS"
