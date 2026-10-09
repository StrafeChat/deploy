# Deploying StrafeChat

One host, one domain, one `.env` file. Docker Compose runs every service (web client, API,
WebSocket gateway, CDN, ScyllaDB, Redis) behind Caddy on `https://$DOMAIN` with automatic
TLS.

## Prerequisites

- A Linux host with Docker Engine 24+ and the Compose plugin (`docker compose version`).
- A DNS `A`/`AAAA` record for your domain pointing at the host.
- Ports 80 and 443 reachable from the internet (Let's Encrypt validates over 80/443),
  plus `7881/tcp`, `50000-50200/udp`, `3478/udp` and `5349/tcp` for voice and video (see below).
- 2 GB RAM minimum; ScyllaDB is the hungry one (`SCYLLA_MEMORY`).

## First start

```bash
git clone https://github.com/StrafeChat/deploy.git strafechat && cd strafechat
./setup.sh
docker compose up -d --build
```

This repository is the only thing you need to clone. The three services (API + gateway,
web client, CDN) are built straight from their own repositories - see
[Building from source](#building-from-source) if you want to build a checkout of your own
instead.

`setup.sh` walks through how you want the instance configured, generates every secret, and
writes `.env`:

| It asks | Default |
| --- | --- |
| Domain and an email for Let's Encrypt | *(required)* |
| Whether registration needs an invite code | open |
| Which captcha, and any keys it needs | ALTCHA, self-hosted |
| Local disk or an S3 bucket for uploads, and the size limit | local disk, 25 MB |
| Whether voice and video are on, and the public IP to advertise for media | on, auto-detected |
| Whether federation is open, allowlisted or has a blocklist | open |

Every question has a default in brackets, so pressing Enter the whole way gives a working
public instance. `.env` is then the entire configuration - `docker-compose.yml` reads
everything from it and is not meant to be edited. To configure by hand instead,
`cp .env.example .env` and fill in the *Required* block; every other setting is documented
inline with a working default.

The first start builds the three images, creates the keyspace, runs every CQL migration,
and generates the instance's federation signing key into the `federation-data` volume.
Watch it with `docker compose logs -f equinox-api` until you see
`federation: enabled as <domain>`. Open `https://$DOMAIN`, register the first account,
and you're in.

## What `.env` controls

| Area | Variables | Notes |
| --- | --- | --- |
| Identity | `DOMAIN`, `ACME_EMAIL` | The domain is also your federation name. |
| Registration | `INVITE_ONLY`, `INSTANCE_ADMINS`, `CAPTCHA`, `CAPTCHA_PROVIDER` + that provider's keys, `EMAIL_BLOCK_DISPOSABLE`, `EMAIL_BLOCKED_DOMAINS` | See below. Throwaway-mail addresses (mailinator, yopmail, …) are refused by default; `EMAIL_BLOCKED_DOMAINS` adds your own, comma separated. IP/range bans, per-space verification levels and automod are managed from the app (admin dashboard → Bans; space settings → Moderation). |
| Direct messages | `PM_POLICY` | `shared` (default): only friends and people who share a space can start a DM with each other, which is what keeps strangers from spamming a public instance. `open`: anyone can message anyone. Blocks apply either way. |
| Email | `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `MAIL_FROM`, `EMAIL_VERIFICATION`, `MAIL_HOSTNAME`, `MAIL_DKIM_SELECTOR` | Off until `SMTP_HOST` is set; bundled send-only relay or your own server. See below. |
| Uploads | `ATTACHMENT_MAX_MB`, `STORAGE_BACKEND`, `S3_*`, `NEBULA_CORS_ORIGINS`, `SEED_EMOJI` | Local volume or any S3-compatible bucket; the CDN also serves the emoji sets so the client needs no third-party CDN. |
| Voice/video | `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `LIVEKIT_NODE_IP` | Bundled LiveKit; see below. |
| Federation | `FEDERATION_ALLOWLIST`, `FEDERATION_BLOCKLIST`, `FEDERATION_SIGNING_KEY`, `DISCOVER_FEDERATION` | Open by default. `DISCOVER_FEDERATION` (on by default) also puts the spaces your peers list on your Discover page, and offers yours to them; a space's managers can opt out of being shared from space settings → Discover. |
| Tuning | `SNOWFLAKE_NODE_ID`, `LOG_LEVEL`, `SCYLLA_SMP`, `SCYLLA_MEMORY` | |

### Invite-only registration

`INVITE_ONLY=true` closes registration to people holding an invite code.

The first account is exempt: on a brand-new instance there is nobody to have issued a code
yet, so **the first registration succeeds without one and becomes this instance's
administrator**. That claim is made with a lightweight transaction, so a stranger watching a
fresh deployment cannot race you for it - but register your own account promptly all the
same.

After that, an administrator issues codes in **Settings → Instance**, each with an optional
note, a use limit (1, 5, 25 or unlimited) and an expiry (1, 7 or 30 days, or never). A code
that runs out or expires disappears on its own. The same thing over the API:

```bash
curl -X POST https://$DOMAIN/api/instance/invites \
     -H "Authorization: <your token>" -H 'Content-Type: application/json' \
     -d '{"max_uses":1,"max_age_seconds":604800,"note":"for Sam"}'
```

`INSTANCE_ADMINS` is a comma-separated list of user ids that may do this regardless of what
the database says. Leave it empty - it exists so that an operator who loses the first
account is not locked out of their own instance.

Codes are checked against a compare-and-set, so a single-use invite admits exactly one
account even if several people redeem it at the same instant. Turning `INVITE_ONLY` back off
leaves existing codes in place, unused and harmless.

### Moderation

Administrators have a dashboard at `https://$DOMAIN/admin` (also reachable from the user
menu and from Settings → Instance). It can find any account by id, email, `name#0001` or
username; show where it is signed in from, which spaces it is in and what has been reported
about it; ban it from the instance - every session ends at once, the gateway drops its
connections, and sign-in is refused with the reason - for a day, a week, a month, a year
or until lifted; and take down a space, which removes it for all its members.

Anyone can report a user or a space (from a message, a member list, a profile, or the space
menu). Reports queue up on the dashboard; resolving one can dismiss it, mark it handled,
ban the account or take the space down, and every action lands in the instance audit log.
The server never copies message text into a report: in an end-to-end encrypted room it
cannot read it, and the reporter is told to paste it if they want it seen.

Every instance has an **official account** (shown with an OFFICIAL tag, username `system`),
provisioned automatically on first start. It delivers official messages to a user as a
direct message: the outcome of a report to the person who filed it, a note when a ban is
lifted, and any free-text notice an administrator sends from the dashboard (user drawer →
**Send a notice** - use it for warnings or announcements). The official account never logs
in and its direct messages are one-way - a recipient cannot reply. Its notices are plain
text (the account has no encryption keys), so unlike an ordinary 1:1 DM they are not
end-to-end encrypted; send nothing through it you would not want the server to hold.

### Discover

Every instance has a **Discover** page (the compass below "Add a space" in the sidebar): a
directory of the spaces and bots on that instance. Nothing is listed by itself - a
space's managers apply from **Space settings → Discover** and a bot's owner from
**Settings → Developers**, each with a tagline and a few tags, and the application lands
on the dashboard's **Discover** tab, where an administrator approves or declines it (a
note goes back to the applicant). A listed space can be joined from the page without an
invite; a listed bot's card opens its install page. A space is listed where it is hosted,
and an administrator can remove one at any time. Approvals, refusals and removals land in
the instance audit log.

The page also shows spaces listed on the instances you federate with, so a small instance
offers its users the whole network rather than its own handful of spaces. Each instance
serves what it lists at a signed endpoint and asks its peers for theirs every 15 minutes,
so a peer being down only means a slightly stale card. Joining one of those cards joins
the space on the instance that hosts it, the same as any federated space. Sharing is per
listing and on by default: a space's managers can untick **Show on other instances too**
under Space settings → Discover to be found on this instance only, and an operator can turn
the whole exchange off with `DISCOVER_FEDERATION=false`. Bots are never shared, since
installing one is an OAuth flow on the instance the application lives on.

### Desktop app

Your users do not need anything from you to use the desktop app: it is one build for every
instance, published at
[github.com/StrafeChat/web.strafe.chat/releases](https://github.com/StrafeChat/web.strafe.chat/releases)
for Windows, macOS and Linux, and its sign-in page asks which instance to use (your
`DOMAIN`). The API, gateway and CDN admit the app's own request origin alongside
`CORS_ORIGINS` / `STARGATE_ALLOWED_ORIGINS`, so no list needs editing. Two things to know:
a hosted captcha (Turnstile, Friendly Captcha) must allow the host `tauri.localhost` in its
dashboard or the app's registration form cannot show it (the default ALTCHA is unaffected),
and passkeys cannot be used as a second factor from the app - authenticator apps and
recovery codes work.

### Registration captcha

Any instance open to the public should run one (`CAPTCHA=true`). Four providers:

| `CAPTCHA_PROVIDER` | Needs | Where the work happens |
| --- | --- | --- |
| `altcha` (default) | `ALTCHA_HMAC_KEY` - generated by `setup.sh` | Entirely on your instance: it issues a signed proof-of-work puzzle and checks the answer. No account anywhere, no third-party script or request, nothing to track. |
| `cap` | `COMPOSE_PROFILES=cap`, then `CAP_SITE_KEY`, `CAP_SECRET_KEY`, `CAP_API_URL` - see below | Also entirely on your instance, in its own [Cap](https://trycap.dev) container, which adds a stats dashboard. |
| `friendly` | `FRIENDLY_CAPTCHA_SITE_KEY`, `FRIENDLY_CAPTCHA_API_KEY` from [friendlycaptcha.com](https://friendlycaptcha.com) (free tier) | Puzzle from their API; the widget is bundled with the client, so no third-party script. |
| `turnstile` | `TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY` from the Cloudflare dashboard | Cloudflare's script runs in the browser. |

Starting with `CAPTCHA=true` and the chosen provider's keys missing is a hard error - the
API refuses to boot rather than accept every registration while you believe it is
protected.

#### Using Cap

`altcha` needs no extra container and is the right default. Pick `cap` when you want its
dashboard (solve counts, per-site stats) or want one Cap serving several apps.

```bash
# 1. start it - the profile keeps it out of the way for everyone else
COMPOSE_PROFILES=cap docker compose up -d cap caddy

# 2. open https://<your domain>/cap/ and sign in with CAP_ADMIN_KEY from .env
#    (setup.sh generated one), then create a site

# 3. paste its two keys into .env and switch the provider over
#    CAPTCHA=true
#    CAPTCHA_PROVIDER=cap
#    CAP_SITE_KEY=...
#    CAP_SECRET_KEY=...
#    CAP_API_URL=https://<your domain>/cap      # already set for you

# 4. restart the API so it picks the new provider up
COMPOSE_PROFILES=cap docker compose up -d equinox-api
```

Cap stores its state in the instance's Redis on database 3, so there is no second
datastore to back up. `CAP_SITE_KEY` and `CAP_API_URL` are public (the browser needs
both); `CAP_SECRET_KEY` and `CAP_ADMIN_KEY` never leave the server.

### Email: verification links and password resets

Two things use email: the verification link a new account gets, and the "forgot password"
link. Both are off while `SMTP_HOST` is empty - the client then shows no forgot-password
link and asks nobody to verify. Two ways to turn them on; `setup.sh` asks which.

**The bundled relay** (`mail` in the compose file, started by `COMPOSE_PROFILES=mail`) is
[maddy](https://maddy.email), a single-binary mail server in Go, configured in
[`mail/maddy.conf`](mail/maddy.conf) to do one job: take mail from the API over a private
Docker network no other container is on, DKIM-sign it with a key it generates on first
start, and deliver it to the recipients' servers itself - over TLS, honouring MTA-STS and
DANE, through a retry queue that rides out greylisting. It publishes no port, receives no
mail and has no mailboxes; nothing to sign up for and no third party sees the addresses.
`setup.sh` sets `SMTP_HOST=mail`, `SMTP_TLS=none` (the hop to it is a private network; the
relay's own deliveries are TLS) and adds the profile.

**Your own server** - a mail server you already run, or a provider's submission endpoint -
takes `SMTP_HOST`, `SMTP_PORT`, `SMTP_TLS` (`starttls`, `tls` or `none`), and a username
and password if it wants one. The API speaks ordinary authenticated SMTP to it.

Mail only *arrives* if the domain says the sender is allowed to send it. For the bundled
relay that means four DNS records, which `setup.sh` prints and
[`docs/EMAIL.md`](docs/EMAIL.md) explains:

| Record | Name | Value |
| --- | --- | --- |
| A | `mail.$DOMAIN` (`MAIL_HOSTNAME`) | this host's public IP - a plain record, not proxied |
| PTR | the host's IP | `mail.$DOMAIN` - reverse DNS, set at your hosting provider |
| TXT (SPF) | `$DOMAIN` | `v=spf1 a:mail.$DOMAIN -all` |
| TXT (DKIM) | `strafe._domainkey.$DOMAIN` | printed by `docker compose exec mail cat /data/dkim_keys/$DOMAIN_strafe.dns` |
| TXT (DMARC) | `_dmarc.$DOMAIN` | `v=DMARC1; p=quarantine` |

The relay also needs **outbound port 25** open from this host. Most cloud providers block
it for new accounts and open it on request; `setup.sh` probes it and warns. Behind
Cloudflare, keep `mail.$DOMAIN` a DNS-only (grey cloud) record - a proxied one points at
Cloudflare, not at you, and SPF and the PTR check both fail.

`EMAIL_VERIFICATION=true` makes a verified address a condition of signing in: a new account
is sent its link at registration and the login page says "verify your email first" (and
re-sends the link, once a minute at most) until it is clicked. Accounts from before you
turned it on are asked to verify once at their next sign-in. Turn it on **after** a test
email has arrived - with it on and mail not getting through, nobody new can get in.
Password reset works whenever email does, verification required or not.

Each link is a single-use 256-bit token kept hashed in Redis: 24 hours for verification,
1 hour for a reset. A reset signs the account out everywhere.

### Storing uploads in a bucket

By default uploads live in the `nebula-data` volume on the host. For anything that will
outgrow a disk, point the CDN at a bucket:

```env
STORAGE_BACKEND=s3
S3_BUCKET=strafe-uploads
S3_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com    # empty for AWS S3
S3_REGION=auto
S3_ACCESS_KEY_ID=...
S3_SECRET_ACCESS_KEY=...
S3_FORCE_PATH_STYLE=false                                    # true for MinIO / most self-hosted
```

Works with AWS S3, Cloudflare R2, Backblaze B2, MinIO, Ceph RGW - anything that speaks
the S3 API. The bucket must already exist; the CDN checks it can reach it at startup and
refuses to start otherwise, so a typo shows up in `docker compose logs nebula`, not as a
failed upload later. Objects are served *through* the CDN (same `/cdn/...` URLs as
before), so the bucket can stay private and nothing about federation or client caching
changes. Switching backends does not move existing objects; copy them across with your
bucket's tooling (`aws s3 sync`, `rclone`) first if you are migrating a live instance.

### Voice and video

Calls in PMs and group PMs and the space voice rooms run on the bundled LiveKit server
(`livekit` in the compose file) - self-hosted, same host, nothing to sign up for.
`setup.sh` generates the `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` pair the API and
LiveKit share; to run without voice, leave both empty and every call control disappears
from the client.

Signalling goes through Caddy (`wss://$DOMAIN/livekit`), but WebRTC media does not, so
open these on the host firewall, straight to the LiveKit container:

| Port | Used for |
| --- | --- |
| `7881/tcp` | ICE over TCP, for clients whose networks block UDP |
| `50000-50200/udp` | Media |
| `3478/udp` | The built-in TURN relay, for clients behind strict NATs |
| `5349/tcp` | TURN/TLS - Firefox fails to connect at all without this, even when UDP works fine |

LiveKit finds the host's public IP through STUN. On a host that cannot reach the
internet directly, or behind a NAT that does not hairpin, set `LIVEKIT_NODE_IP`. Media
is end-to-end encrypted: each sender's media key is generated in their browser, handed to
the others over the same Olm channel PMs use, and rotated whenever someone joins or leaves,
so your LiveKit forwards packets it cannot read. A browser that cannot do it is refused the
call rather than connected in the clear. See [`docs/VOICE.md`](docs/VOICE.md).

## Building from source

`docker compose up --build` builds each service from its GitHub repository, pinned in
`.env`:

```
EQUINOX_SRC=https://github.com/StrafeChat/equinox.git#dev
WEB_SRC=https://github.com/StrafeChat/web.strafe.chat.git#dev
NEBULA_SRC=https://github.com/StrafeChat/nebula.git#dev
```

Point any of them somewhere else to build that instead - a local checkout, your own fork,
or a tag rather than a branch:

```
EQUINOX_SRC=../equinox                                 # a checkout beside this directory
EQUINOX_SRC=https://github.com/you/equinox.git#v1.2.0  # a fork, pinned to a tag
```

`./setup.sh` fills in local paths automatically when it finds the repositories next to this
one, which is what you want when you are developing rather than deploying. After changing
any of them, `docker compose up -d --build` rebuilds only what moved.

Pinning tags rather than tracking `#dev` is the sane choice for an instance you care about:
`dev` is where work lands, so it can break.

## Behind Cloudflare (or any other CDN)

If you put Cloudflare's proxy in front of this, set **SSL/TLS → Overview → Full (strict)**
before anything else. On **Flexible**, Cloudflare speaks plain HTTP to your server; Caddy
answers every plain-HTTP request with a redirect to HTTPS; Cloudflare hands that redirect
back to the browser, which asks again over HTTPS, which Cloudflare again turns into plain
HTTP to your server. That is `ERR_TOO_MANY_REDIRECTS`, and no change on this side can fix
it — the loop is between the browser and Cloudflare.

Two things make that failure outlive the fix:

- Browsers cache a `301` more or less permanently, so the loop can persist after the
  setting is correct. Confirm with `curl` rather than the browser (below), and retest in a
  private window.
- This deployment sends `Strict-Transport-Security`, so once a browser has seen the domain
  it will refuse plain HTTP for a year. That is intended, but it means "try it over http"
  is not a useful test.

To see what your server is actually doing, ask it directly and skip both caches:

```bash
curl -sSI --resolve $DOMAIN:443:<your server ip> https://$DOMAIN/ | head -20
```

A healthy instance answers `HTTP/2 200`. A `301` to the URL you just requested is the
loop, and tells you the redirect is being generated in front of the server, not by it.

### Certificate: Full (strict) with a Cloudflare Origin cert

Caddy still needs a certificate the edge accepts, and while the proxy is on it **cannot**
get one from Let's Encrypt — Cloudflare terminates TLS, so the TLS-ALPN challenge never
reaches Caddy. To keep the proxy on throughout, serve a **Cloudflare Origin certificate**
(this is built in):

1. Cloudflare dashboard → **SSL/TLS → Origin Server → Create Certificate** (it covers
   `$DOMAIN`; add `*.$DOMAIN` too if you use subdomains).
2. Save the certificate to `certs/origin.pem` and the private key to `certs/origin.key`
   beside this file — `certs/` is git-ignored.
3. In `.env`, set `CLOUDFLARE_ORIGIN_CERT=true`, then `docker compose up -d`.
4. Set the edge to **SSL/TLS → Overview → Full (strict)**.

Caddy then serves that cert and skips ACME; the cert is valid for years, so nothing
renews. (Prefer real Let's Encrypt certs with the proxy on? Give Caddy a Cloudflare API
token and the DNS-01 challenge instead — that needs a Caddy build with the Cloudflare DNS
module, which the Origin cert avoids.) If you only ever run **DNS-only (grey cloud)**,
ignore all of this: the default Let's Encrypt setup is correct.

### WebSockets

The gateway (`/gateway`) and voice signalling (`/livekit`) are WebSockets on 443, which
Cloudflare proxies — WebSockets are on by default (**Network → WebSockets**). The gateway
pings every ~54 s, under Cloudflare's ~100 s idle cutoff, so a quiet connection stays up;
nothing extra is needed once the certificate above is sorted. Do **not** switch the domain
to "Cache Everything": the client's `index.html` and `config.js` are served `no-cache` and
must stay that way.

### Real client IP

With the proxy on there is an extra hop, so unless the API is told to trust it every
request looks like it came from a Cloudflare edge — and per-IP rate limits bucket all your
users together. Set `TRUSTED_PROXIES` in `.env` to `private` plus
[Cloudflare's ranges](https://www.cloudflare.com/ips/); `.env.example` has the current list
ready to paste. To stop anyone reaching the HTTP surface by hitting the origin IP directly,
add [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/).

### Voice and video media

The one thing the proxy cannot carry at all is **WebRTC media**. Cloudflare forwards HTTP
and WebSockets, not the media ports, so clients reach your host **directly** for audio and
video:

- Keep `7881/tcp`, `50000-50200/udp`, `3478/udp` and `5349/tcp` open on the host firewall.
- Set `LIVEKIT_NODE_IP` to the server's real public IP. Behind the proxy LiveKit cannot
  infer it — the domain now resolves to Cloudflare — so without it calls connect and carry
  no audio. With it, clients get direct UDP candidates plus a TCP fallback on 7881 for
  UDP-blocked networks.
- The bundled TURN relay is advertised at `turn:$DOMAIN:3478`; with `$DOMAIN` proxied that
  name resolves to Cloudflare, which does not carry UDP 3478, so the relay path is dead.
  The direct UDP and TCP candidates above cover the same clients, so this only matters for
  the rare peer that can reach a relay but nothing direct — give it one on a **DNS-only**
  subdomain (`rtc.$DOMAIN` → your IP) if you need it.

Because media is direct, **the origin's IP is visible to anyone in a call** — Cloudflare
cannot hide it for voice. The web, API and gateway stay behind the proxy (WAF, L7 DDoS);
the media endpoint does not. If hiding the origin is a hard requirement, voice can't run on
a self-hosted SFU behind Cloudflare's standard proxy.

## Updating

```bash
./update.sh --check    # what would change, touching nothing
./update.sh            # do it
```

It fast-forwards this repository, reports the commit each service would move to, carries
any settings added upstream into your `.env` (with the comments that explain them, after
copying the old file aside), pulls the pinned third-party images, rebuilds, and waits until
every health check passes before saying it is done. If the stack does not come back it
prints what each service is doing and the recent errors rather than leaving you to find
them.

That last part is the reason to prefer it over `git pull && docker compose up -d --build`:
a setting added upstream is invisible until something that has no default stops the stack,
and by then it is not obvious that a missing `.env` key is the cause.

Your data is in docker volumes and is never touched. Updates are one-way - there is no
`--rollback` - so **take a backup first** (see below) on an instance you care about.

`*_SRC` in `.env` is what "latest" means. They track `#dev` out of the box, which is where
work lands and can therefore break; pin a tag instead if you would rather decide when your
instance moves:

```
EQUINOX_SRC=https://github.com/StrafeChat/equinox.git#v1.2.0
```

## Day-to-day

```bash
docker compose ps                     # health
docker compose logs -f equinox-api    # API logs (stargate, nebula, caddy likewise)
./update.sh                           # upgrade to the latest of what *_SRC points at
docker compose exec scylla nodetool status            # database health
```

Changed `.env`? `docker compose up -d` recreates only the services whose settings
changed.

Migrations run on every start through the `migrate` command (`equinox/cmd/migrate`): it
applies the `*.cql` files that are not yet recorded in the `schema_migrations` table, in
order, so an upgrade that adds tables needs nothing manual.

A keyspace that was migrated before this tool existed (by the old `cqlsh` loop) has no
`schema_migrations` table; the tool refuses to touch it because some migration files drop
and recreate tables. The compose service passes `-adopt`, which records the current files
as applied without running anything, once. Only do that when the schema really is
current - if it is behind, apply the missing files with `cqlsh` first.

```bash
docker compose run --rm equinox-migrations             # in the compose deployment
go run ./cmd/migrate -dry-run                          # local dev, from equinox/
go run ./cmd/migrate                                   # apply pending migrations
go run ./cmd/migrate -adopt                            # existing hand-migrated keyspace, once
```

### Backups

Everything durable is in named volumes: `scylla-data` (all chat data), `nebula-data`
(uploads, unless you use a bucket), `federation-data` (signing key), `caddy-data`
(certificates). Snapshot them with your usual volume backup tooling; the signing key
matters most for identity - if it changes, other instances will re-fetch your public key,
but nothing else breaks. Keep `.env` somewhere safe too: it holds the upload and captcha
secrets.

## Federation

Federation is on whenever `DOMAIN` is set (which this compose always does). Your instance
publishes `https://$DOMAIN/.well-known/strafe` and other instances can reach your users
as `name#0001@$DOMAIN`. To restrict who you talk to, set `FEDERATION_ALLOWLIST` (only
those) or `FEDERATION_BLOCKLIST`. See [`docs/FEDERATION.md`](docs/FEDERATION.md) for
how it works and what crosses the wire.

Checklist for a working federation link between two instances:

1. Both resolve each other's `/.well-known/strafe` over HTTPS (`curl https://other/.well-known/strafe`).
2. Neither has the other on a blocklist / missing from a non-empty allowlist.
3. Clocks are within 5 minutes of each other (signed requests carry a timestamp).
4. `NEBULA_CORS_ORIGINS` is empty or includes the other instance's origin, so its users
   can open attachments hosted on your CDN.

## Running two instances on one machine (development)

Federation needs each instance to have a distinct domain, keyspace, Redis database and
ports. `equinox/cmd/api` and `cmd/stargate` read `ENV_FILE` to pick a config file, and
`FEDERATION_STATIC_PEERS` + `FEDERATION_ALLOW_INSECURE=true` let instances find each
other over plain `http://127.0.0.1:<port>` without DNS or TLS:

```env
# .env.instance-b
PORT=4100
STARGATE_PORT=4101
SCYLLA_KEYSPACE=strafechatb
REDIS_DB=1
REDIS_CACHE_PREFIX=equinoxb:
SNOWFLAKE_NODE_ID=2
FEDERATION_DOMAIN=b.local
FEDERATION_PUBLIC_URL=http://127.0.0.1:4100
FEDERATION_ALLOW_INSECURE=true
FEDERATION_STATIC_PEERS=a.local=http://127.0.0.1:4000
FEDERATION_KEY_FILE=./federation-b.key
```

```bash
ENV_FILE=.env.instance-b go run ./cmd/api
```

The first instance gets the mirror image (`FEDERATION_DOMAIN=a.local`,
`FEDERATION_STATIC_PEERS=b.local=http://127.0.0.1:4100`).

## Without Docker

Each service is a single static binary (`go build ./cmd/api`, `./cmd/stargate`,
`nebula/cmd/nebula`) plus the static web bundle (`npm run build`). Configure them with the
same environment variables the compose file shows, put any reverse proxy in front that can
do HTTPS and WebSockets, and route the four path prefixes as in the `Caddyfile`.

Set `TRUSTED_PROXIES` on the API to the address(es) of that reverse proxy (an IP, a CIDR,
or one of `loopback`, `linklocal`, `private`, comma-separated). Only requests arriving
from those addresses have their `X-Forwarded-For` header believed; without it the API sees
every request as coming from the proxy, so the per-IP login rate limit (10/minute) would
apply to all of your users together. The compose file sets `private`, which covers the
Caddy container.
