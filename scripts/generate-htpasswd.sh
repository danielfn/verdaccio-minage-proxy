#!/usr/bin/env sh
# Generates an htpasswd line with bcrypt (the only format reliably supported
# by the verdaccio 6 htpasswd plugin; do NOT use `openssl passwd -6`).
# Uses the verdaccio image itself -> no host dependencies (docker only).
#
# Usage:
#   ./scripts/generate-htpasswd.sh <username> [password]
#
# Example (volume seeding):
#   docker compose exec verdaccio sh -c 'cat >> /verdaccio/storage/htpasswd' \
#     < <(./scripts/generate-htpasswd.sh svc-repo-manager)
set -eu

VERDACCIO_IMAGE="${VERDACCIO_IMAGE:-verdaccio/verdaccio:6.9.2}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <username> [password]" >&2
  exit 1
fi

USER_NAME="$1"
USER_PASS="${2:-$(openssl rand -base64 24)}"

HASH="$(docker run --rm --entrypoint node "$VERDACCIO_IMAGE" -e "
const bcrypt = require('/usr/local/lib/node_modules/verdaccio/node_modules/bcryptjs');
console.log(bcrypt.hashSync(process.argv[1], 10));
" "$USER_PASS")"

printf '%s:%s\n' "$USER_NAME" "$HASH"
if [ "$#" -lt 2 ]; then
  printf '(auto-generated password: %s — store it now, it cannot be recovered)\n' "$USER_PASS" >&2
fi
