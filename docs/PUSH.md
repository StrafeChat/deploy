# Push notifications

A phone signed in to an instance is notified about new messages, mentions and incoming calls
while the app is closed, and a notification disappears again when the conversation is read
on another device. This document is the map: who sends what to whom, what each party can
see, what an operator configures (very little), and how to tell what went wrong.

## The short version for operators

- **There is nothing to sign up for.** An instance needs no Google (Firebase) or Apple (APNs)
  account, key or configuration. It speaks plain, standard **Web Push** to whatever address
  each device gives it.
- **Push is on by default.** The instance generates its own Web Push identity (a VAPID key)
  on first start and keeps it in the database.
- **Nothing readable leaves the instance.** Every notification is encrypted to a key that
  only the receiving device holds. The relays in between see an opaque blob of one of four
  sizes, and when it was sent.
- The API needs outbound HTTPS to the push services devices use (the app's push gateway,
  e.g. `push.strafe.chat`, or a UnifiedPush server such as `ntfy.sh`).

## Pieces

| Piece | Where | Job |
| --- | --- | --- |
| Push module | `equinox/internal/modules/push` | Subscriptions, the instance's VAPID identity, the notify decision, encryption, the delivery queue and workers |
| Producers | `messages`, `rooms`, `voice` modules | Queue a job when a message is created, a room is read, or call ringing starts/stops |
| Directory | `equinox/internal/modules/push/pushdir` | What the workers look up about users, sessions, rooms and spaces |
| Outbound guard | `equinox/internal/safehttp` | The dial-time check that keeps pushes (and link previews) off private networks |
| Push gateway | `equinox/cmd/pushgateway` | Run by whoever publishes an app build: Web Push in, FCM/APNs out (see below) |
| Mobile app | `mobile/modules/strafe-push`, `mobile/src/platform/push` | Device keys, registration, decryption, rendering |

## How a notification travels

```
 device ──(1) register its FCM/APNs token──▶ push gateway ──▶ {endpoint}
 device ──(2) PUT /users/@me/push {endpoint, keys, prefs}──▶ its instance
 instance ──(3) Web Push POST <endpoint>, encrypted body + VAPID──▶ gateway ──▶ FCM/APNs ──▶ device
 instance ──(3') the same, to a UnifiedPush server ──▶ distributor app ──▶ device
```

1. The app asks the **push gateway of its own build** for an endpoint. The gateway seals the
   device token into the endpoint URL, so the instance never learns the token and two
   instances cannot link the same phone by its endpoint. On Android the user may instead use
   **UnifiedPush** (ntfy, NextPush, ...), which involves no gateway and no Google at all.
2. The app generates a key pair and an auth secret on the device and registers the endpoint
   and the public half with the instance, together with its notification preferences.
3. When something happens, the instance decides whether this device wants to know, builds a
   small JSON payload, encrypts it to the device's key and POSTs it to the endpoint.

A federated message notifies like a local one: the recipient's **home instance** sends the
push, once the message has been relayed to it.

## Privacy model

- **Encrypted end to end, instance to device.** The body is RFC 8291 message encryption
  (`aes128gcm`): a fresh ephemeral P-256 key and salt per push, ECDH with the device's key,
  mixed with the device's auth secret, AES-128-GCM. Only the device can read it - not the
  gateway, not Apple or Google, not a UnifiedPush server.
- **Padded.** The plaintext is padded to exactly 256, 512, 1024 or 2048 bytes, so the size
  of a push says almost nothing about the message.
- **End-to-end encrypted rooms stay that way.** The server has no plaintext for a PM, a group
  PM or an encrypted channel, so their pushes say only *who* wrote *where* (which the
  instance knows anyway) and the device shows "Encrypted message". Nothing is weakened to
  get previews.
- **Previews are the device's choice.** For rooms that are not end-to-end encrypted the
  payload carries a short plain-text preview only if that device asked for previews.
- **Stored data.** One row per signed-in session: the endpoint, the device's public key and
  auth secret, the preferences and delivery bookkeeping (last success, last error, a failure
  count). It is deleted when the session is signed out or revoked, when an instance
  administrator bans the account, when the push service says the endpoint is gone, and after
  five consecutive refused deliveries. Nothing about individual notifications is kept;
  queued jobs are deleted from Redis as soon as they are delivered.
