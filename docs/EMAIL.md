# Email

The API sends two kinds of email: the **verification link** a new account gets, and the
**password-reset link** anyone can ask for from the login page. Everything else - who is
online, what was said, who is in which space - never touches email. This document is the
map: what sends, what delivers, what DNS has to say for the mail to arrive, and how to
tell what went wrong when it does not.

## Pieces

| Piece | Where | Job |
| --- | --- | --- |
| Mail package | `equinox/internal/mail` | SMTP client (go-mail) and the two templates (text + HTML) |
| Email service | `equinox/internal/modules/auth/service_email.go`, `handler_email.go` | Tokens, cooldowns, the verify / forgot / reset endpoints, the login gate |
| Bundled relay | `deploy/mail/maddy.conf`, `mail` in `docker-compose.yml` | maddy: DKIM signing, TLS delivery to recipients' MX, retry queue |
| Client pages | `web.strafe.chat/src/pages/{VerifyEmail,ForgotPassword,ResetPassword}Page.tsx` | Where the links land; plus the login page's "verify first" state and the settings' email row |

## Configuration

The API needs one variable; without it email is off and the client hides every trace of it
(`GET /` → `features.email.enabled`):

```
SMTP_HOST=mail                 # the bundled relay's service name, or any SMTP server
SMTP_PORT=587                  # default 587; 465 when SMTP_TLS=tls
SMTP_TLS=starttls              # starttls (STARTTLS required) | tls (implicit TLS) | none
SMTP_USERNAME=                 # both or neither
SMTP_PASSWORD=
MAIL_FROM=noreply@chat.example.com   # default: noreply@<FEDERATION_DOMAIN, else WEB_URL host>
MAIL_FROM_NAME=StrafeChat
EMAIL_VERIFICATION=false       # true: a verified address is required to sign in
```

`WEB_URL` must be set too - every link in an email points at the web client. The API
refuses to boot on a half configuration (`EMAIL_VERIFICATION=true` with no host, a
username without a password, a sender that is not an address) rather than fail at the
first signup; whether the SMTP server is actually reachable is checked per send, so a relay
that is down does not keep the API from starting.

## Why maddy, and why a relay at all

The API could have delivered mail itself - look up the recipient domain's MX, connect on
port 25, hand the message over. It deliberately does not. Real delivery needs a **queue**:
many receivers greylist (refuse a first attempt from an unknown sender with a temporary
error and accept the retry minutes later), servers go down, and a verification link that
is simply dropped on the first 4xx is a locked-out user. It needs **DKIM signing**, without
which Gmail and Outlook junk or refuse mail outright today. And it needs the TLS policies
receivers publish (MTA-STS, DANE) to be honoured. That is a mail transfer agent's whole
job, and reimplementing one inside a chat API would be the wrong place for the code.

Candidates for the bundled relay, as of September 2026:

| | Footprint | DKIM | Queue | Send-only config | Maintenance |
| --- | --- | --- | --- | --- | --- |
| **maddy** (`foxcpp/maddy`) | one Go binary, ~28 MB image, ~30 MB RSS | built in, keys auto-generated | built in, exponential backoff | yes - one `smtp` endpoint feeding `target.remote` | active (0.9.5, May 2026) |
| Postfix (`bokysan/docker-postfix`) | Debian + Postfix; since v6 DKIM is done by rspamd, a second daemon | via rspamd/OpenDKIM | yes | yes, env-driven | active |
| chasquid | Go binary | built in | yes | relays only for authenticated clients; wants a users file or Dovecot | active, slower cadence |
| OpenSMTPD | small C daemon | separate filter | yes | yes | community images, thin |
| msmtp / smarthost images | tiny | no | no | relay to an upstream only | - |

maddy wins on fit: it is one memory-safe binary in the same language as the rest of the
stack, DKIM and the queue are built in rather than bolted on, outbound TLS with MTA-STS and
DANE is the default policy, and a send-only configuration is a dozen lines. Postfix is the
safe, mature alternative and would be the pick if maddy were ever abandoned; the image's
move to rspamd for signing made it the heavier option for a relay that sends a handful of
mails an hour.

## What the relay does

