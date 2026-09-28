#!/usr/bin/env sh
# First-time setup: asks how you want this instance configured, generates every secret, and
# writes .env. Safe to re-run: an existing .env is never overwritten.
#
#   ./setup.sh && docker compose up -d --build
#
# Every question has a default in brackets - pressing Enter through the whole thing gives a
# working public instance with a self-hosted captcha, local uploads, voice on and open
# federation. Nothing here cannot be changed later by editing .env.
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

# ------------------------------------------------------------------ small helpers ----

# Write KEY=value into .env. Deliberately not sed: an S3 secret or captcha key can contain
# /, & or | and would corrupt a sed replacement. The value travels through the environment
# so awk never interprets it as a pattern or an escape sequence.
set_env() {
  SETUP_K="$1" SETUP_V="$2" awk '
    BEGIN { k = ENVIRON["SETUP_K"]; v = ENVIRON["SETUP_V"] }
    $0 ~ "^" k "=" { print k "=" v; found = 1; next }
    { print }
    END { if (!found) print k "=" v }
  ' .env > .env.tmp && mv .env.tmp .env
}

section() {
  printf '\n\033[1m%s\033[0m\n' "$1"
}

# ask <prompt> <default>; echoes the answer. Enter takes the default.
ask() {
  _prompt="$1"
  _default="${2:-}"
  if [ -n "$_default" ]; then
    printf '%s [%s]: ' "$_prompt" "$_default" >&2
  else
    printf '%s: ' "$_prompt" >&2
  fi
  read -r _answer || _answer=""
  [ -n "$_answer" ] || _answer="$_default"
  printf '%s' "$_answer"
}

# ask_required <prompt> - keeps asking until something is typed.
ask_required() {
  while :; do
    _value=$(ask "$1" "")
    [ -n "$_value" ] && break
    echo "  That one is required." >&2
  done
  printf '%s' "$_value"
}

# yesno <prompt> <y|n default>; returns 0 for yes.
yesno() {
  _def="$2"
  _answer=$(ask "$1 [y/n]" "$_def")
  case "$_answer" in
    y | Y | yes | YES | Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ------------------------------------------------------------------------ identity ----

section "Identity"
echo "  The domain is also this instance's federation name: your users are name#0001@domain"
echo "  to people on other instances. DNS for it must already point at this host."
domain=$(ask_required "Public hostname (e.g. chat.example.com)")
acme_email=$(ask_required "Email for Let's Encrypt certificate notices")

# -------------------------------------------------------------------- registration ----

section "Registration"
invite_only=false
if yesno "  Require an invite code to create an account?" "n"; then
  invite_only=true
  echo "  The first account you register is exempt and becomes this instance's"
  echo "  administrator; after that you issue codes in Settings -> Instance."
fi

captcha=false
captcha_provider=altcha
friendly_site=""
friendly_api=""
turnstile_site=""
turnstile_secret=""
if yesno "  Protect registration with a captcha?" "y"; then
  captcha=true
  echo
  echo "  1) altcha     self-hosted proof-of-work. No account, no third-party request,"
  echo "                nothing to configure. Recommended."
  echo "  2) cap        also self-hosted, in its own container, with a stats dashboard."
  echo "  3) friendly   Friendly Captcha's hosted API (free tier; needs keys from them)."
  echo "  4) turnstile  Cloudflare Turnstile (needs keys from the Cloudflare dashboard)."
  while :; do
    choice=$(ask "  Which one?" "1")
    case "$choice" in
      1 | altcha) captcha_provider=altcha; break ;;
      2 | cap) captcha_provider=cap; break ;;
      3 | friendly)
        captcha_provider=friendly
        friendly_site=$(ask_required "    Friendly Captcha site key")
        friendly_api=$(ask_required "    Friendly Captcha API key")
        break
        ;;
      4 | turnstile)
        captcha_provider=turnstile
        turnstile_site=$(ask_required "    Turnstile site key")
        turnstile_secret=$(ask_required "    Turnstile secret key")
        break
        ;;
      *) echo "    Pick 1, 2, 3 or 4." >&2 ;;
    esac
  done
fi

# ------------------------------------------------------------------------- uploads ----

section "Uploads"
storage_backend=fs
s3_bucket=""
s3_endpoint=""
s3_region="us-east-1"
s3_key=""
s3_secret=""
s3_path_style=false
attachment_max=25
if yesno "  Store avatars, emoji and attachments in an S3 bucket instead of on this disk?" "n"; then
  storage_backend=s3
  s3_bucket=$(ask_required "    Bucket name")
  echo "    Endpoint: leave empty for AWS; set it for MinIO, Cloudflare R2, Backblaze B2, Ceph."
  s3_endpoint=$(ask "    S3 endpoint URL" "")
  s3_region=$(ask "    Region" "us-east-1")
  s3_key=$(ask "    Access key id (empty to use this host's ambient AWS credentials)" "")
  [ -n "$s3_key" ] && s3_secret=$(ask_required "    Secret access key")
  # Every self-hosted S3 implementation needs this; AWS does not.
  if [ -n "$s3_endpoint" ]; then s3_path_style=true; fi
fi
attachment_max=$(ask "  Largest attachment, in megabytes" "25")

# -------------------------------------------------------------------- voice/video -----

section "Voice and video"
livekit_key=""
livekit_secret=""
livekit_node_ip=""
if yesno "  Enable voice and video calls?" "y"; then
  livekit_key="API$(openssl rand -hex 6)"
  livekit_secret=$(openssl rand -hex 32)
  echo "  Media is WebRTC and does not go through the web server, so these must reach"
  echo "  this host directly: 7881/tcp, 50000-50200/udp and 3478/udp."
  echo "  Leave the next answer empty unless this host cannot work out its own public"
  echo "  address - behind NAT, or behind a proxy like Cloudflare."
  livekit_node_ip=$(ask "  Public IP to advertise for media" "")