- **Logs** name a push endpoint's host only, never its path (which is a capability) or keys.
- **On the device.** Avatars in notifications are fetched from the account's own instance, or
  over HTTPS from a public address - never from the phone's own network because a push named
  it. A notification's Reply / Answer buttons carry a per-install key in their
  `strafe://push/open` link; the app only acts on those buttons with it, so another app or a
  web page opening such a link can at most open a room - it can never answer a call.

## Configuration

Every setting is optional. In `deploy/.env` (passed through by `docker-compose.yml`):

| Variable | Default | Meaning |
| --- | --- | --- |
| `PUSH_ENABLED` | `true` | Master switch. Off: the push routes answer `404 push is disabled` and nothing is queued. |
| `PUSH_VAPID_PRIVATE_KEY` | empty | The instance's VAPID key, base64url of the raw 32-byte P-256 private key. Empty: generated on first start, stored in the `push_vapid` table and shared by every API replica. |
| `PUSH_VAPID_SUBJECT` | `https://<DOMAIN>` | Contact URI (`mailto:` or `https:`) that push services may use to reach the operator. |
| `PUSH_ALLOWED_HOSTS` | empty | Comma-separated push hosts (subdomains included). When set, other endpoints are refused at subscribe time (400) and at send time. |
| `PUSH_ALLOW_INSECURE` | `false` | **Development only.** Allows `http://` endpoints and private/loopback addresses. |
| `PUSH_WORKERS` | `4` | Delivery goroutines per API process. |

To pin a key (for example when moving an instance and wanting existing registrations to keep
working without the apps re-registering):

```sh
openssl ecparam -name prime256v1 -genkey -noout | openssl ec -outform DER 2>/dev/null \
  | tail -c +8 | head -c 32 | basenc --base64url | tr -d '=\n'
```

The schema is migration `equinox/migrations/049_push_subscriptions.cql` (`push_subscriptions`,
`push_vapid`), applied by `cmd/migrate` like every other.

## What an instance does *not* need

- No Firebase project, no `google-services.json`, no APNs key or Apple developer account.
- No inbound port: pushes are outbound HTTPS requests.
- No trust in the gateway: it only ever sees ciphertext, and an instance can restrict which
  gateways it talks to with `PUSH_ALLOWED_HOSTS`.

The Apple/Google hop belongs to whoever **publishes the app build**, because only they hold
that build's APNs key and Firebase credentials. The official Strafe build is configured for
`https://push.strafe.chat`; anyone who builds and publishes their own app runs their own
gateway (`equinox/cmd/pushgateway`) - see the next section.

## Running a push gateway

Only for people who **publish an app build**. Instance operators can skip this section.

`pushgateway` is a small stateless relay in the equinox image (`/app/pushgateway`): standard
Web Push in, Firebase Cloud Messaging (Android) or APNs (iOS) out. It stores nothing. A
device's platform token travels inside its endpoint URL, sealed with AES-256-GCM, so the
gateway needs no database and the instance never sees the token. Bodies are forwarded byte
for byte. It cannot read them, and it never logs tokens, endpoints or bodies.

### Settings

| Variable | Meaning |
| --- | --- |
| `PUSHGW_PUBLIC_URL` | **Required.** The address instances reach it at, e.g. `https://push.example.com` (a path prefix is fine). Endpoints are built from it, and a sender's VAPID `aud` must equal its origin. |
| `PUSHGW_SEAL_KEY` | **Required.** 32 random bytes, base64 (`openssl rand -base64 32`). Keep it secret and stable: losing it invalidates every endpoint (devices re-register on their next start). |
| `PUSHGW_SEAL_KEYS_OLD` | Previous seal keys, comma-separated, accepted for opening only. To rotate: move the current key here, set a new `PUSHGW_SEAL_KEY`, and drop the old one once devices have re-registered. |
| `PUSHGW_FCM_CREDENTIALS` | Path to a Firebase service-account JSON. Enables Android (FCM). |
| `PUSHGW_APNS_KEY`, `PUSHGW_APNS_KEY_ID`, `PUSHGW_APNS_TEAM_ID`, `PUSHGW_APNS_TOPIC` | The `.p8` key file, its Key ID, your Team ID and the app's bundle id. All four or none. Enables iOS (APNs). |
| `PUSHGW_LISTEN` | Bind address, default `:4020`. |
| `PUSHGW_TRUSTED_PROXIES` | IPs/CIDRs (or `loopback`, `linklocal`, `private`) whose `X-Forwarded-For` is believed, for the per-IP registration limit. |
| `PUSHGW_DEBUG` | Development only; see below. Refuses to start unless `PUSHGW_PUBLIC_URL` is local (localhost, a private address, a `.local`/`.test`/`.internal` name) and no FCM/APNs credentials are configured. |
| `LOG_LEVEL` | `info` (default) prints a counter summary every 5 minutes; `debug` prints a line per push. |