[`mail/maddy.conf`](../mail/maddy.conf), in order:

- `tls off` for the **submission** side. The only client is the API, one hop away on the
  `mail` Docker network, which the compose file attaches to nothing else - that network is
  the credential, so no SMTP login is needed either (the `submission` endpoint module would
  insist on one; the plain `smtp` module is used). No port is published.
- `source {env:MAIL_DOMAIN}` relays mail **only from the instance's own domain**, after
  **DKIM-signing** it (`modify { dkim ... }`); any other sender gets a 501. A bug or a
  compromised API cannot make the relay send as someone else.
- `target.remote` delivers to each recipient domain's **MX over TLS**: a server without
  STARTTLS is refused (`min_tls_level encrypted`), and MTA-STS / DANE policies are
  enforced when a domain publishes them.
- `target.queue` **retries** temporary failures with exponential backoff, about twenty
  attempts over two days. There is no `bounce` block on purpose: the relay receives no
  mail, so there is nowhere for a bounce to land; a message that gives up is logged.

The DKIM key pair is generated on the relay's first start into the `mail-data` volume at
`/data/dkim_keys/<domain>_<selector>.key`, with the DNS record to publish written beside it:

```bash
docker compose exec mail cat /data/dkim_keys/chat.example.com_strafe.dns
```

Keep the volume: a new key means a new DNS record. `MAIL_DKIM_SELECTOR` (default
`strafe`) is the record's name; change it only if you rotate keys.

## DNS: making the mail arrive

A receiving server accepts mail from an unknown sender on three conditions, and the big
providers now enforce all of them. With `DOMAIN=chat.example.com` and the default
`MAIL_HOSTNAME=mail.chat.example.com`:

| Record | Name | Value | Why |
| --- | --- | --- | --- |
| A | `mail.chat.example.com` | the host's public IP | The relay says `EHLO mail.chat.example.com`; receivers resolve that and expect to find the connecting IP. **Must not be proxied** (Cloudflare grey cloud). |
| PTR | the host's IP | `mail.chat.example.com` | Reverse DNS. Set at your hosting provider, not in your zone - look for "reverse DNS" or "rDNS" on the server's network page. Many receivers refuse mail from an IP with no PTR, or one that does not resolve back. |
| TXT (SPF) | `chat.example.com` | `v=spf1 a:mail.chat.example.com -all` | "Mail from this domain comes from the IP that `mail.chat.example.com` resolves to, and nowhere else." Behind Cloudflare `v=spf1 a -all` would be wrong - the bare domain's A record is Cloudflare's. |
| TXT (DKIM) | `strafe._domainkey.chat.example.com` | from the `.dns` file above | The public half of the signing key. The whole string, including `v=DKIM1; k=rsa; p=...`. |
| TXT (DMARC) | `_dmarc.chat.example.com` | `v=DMARC1; p=quarantine` | Tells receivers what to do with mail that fails both checks. `p=none` while testing, `p=quarantine` or `p=reject` once mail flows. |

Then **outbound port 25** must be open from the host. Most cloud providers (AWS, Google
Cloud, Azure, DigitalOcean, Hetzner, Oracle) block it for new accounts and lift the block
on request through a support form; residential ISPs usually block it for good. Test from
the host:

```bash
nc -z -w 3 gmail-smtp-in.l.google.com 25 && echo open || echo blocked
```

If it stays blocked, use **your own SMTP server** instead of the bundled relay: any mail
server or provider that accepts authenticated submission on 587 or 465. Then the bundled
relay is not started at all, and SPF/DKIM are whatever that server's documentation says.

A new IP has no reputation. The first mails to Gmail or Outlook may land in spam even with
every record right; that resolves itself as recipients open them. Send a test to a mailbox
you control and run it through a checker such as mail-tester.com to see every check's
verdict at once.

## The flows

**Registration.** `POST /auth/register` creates the account, then - when verification is
required - issues a token and sends the link before answering. The response carries
`email_verification_required: true` and the client shows "check your inbox" instead of
sending the person to the login page. A relay that is down costs only a resend: the account
exists, the next sign-in attempt mails again.

