#!/usr/bin/env sh
# First-time setup: creates .env from .env.example, asks for the two values only you know,
# and generates every secret. Safe to re-run: an existing .env is never overwritten.
#
#   ./setup.sh && docker compose up -d --build
set -eu

cd "$(dirname "$0")"

if [ -f .env ]; then
  echo ".env already exists - leaving it alone."
  echo "Delete it first if you really want to start over: rm .env && ./setup.sh"
  exit 0
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is needed to generate secrets (apt install openssl / brew install openssl)." >&2
  exit 1
fi

printf 'Public hostname for this instance (e.g. chat.example.com): '
read -r domain
if [ -z "$domain" ]; then
  echo "A domain is required." >&2
  exit 1
fi

printf "Email for Let's Encrypt certificate notices: "
read -r email
if [ -z "$email" ]; then
  echo "An email is required (Let's Encrypt asks for one)." >&2
  exit 1
fi

printf 'Protect registration with a captcha? [Y/n] '
read -r captcha
case "${captcha:-Y}" in
  n|N) captcha=false ;;
  *) captcha=true ;;
esac

# Build from a checkout beside this directory if there is one - that is what a developer
# working in the full workspace wants, and it is the only way to build uncommitted changes.
# Otherwise leave .env.example's GitHub URLs alone, which is what a plain clone needs.
local_src=""
detect_src() {
  # $1 = variable name, $2 = sibling directory
  if [ -f "../$2/Dockerfile" ]; then
    local_src="$local_src$1"
    printf '  %s -> ../%s (local checkout)\n' "$1" "$2" >&2
    return 0
  fi
  return 1
}
echo "Source:" >&2
detect_src EQUINOX_SRC equinox || echo "  EQUINOX_SRC -> github.com/StrafeChat/equinox" >&2
detect_src WEB_SRC web.strafe.chat || echo "  WEB_SRC -> github.com/StrafeChat/web.strafe.chat" >&2
detect_src NEBULA_SRC nebula || echo "  NEBULA_SRC -> github.com/StrafeChat/nebula" >&2

upload_secret=$(openssl rand -hex 32)
altcha_key=$(openssl rand -hex 32)
# Only used if the operator switches CAPTCHA_PROVIDER to cap; generating it now means the
# dashboard is never protected by a password someone typed in a hurry.
cap_admin_key=$(openssl rand -hex 32)
livekit_key="API$(openssl rand -hex 6)"
livekit_secret=$(openssl rand -hex 32)
# A random node id keeps two instances set up from this script from colliding on ids.
node_id=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 1024 ))

# Fill the template. Values are constrained enough (hostname, email, hex) that plain sed
# is safe; the only characters that could bite (/ & |) cannot appear in them.
sed \
  -e "s|^DOMAIN=.*|DOMAIN=$domain|" \
  -e "s|^ACME_EMAIL=.*|ACME_EMAIL=$email|" \
  -e "s|^NEBULA_UPLOAD_SECRET=.*|NEBULA_UPLOAD_SECRET=$upload_secret|" \
  -e "s|^CAPTCHA=.*|CAPTCHA=$captcha|" \
  -e "s|^ALTCHA_HMAC_KEY=.*|ALTCHA_HMAC_KEY=$altcha_key|" \
  -e "s|^CAP_ADMIN_KEY=.*|CAP_ADMIN_KEY=$cap_admin_key|" \
  -e "s|^LIVEKIT_API_KEY=.*|LIVEKIT_API_KEY=$livekit_key|" \
  -e "s|^LIVEKIT_API_SECRET=.*|LIVEKIT_API_SECRET=$livekit_secret|" \
  -e "s|^SNOWFLAKE_NODE_ID=.*|SNOWFLAKE_NODE_ID=$node_id|" \
  .env.example > .env

# Only rewrite the sources we actually found; the rest keep their GitHub defaults.
case "$local_src" in *EQUINOX_SRC*) sed -i.bak -e "s|^EQUINOX_SRC=.*|EQUINOX_SRC=../equinox|" .env ;; esac
case "$local_src" in *WEB_SRC*) sed -i.bak -e "s|^WEB_SRC=.*|WEB_SRC=../web.strafe.chat|" .env ;; esac
case "$local_src" in *NEBULA_SRC*) sed -i.bak -e "s|^NEBULA_SRC=.*|NEBULA_SRC=../nebula|" .env ;; esac
rm -f .env.bak

chmod 600 .env

cat <<EOF

Wrote .env for https://$domain
  - upload secret, captcha key and voice (LiveKit) key pair generated
  - captcha: $captcha (ALTCHA, self-hosted - change CAPTCHA_PROVIDER in .env for another;
    for Cap, set COMPOSE_PROFILES=cap and see the CAP_* block in .env)
  - uploads: local volume (set STORAGE_BACKEND=s3 in .env to use a bucket)
  - sources: see the *_SRC values in .env (GitHub unless a checkout was found beside this
    directory); the first build clones and compiles them, so it takes a while
  - voice/video: on. Open 7881/tcp, 50000-50200/udp and 3478/udp on the firewall
    (clear LIVEKIT_API_KEY and LIVEKIT_API_SECRET in .env to run without voice)

Make sure DNS for $domain points at this host, then:

  docker compose up -d --build
  docker compose logs -f equinox-api      # until you see "federation: enabled as $domain"

Then open https://$domain and register the first account.
EOF