It refuses to start on a bad configuration and says why; `GET /healthz` lists the platforms
that are live. Limits (per replica): 30 registrations a minute per IP, 120 pushes a minute
per endpoint, 20000 a minute per instance (VAPID key).

```yaml
  pushgateway:
    image: <the equinox image>
    command: ["./pushgateway"]
    environment:
      PUSHGW_PUBLIC_URL: https://push.example.com
      PUSHGW_SEAL_KEY: ${PUSHGW_SEAL_KEY}
      PUSHGW_FCM_CREDENTIALS: /secrets/firebase-service-account.json
      PUSHGW_APNS_KEY: /secrets/AuthKey_XXXXXXXXXX.p8
      PUSHGW_APNS_KEY_ID: XXXXXXXXXX
      PUSHGW_APNS_TEAM_ID: YYYYYYYYYY
      PUSHGW_APNS_TOPIC: chat.strafe.mobile
      PUSHGW_TRUSTED_PROXIES: private
    volumes: ["./secrets:/secrets:ro"]
    expose: ["4020"]
```

Put TLS in front (Caddy: `push.example.com { reverse_proxy pushgateway:4020 }`). Sealed
endpoints can be a few kilobytes long, so allow long request lines. No CORS is needed.

### Credentials

- **Firebase.** In the Firebase console, add an Android app with your package name. In
  *Project settings → Service accounts*, generate a private key: that JSON is
  `PUSHGW_FCM_CREDENTIALS`. The Firebase Cloud Messaging API (V1) must be enabled for the
  project. The app build needs the same project's Android client values (*Project settings →
  General*) as `STRAFE_FCM_PROJECT_ID`, `STRAFE_FCM_APP_ID`, `STRAFE_FCM_API_KEY` and
  `STRAFE_FCM_SENDER_ID` at build time. Without them the Android build has no Firebase and
  uses UnifiedPush only.
- **APNs.** In Apple Developer, *Keys*: create a key with the Apple Push Notifications service
  enabled and download the `.p8` (you can only download it once). The bundle id needs the Push
  Notifications capability, and both it and `<bundle id>.NotificationService` need the App
  Group `group.<bundle id>`. One key serves sandbox and production. Each device reports which
  environment its build uses, and the gateway picks Apple's host to match.

### Pointing an app build at a gateway

The app reads its gateway from `EXPO_PUBLIC_PUSH_GATEWAY` when it is built (default
`https://push.strafe.chat`; see `mobile/app.config.js`). A build published under another
bundle id or Firebase project needs its own gateway with those credentials. Instances need
no change: they follow whatever endpoint each device registers.

### Responses

`POST /v1/push/<sealed>` answers:

| Status | Meaning |
| --- | --- |
| `201` | Delivered to Apple or Google. |
| `410` | The device token is dead; the instance deletes the subscription. |
| `429` | Throttled (`Retry-After`). |
| `502` | Upstream failure - including Apple or Google refusing because of this gateway's own configuration (`DeviceTokenNotForTopic`: a wrong `PUSHGW_APNS_TOPIC`; `SENDER_ID_MISMATCH`: another Firebase project's credentials). Those hit every device alike, so they are never reported as `410`, which would have every instance delete every subscription. |
| `503` | The platform isn't configured on this gateway. |
| `400`/`401`/`404`/`413`/`415` | A malformed push, a missing or invalid VAPID header, an unknown endpoint, too large, or not `aes128gcm`. |

The `Urgency` header picks how it is delivered. `high` becomes an alert, which iOS hands to
the app's notification extension to decrypt. Anything lower becomes a silent background
push, used for read receipts and for stopping a ring.

## UnifiedPush

