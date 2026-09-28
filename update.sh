#!/usr/bin/env sh
# Update a running StrafeChat instance: fetch this repository, work out what has changed,
# carry any new settings into .env, rebuild the services and wait for them to come back.
#
#   ./update.sh            update and restart
#   ./update.sh --check    say what would change and touch nothing
#   ./update.sh --yes      do not ask
#
# Safe to run on a healthy instance; safe to interrupt before the rebuild. Your data lives
# in docker volumes and is not touched, and .env is copied aside before anything edits it.
set -eu

cd "$(dirname "$0")"

CHECK=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --check | -n) CHECK=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --help | -h)
      # Print the header comment, stopping at the first line that is not one, so editing
      # the block above cannot leave this printing code.
      awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
      exit 0
      ;;
    *)
      echo "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

bold() { printf '\n\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$1"; }
err() { printf '\033[31m  x %s\033[0m\n' "$1" >&2; }
ok() { printf '\033[32m  ok %s\033[0m\n' "$1"; }

if [ ! -f .env ]; then
  err "no .env here - this instance has not been set up yet."
  err "run ./setup.sh first."
  exit 1
fi

# ------------------------------------------------------------------- this repository ----

bold "This deployment"
if [ -d .git ] && command -v git >/dev/null 2>&1; then
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    warn "local changes here - not pulling. Commit or stash them to get compose updates."
  elif [ "$CHECK" -eq 1 ]; then
    git fetch --quiet origin 2>/dev/null || true
    behind=$(git rev-list --count HEAD..@{u} 2>/dev/null || echo 0)
    if [ "$behind" = "0" ]; then info "up to date"; else info "$behind update(s) available for this repository"; fi
  else
    before=$(git rev-parse HEAD 2>/dev/null || echo none)
    git pull --quiet --ff-only 2>/dev/null || warn "could not fast-forward - pull it by hand"
    after=$(git rev-parse HEAD 2>/dev/null || echo none)
    if [ "$before" != "$after" ]; then
      ok "updated this repository"
      # A running sh reads its script as it goes, so carrying on inside a file that just
      # changed underneath us is how you get a half-old, half-new run. Start again in the
      # new one, once.
      if [ -z "${STRAFE_UPDATE_REEXEC:-}" ]; then
        info "restarting with the updated script"
        STRAFE_UPDATE_REEXEC=1 export STRAFE_UPDATE_REEXEC
        exec "$0" "$@"
      fi
    else
      info "up to date"
    fi
  fi
else
  info "not a git checkout - only the services will be updated"
fi

# ------------------------------------------------------------------------- services ----

# Where each service builds from, and what it would move to. A *_SRC holding a URL is
# asked over the network; one holding a path is read from that checkout.
report_source() {
  _name="$1"
  _var="$2"
  _src=$(grep "^${_var}=" .env 2>/dev/null | head -1 | cut -d= -f2- || true)
  [ -n "$_src" ] || _src=$(grep "^${_var}=" .env.example | head -1 | cut -d= -f2-)
  case "$_src" in
    http*://*)
      _url=${_src%%#*}
      _ref=${_src##*#}
      [ "$_ref" = "$_src" ] && _ref=HEAD
      _hash=$(git ls-remote "$_url" "$_ref" 2>/dev/null | head -1 | cut -c1-7)
      [ -n "$_hash" ] || _hash="unreachable"
      printf '  %-10s %s @ %s (%s)\n' "$_name" "$_url" "$_ref" "$_hash"
      ;;
    "")
      printf '  %-10s (not set)\n' "$_name"
      ;;
    *)
      if [ -d "$_src/.git" ]; then
        _hash=$(git -C "$_src" rev-parse --short HEAD 2>/dev/null || echo unknown)
        _dirty=""
        [ -n "$(git -C "$_src" status --porcelain 2>/dev/null)" ] && _dirty=" +local changes"
        printf '  %-10s %s (%s%s)\n' "$_name" "$_src" "$_hash" "$_dirty"
      else
        printf '  %-10s %s\n' "$_name" "$_src"
      fi
      ;;
  esac
}

bold "Services will be built from"
report_source api EQUINOX_SRC
report_source web WEB_SRC
report_source cdn NEBULA_SRC
info ""
info "Pin a tag in .env (e.g. #v1.2.0) if you would rather decide when these move."

# ----------------------------------------------------------------------------- .env ----

# Settings added upstream since this instance was set up. Compose's :- defaults hide most
# of them, so an instance quietly runs without a new feature until something that has no
# default stops the stack.
new_keys=$(
  awk -F= '/^[A-Z_][A-Z0-9_]*=/ { print $1 }' .env.example | while read -r k; do
    grep -q "^${k}=" .env || echo "$k"
  done
)
gone_keys=$(
  awk -F= '/^[A-Z_][A-Z0-9_]*=/ { print $1 }' .env | while read -r k; do
    grep -q "^${k}=" .env.example || echo "$k"
  done
)

# Copy a key out of .env.example together with the comment block that documents it, so an
# operator reading .env afterwards can tell what the new setting is for.
append_key() {
  APPEND_K="$1" awk '
    BEGIN { k = ENVIRON["APPEND_K"]; block = "" }
    /^#/ { block = block $0 "\n"; next }
    /^[[:space:]]*$/ { block = ""; next }
    $0 ~ "^" k "=" { printf "\n%s%s\n", block, $0; exit }
    { block = "" }
  ' .env.example >> .env
}

bold "Configuration"
if [ -n "$new_keys" ]; then
  warn "settings added since this instance was set up:"
  for k in $new_keys; do info "    $k"; done
else
  info "no new settings"
fi
if [ -n "$gone_keys" ]; then
  info "settings no longer used (harmless, left alone):"
  for k in $gone_keys; do info "    $k"; done
fi

# ---------------------------------------------------------------------------- apply ----

if [ "$CHECK" -eq 1 ]; then
  bold "Nothing changed (--check)"
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '\nRebuild and restart this instance? [y/N] '
  read -r reply || reply=""
  case "$reply" in
    y | Y | yes | YES) ;;
    *)
      info "aborted"
      exit 1
      ;;
  esac
fi

if [ -n "$new_keys" ]; then
  backup=".env.backup.$(date +%Y%m%d%H%M%S)"
  cp .env "$backup"
  chmod 600 "$backup"
  for k in $new_keys; do append_key "$k"; done
  ok "added $(echo "$new_keys" | wc -w | tr -d ' ') setting(s) to .env at their defaults (previous copy: $backup)"
fi

bold "Pulling third-party images"
# --ignore-buildable: the three StrafeChat services are built here, not pulled; this is
# ScyllaDB, Redis, Caddy, LiveKit and Cap picking up their pinned tags.
docker compose pull --ignore-buildable --quiet 2>/dev/null || docker compose pull --ignore-pull-failures

bold "Rebuilding and restarting"
# --wait holds until every healthcheck passes and the migration container has exited
# cleanly, so this command finishing means the instance is actually serving.
if docker compose up -d --build --wait --wait-timeout 600; then
  bold "Done"
  docker compose ps
  printf '\n'
  info "migrations:"
  docker compose logs --no-log-prefix --tail 20 equinox-migrations 2>/dev/null || true
else
  err "the stack did not come up healthy within 10 minutes."
  err "what each service is doing:"
  docker compose ps
  err "recent errors:"
  docker compose logs --tail 40 2>/dev/null | grep -iE "error|fatal|panic|refused" | tail -20 || true
  err "nothing was rolled back - your data is untouched and the previous .env is beside it."
  exit 1
fi