fi

# --------------------------------------------------------------------- federation -----

section "Federation"
federation_allowlist=""
federation_blocklist=""
echo "  Open by default: any instance may talk to yours, and yours to any."
if yesno "  Restrict federation to a list of instances you name?" "n"; then
  federation_allowlist=$(ask "    Allowed domains, comma separated" "")
else
  federation_blocklist=$(ask "  Domains to refuse, comma separated (empty for none)" "")
fi

# ------------------------------------------------------------------------ building ----

# Build from a checkout beside this directory if there is one - that is what a developer
# working in the full workspace wants, and the only way to build uncommitted changes.
# Otherwise leave .env.example's GitHub URLs alone, which is what a plain clone needs.
local_src=""
detect_src() {
  if [ -f "../$2/Dockerfile" ]; then
    local_src="$local_src$1"
    return 0
  fi
  return 1
}
detect_src EQUINOX_SRC equinox || true
detect_src WEB_SRC web.strafe.chat || true
detect_src NEBULA_SRC nebula || true

# ------------------------------------------------------------------------- secrets ----

upload_secret=$(openssl rand -hex 32)
altcha_key=$(openssl rand -hex 32)
# Only used if the operator switches CAPTCHA_PROVIDER to cap; generating it now means the
# dashboard is never protected by a password someone typed in a hurry.
cap_admin_key=$(openssl rand -hex 32)
# A random node id keeps two instances set up from this script from colliding on ids.
node_id=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 1024 ))

# --------------------------------------------------------------------------- write ----

cp .env.example .env
chmod 600 .env

set_env DOMAIN "$domain"
set_env ACME_EMAIL "$acme_email"
set_env NEBULA_UPLOAD_SECRET "$upload_secret"
set_env SNOWFLAKE_NODE_ID "$node_id"

set_env INVITE_ONLY "$invite_only"
set_env CAPTCHA "$captcha"
set_env CAPTCHA_PROVIDER "$captcha_provider"
set_env ALTCHA_HMAC_KEY "$altcha_key"
set_env CAP_ADMIN_KEY "$cap_admin_key"
set_env FRIENDLY_CAPTCHA_SITE_KEY "$friendly_site"
set_env FRIENDLY_CAPTCHA_API_KEY "$friendly_api"
set_env TURNSTILE_SITE_KEY "$turnstile_site"
set_env TURNSTILE_SECRET_KEY "$turnstile_secret"
if [ "$captcha_provider" = cap ]; then
  set_env COMPOSE_PROFILES cap
  set_env CAP_API_URL "https://$domain/cap/"
fi

set_env STORAGE_BACKEND "$storage_backend"
set_env S3_BUCKET "$s3_bucket"
set_env S3_ENDPOINT "$s3_endpoint"
set_env S3_REGION "$s3_region"
set_env S3_ACCESS_KEY_ID "$s3_key"
set_env S3_SECRET_ACCESS_KEY "$s3_secret"
set_env S3_FORCE_PATH_STYLE "$s3_path_style"
set_env ATTACHMENT_MAX_MB "$attachment_max"

set_env LIVEKIT_API_KEY "$livekit_key"
set_env LIVEKIT_API_SECRET "$livekit_secret"
set_env LIVEKIT_NODE_IP "$livekit_node_ip"

set_env FEDERATION_ALLOWLIST "$federation_allowlist"
set_env FEDERATION_BLOCKLIST "$federation_blocklist"

case "$local_src" in *EQUINOX_SRC*) set_env EQUINOX_SRC ../equinox ;; esac
case "$local_src" in *WEB_SRC*) set_env WEB_SRC ../web.strafe.chat ;; esac
case "$local_src" in *NEBULA_SRC*) set_env NEBULA_SRC ../nebula ;; esac

# -------------------------------------------------------------------------- report ----

section "Wrote .env for https://$domain"
if [ "$invite_only" = true ]; then
  echo "  registration  invite only - register YOUR account first; it needs no code and"
  echo "                becomes this instance's administrator"
else
  echo "  registration  open to anyone"
fi
if [ "$captcha" = true ]; then
  echo "  captcha       $captcha_provider"
  [ "$captcha_provider" = cap ] && echo "                dashboard at https://$domain/cap/ - sign in with CAP_ADMIN_KEY from .env"
else
  echo "  captcha       off"
fi
if [ "$storage_backend" = s3 ]; then
  echo "  uploads       s3 bucket $s3_bucket (max ${attachment_max}MB)"
else
  echo "  uploads       local volume (max ${attachment_max}MB)"
fi
if [ -n "$livekit_key" ]; then
  echo "  voice/video   on - open 7881/tcp, 50000-50200/udp and 3478/udp on the firewall"
else
  echo "  voice/video   off"
fi
if [ -n "$federation_allowlist" ]; then
  echo "  federation    only: $federation_allowlist"
elif [ -n "$federation_blocklist" ]; then
  echo "  federation    open, except: $federation_blocklist"
else
  echo "  federation    open"
fi
if [ -n "$local_src" ]; then
  echo "  building      from the checkouts beside this directory"
else
  echo "  building      from github.com/StrafeChat - the first build clones and compiles,"
  echo "                so give it a few minutes"
fi

cat <<EOF

Make sure DNS for $domain points at this host, then:

  docker compose up -d --build
  docker compose logs -f equinox-api      # until you see "federation: enabled as $domain"

Then open https://$domain and register the first account.
EOF