On Android a user can pick a UnifiedPush distributor instead of Firebase in the app's
notification settings. The distributor app hands the Strafe app an endpoint on its server
(e.g. `https://ntfy.sh/up...`, or your own ntfy/NextPush), and the instance POSTs Web Push
there directly - no gateway, no Google Play services. The instance treats it exactly like any
other endpoint; the subscription's `kind` is `unifiedpush`. A self-hosted distributor on a
private network only works if `PUSH_ALLOW_INSECURE=true`, which is meant for development:
in production the distributor's server must be reachable on a public HTTPS address.

## Protocol reference

### Delivery (RFC 8030 + RFC 8291 + RFC 8292)

`POST <endpoint>` with:

| Header | Value |
| --- | --- |
| `Content-Encoding` | `aes128gcm` |
| `Content-Type` | `application/octet-stream` |
| `TTL` | seconds, per type (below) |
| `Urgency` | `high`, `normal` or `low`, per type |
| `Topic` | per type, replaces an undelivered push with the same topic |
| `Authorization` | `vapid t=<JWT>, k=<base64url uncompressed VAPID public key>` |

The body is one aes128gcm record: `salt(16) || rs(4) = 4096 || idlen(1) = 65 || keyid(65,
the ephemeral sender key) || ciphertext`. The VAPID JWT is ES256 (`{"typ":"JWT","alg":"ES256"}`)
with `aud` = the endpoint's origin, `exp` = now + 12 h, `sub` = `PUSH_VAPID_SUBJECT`.

| Type `t` | Meaning | Urgency | TTL | Topic |
| --- | --- | --- | --- | --- |
| `msg` | a new message | high | 86400 | - |
| `call` | an incoming call is ringing | high | 45 | `c<room id>` |
| `call_end` | ringing stopped (answered, declined, ended) | normal | 60 | `c<room id>` |
| `read` | the room was read on another device | low | 3600 | `r<room id>` |
| `test` | "send a test notification" | high | 300 | - |

Push service answers: `2xx` delivered; `404`/`410` the subscription is deleted; `400`, `403`,
`413` (and anything else unexpected) count a failure, five in a row delete it; `429` is
retried after `Retry-After` (at most 60 s); `5xx` and network errors are retried after 1 s,
4 s and 15 s while the push is still within its TTL, then counted - but never delete the
subscription, so a push service's bad hour does not cost every device its registration.
Redirects are not followed.

### Payload (inside the encryption)

Compact JSON, at most 2047 bytes. All ids are strings.

```jsonc
{
  "v": 1, "t": "msg", "uid": "<recipient>", "ts": 1760000000000,
  "rid": "<room>", "rt": 3,              // 1 PM, 2 group PM, 3 space text, 4 space voice, 6 thread
  "sid": "<space>",                      // space rooms only
  "mid": "<message>",
  "a": { "id": "<author>", "n": "Alice", "av": "https://.../avatar.webp" },
  "rn": "general",                       // room / thread / group name; absent for a 1:1 PM
  "pn": "announcements",                 // a thread's channel
  "sn": "Strafe HQ",                     // space name
  "e": true,                             // end-to-end encrypted room: never a "b"
  "b": "hey @Bob look at this",          // preview, non-E2EE rooms, if the device wants it
  "att": 2,                              // attachments
  "m": true                              // mentions the recipient (directly, by role, @everyone/@here)
}
```

`read` carries `rid`, `rt`, `sid` and `mid` (read up to). `call` carries `rid`, `rt`, the caller
as `a` and a group's `rn`. `call_end` carries `rid` and `rt`. `test` carries nothing more.
The preview has mentions written out as `@name`, room links as `#name` (only rooms the
recipient can see), custom emoji as `:name:`, whitespace collapsed, at most 300 characters.
In a space room or thread, `a.n` and `a.av` and the `@name` mentions in `b` are the member's
space nickname and space avatar where they have set one; PMs, group PMs and calls always
show the global profile.

### Who is notified

The instance mirrors what the web client does when it is open: never for your own message,
not from someone you blocked, nothing while your status is Do Not Disturb, nothing from a
room you cannot see or have muted; otherwise the room's own notification setting, falling
back to the device's preference for spaces (default: mentions only - narrowed to mentions
when the space defaults to mentions) or for PMs (default: all). Calls ring through Do Not
Disturb, as on the web, unless the device turned calls off.