**Sign-in with an unverified address** (`EMAIL_VERIFICATION=true`). `POST /auth/login`
checks the password first - whether an address is verified is only its owner's to learn -
then answers `403 {"code":"email_unverified","verification_email_sent":true|false}`, having
re-sent the link unless one went out in the last minute. The login page shows the state
with a resend button (which is just another login attempt). Accounts created before the
switch go through exactly this once.

**Verifying.** The link is `<WEB_URL>/verify-email?token=...`; the page posts it to
`POST /auth/email/verify`, which burns the token (Redis `GETDEL`, so a second click fails)
and sets `verified_email`. No session is needed - the person may be in another browser.
A signed-in account can ask for a fresh link with `POST /users/@me/email/verification`
(Settings → Security shows the address and its state).

**Forgot password.** `POST /auth/password/forgot {email}` answers `200` for any well-formed
address. If an account has it, a one-hour token is issued and the mail is sent **off the
request** - a synchronous SMTP round trip would make the response time a reliable oracle
for which addresses are registered. The link is `<WEB_URL>/reset-password?token=...`;
`POST /auth/password/reset {token, password}` sets the new password, marks the address
verified (the link proved it), revokes every session and tells the gateway to drop the
connections that held them (`SESSION_REVOKED`, reason `password_reset`).

**Tokens.** 32 random bytes, hex on the wire, stored under their SHA-256 in Redis with a
TTL (24 h verification, 1 h reset) together with the user id *and the address they were
issued for*, so a link can never confirm or reset through an address the account has since
changed. Nothing is swept; expiry is Redis's job.

**Rate limits.** One email of each kind per minute per account (verification) or per
address (reset) - `email_cooldown` - on top of per-IP route limits: 5 per 15 minutes on
forgot-password and the authenticated resend, 10 per minute on token redemption. Bots
(synthetic addresses) and federation shadows (their home instance mails them) are never
written to.

## Troubleshooting

| Symptom | Look at |
| --- | --- |
| "email is not configured on this instance" (503, `email_disabled`) | `SMTP_HOST` is empty for the API container; `docker compose logs equinox-api` prints `mail: sending through ...` at start when it is set. |
| Registration says "check your inbox", nothing arrives, API log shows `mail: send via mail:587` errors | The relay is not running (`COMPOSE_PROFILES` lacks `mail`?) or refused the sender: `docker compose logs mail`. A `501 5.1.8` means the API's `MAIL_FROM` domain is not `MAIL_DOMAIN`. |
| Relay log shows the message queued and `connection refused` / timeouts to the recipient's MX | Outbound port 25 is blocked from the host. |
| Relay delivers; Gmail/Outlook refuse (`550 5.7.1`) or junk it | A DNS record is missing or wrong - PTR and SPF first, then the DKIM TXT (compare with the `.dns` file). mail-tester.com shows each verdict. |
| Verification links say "not valid or expired" immediately | Redis is losing data between the send and the click (check `redis` logs), or the link was opened twice. |
| Turned `EMAIL_VERIFICATION` on and existing users cannot sign in | Expected: each is asked to verify once. If mail is not arriving, set it back to `false` until it does. |

Queue contents and retries: `docker compose logs mail` shows every attempt with the
recipient domain and the server's reply. The relay keeps queued messages under
`/data/remote_queue` in the `mail-data` volume.

## Development

Point the API at any SMTP sink. [Mailpit](https://mailpit.axllent.org) is a one-container
catch-all with a web inbox:

```bash
docker run -d --name mailpit -p 127.0.0.1:1025:1025 -p 127.0.0.1:8025:8025 axllent/mailpit
```

```
SMTP_HOST=127.0.0.1
SMTP_PORT=1025
SMTP_TLS=none
MAIL_FROM=noreply@a.local
EMAIL_VERIFICATION=true
```

Every email the API sends shows up at http://localhost:8025 with its headers and both
bodies. To exercise the bundled relay itself, run `foxcpp/maddy:0.9` with
`mail/maddy.conf` and swap `target.remote outbound_delivery` for a `target.smtp` that
forwards to Mailpit - the signed message, `DKIM-Signature` header included, lands in the
same inbox.