### REST API

All `/users/@me/push` routes act on the **current session's** subscription and need a
session token (bot and OAuth2 tokens are refused). See the developer docs (`/docs/` on any
instance, "Push notifications") for request and response bodies.

| Route | |
| --- | --- |
| `GET /push/vapid-key` | the instance's VAPID public key (no auth) |
| `PUT /users/@me/push` | subscribe / replace (10/min) |
| `PATCH /users/@me/push` | change preferences |
| `GET /users/@me/push` | the subscription (no keys, endpoint host only) |
| `DELETE /users/@me/push` | unsubscribe (idempotent) |
| `POST /users/@me/push/test` | send a test push now and report the push service's answer (5/min) |

## Troubleshooting

- **Settings say the instance answered an error.** `GET /users/@me/push` shows `last_error`
  and `failures`: `http 403`/`http 401` usually means the push service refuses the instance's
  VAPID key (for example after `PUSH_VAPID_PRIVATE_KEY` was changed - re-registering in the
  app fixes it); `http 413` should never happen (pushes are at most 2150 bytes);
  `timeout`/`network error` means the API cannot reach the push service - check outbound
  HTTPS from the API container.
- **"endpoint must be a public address" / "endpoint resolves to a non-public address".** The
  endpoint points into a private network. In production that is refused on purpose (it would
  let anyone make the instance send requests inside its own network); for local development
  set `PUSH_ALLOW_INSECURE=true`.
- **"this instance does not send push notifications to ..."** - the host is not in
  `PUSH_ALLOWED_HOSTS`.
- **`404 push is disabled`** - `PUSH_ENABLED=false`, or the API could not load or store its
  VAPID key at start (look for `[push]` in its log; a restart retries).
- **Nothing arrives, no error.** Use "Send a test notification" in the app: it posts
  synchronously and reports the push service's status. If the test arrives but messages do
  not, check the room's and the space's notification settings and Do Not Disturb.
- **API log lines** are tagged `[push]`: workers starting, the subscriber index being built,
  subscriptions dropped (with the push host and the reason), and a single line when Redis
  becomes unavailable (pushes are dropped, not queued, until it is back).

## Development

- Run a push service locally and point the app at it with `PUSH_ALLOW_INSECURE=true` on the
  API (plain `http://127.0.0.1:...` endpoints are then accepted).
- **End to end on the Android emulator, without Google.** Start the gateway with
  `PUSHGW_DEBUG=true PUSHGW_PUBLIC_URL=http://127.0.0.1:4020 PUSHGW_SEAL_KEY=<fixed key>`.
  Its `debug` platform keeps pushes in memory (last 200) instead of forwarding them, and
  lists them at `GET /v1/debug/pushes?after=<seq>`. Then:
  1. Run `adb reverse tcp:4020 tcp:4020`.
  2. Start Metro with `EXPO_PUBLIC_PUSH_GATEWAY=http://127.0.0.1:4020`.
  3. In a development build, choose *Settings → Notifications → Push service → Development
     gateway*.
  4. Replay each listed push into the app with
     `adb shell am broadcast -p chat.strafe.mobile -a chat.strafe.mobile.DEBUG_PUSH --es s <slot> --es p <p>`.
     This goes to a receiver that only debug builds contain and runs the same path as an FCM
     message. Polling and replaying in a loop exercises everything except the last hop to
     Apple or Google, which the gateway's tests cover against fake servers.
- A job that takes long (a message to a big space, a slow push service) keeps renewing its
  claim on the `push:jobs` stream while it is processed, so another API process never picks
  it up a second time; a process that dies stops renewing and its jobs are taken over a
  minute later.
- Gateway tests: `go test -race ./internal/pushgateway/...`. They cover sealing and
  rotation, VAPID verification, the FCM and APNs request shapes and error mapping against
  TLS test servers, and the rejections and rate limits.
- `go test ./internal/modules/push/...` covers the RFC 8291 Appendix A test vector, VAPID,
  the decision table, endpoint validation, previews, and the real sender against a TLS test
  push service. The producer and stream tests need a Redis database of their own:
  `PUSH_TEST_REDIS=redis://localhost:6379/15 go test ./internal/modules/push/`.
