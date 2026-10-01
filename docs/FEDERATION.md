# Federation

How independent StrafeChat instances talk to each other, what was true about the codebase
before this existed, and what the design does and doesn't cover.

## Starting point (codebase analysis)

StrafeChat is three services: **equinox** (Go/Fiber REST API and the **stargate**
WebSocket gateway, sharing ScyllaDB + Redis), **nebula** (a small object store serving
avatars, emoji and attachments over HTTP), and the **web** client (SolidJS). Before this
work the system was strictly single-instance:

- **Identity** was a local snowflake id plus `username#discriminator`, with lookup tables
  keyed by email and username. Nothing carried a "which server" notion.
- **Rooms** (PMs, group PMs, space channels) stored participants as local user ids;
  messages lived in one `messages` partition per room with local snowflake ids.
- **E2EE** (Olm/Megolm through matrix-sdk-crypto) already used Matrix-shaped identifiers,
  but with a synthetic server name (`@<id>:strafe.internal`, `!<room>:strafe.internal`).
  The key-exchange endpoints (`/devices/keys/query`, `/keys/claim`, `/send_to_device`)
  parsed and discarded the server part.
- **Deployment** had a development compose file (no web image, no TLS, secrets in a
  mounted `.env`), and both Go entrypoints aborted if `.env` was missing, which made
  configuring containers purely from the environment impossible.

The E2EE layer turned out to be the load-bearing decision: because it already spoke in
`@user:server` / `!room:server`, federation could be built by making those names *real*
rather than by re-plumbing the crypto.

## Design

### Instance identity and discovery

An instance is identified by its **domain** (`FEDERATION_DOMAIN`, e.g. `chat.example.com`)
and an **Ed25519 signing key** (auto-generated into `FEDERATION_KEY_FILE`, or supplied via
`FEDERATION_SIGNING_KEY`). It publishes an instance document at
`https://<domain>/.well-known/strafe` (also at `/federation/v1/instance`):

```json
{
  "domain": "chat.example.com",
  "version": 1,
  "api_url": "https://chat.example.com/api",
  "gateway_url": "wss://chat.example.com/gateway/events",
  "federation_url": "https://chat.example.com/api/federation/v1",
  "key_id": "ed25519:1",
  "public_key": "<base64>",
  "software": { "name": "strafe-equinox", "version": "..." }
}
```

Peers cache this for an hour and re-fetch on a signature failure (key rotation).

### Naming

| Thing | Local form | Federated form |
| --- | --- | --- |
| User, as typed by people | `alice#0001` | `alice#0001@chat.example.com` |
| User, for the crypto engine and S2S payloads (FID) | `@<id>:<local domain>` | `@<origin id>:<home domain>` |
| Room, for the crypto engine | `!<id>:<local domain>` | `!<origin room id>:<origin domain>` |

The *origin* id of a user is what their home instance calls them; the origin of a room is
the instance that created it. Every participating instance must agree on these strings so
Olm sessions and Megolm room keys (which embed the room id) line up.

### Shadow users

A remote user gets a local **shadow row** in `users` with `home_domain` and `remote_id`
set and no email/password. It is never in the email or username lookup tables and can't
log in, but every existing code path that resolves a user id (participants, mentions,
message senders, key-exchange reachability checks) works unchanged. `users_by_remote`
maps `(home_domain, remote_id)` back to the shadow. Profiles are refreshed whenever the
home instance relays a change (`POST /federation/v1/users/update`).

### Mirrored rooms

Each participating instance keeps its **own** room row, participant rows and message rows
under local ids, so listing, read state, mention counts and the gateway all keep working
per instance. Two mapping tables tie the copies together:

- `federated_rooms` / `federated_rooms_by_origin`: local room id ↔ `(origin_domain,
  origin_room_id)`.
- `federated_messages` / `federated_messages_by_origin`: local message id ↔
  `(origin_domain, origin_message_id)` for messages that crossed an instance boundary
  (edits, deletes and replies reference messages by origin id).

Only PMs and group PMs federate. Space channels stay local to the instance hosting the
space (see "Not covered").

### Server-to-server protocol

All S2S calls are JSON over HTTPS under `<federation_url>` and are signed:

```
X-Strafe-Instance:  sender domain
X-Strafe-Timestamp: unix seconds        (rejected if more than 5 minutes off)
X-Strafe-Nonce:     random per request  (rejected if seen before, 10 minute window)
X-Strafe-Signature: ed25519:1=<base64 signature>
```

The signature covers `strafe-fed-v1 \n METHOD \n <path after /federation/v1, with query>
\n timestamp \n nonce \n sha256(body)`. Signing the federation-relative path (not the full
URL path) means a reverse proxy may mount the API under any prefix.

| Endpoint | Purpose |
| --- | --- |
| `GET /users/lookup?username&discriminator` | resolve a handle to a profile |
| `GET /users/:id` | profile by origin id |
| `POST /users/update` | a user's profile changed |
| `POST /relationships` | a friend request, acceptance or teardown from the sender's user to one of the receiver's |
| `POST /rooms` | the origin announces a new room and its participants |
| `PUT /rooms/participants` | full member set after add/remove |
| `PATCH /rooms` | name / E2EE setting changed |
| `POST /rooms/typing` | typing indicator |
| `POST /rooms/messages`, `PATCH /rooms/messages`, `POST /rooms/messages/delete` | message lifecycle (including system messages) |
| `POST /keys/query`, `POST /keys/claim`, `POST /to_device` | E2EE key exchange for the receiver's users |

Authorization rules on the receiving side: an instance may only announce rooms it created,
relay messages/edits/deletes/typing for its **own** users, touch rooms one of its users
participates in, and act on relationships between its **own** user and one of ours. Profiles in payloads are trusted only for the sender's own users; a third
instance's user is fetched from their home before a shadow is created.

Relays are fire-and-forget: the local write and gateway event happen first, then each peer
is called in the background with a 30-second timeout; failures are logged, not surfaced.
There is no retry queue yet (see "Not covered").

### Friends across instances

A friend request to `alice#0001@chat.example.com` resolves the handle through
`GET /users/lookup` on her instance (creating or refreshing her shadow row), stores the
request locally against the shadow id, and relays it with `POST /relationships`
(`action: request`). Her instance stores it the other way round - from *your* shadow row
to her - and shows it to her like any local request. Accepting relays `accept`; declining,
withdrawing, unfriending and blocking all relay a single `remove`, and the receiving side
tears down whatever still stands (its own state says which it was). Two requests that cross
become a friendship on both sides. Blocks are never announced: a request from someone the
recipient has blocked is accepted with `204` and dropped, so the sender's instance learns
nothing. Because shadows are ordinary `users` rows, the friends list, pending requests and
nicknames need no extra tables; `home_domain` on the relationship's user object is what the
client renders as `@domain`. Profile changes are relayed to the home instance of every
remote friend, not only to instances sharing a room.

### End-to-end encryption across instances

The client builds the crypto engine's ids from the identity registry
(`web.strafe.chat/src/stores/federationIds.ts`), populated from the `home_domain` /
`origin_id` fields every participant now carries and the `federation` field on rooms.
On the server, `/devices/keys/query`, `/keys/claim` and `/send_to_device` split requests
by the domain in each `@id:domain` key: local users are answered locally, the rest is
forwarded (signed) to their home instance, which serves only its own users. Inbound
to-device traffic is stored for the local recipient with the sender's shadow id and pushed
with `sender_fid` so the recipient's engine keys the Olm session by the right name.

Consequence for existing installs: enabling federation renames local users from
`@id:strafe.internal` to `@id:<domain>`. The crypto engine refuses to reuse an account
under a different name, so the client keys its local store and device id by the federated
identity (`<id>@<domain>`) and, the first time a browser connects afterwards, retires the
pre-federation device: its store is deleted, the device revoked, and a fresh one
provisioned (`lib/e2ee/machine.ts`, `migrateLegacyIdentity`). A recovery backup that still
names the retired device is ignored rather than restored. Peers re-share room keys on
their next message; history encrypted before that stays readable only where the old
sessions still exist. Do this once, before you have users who care.

To-device messages record the sender's federated id (`sender_fid`, migration 022) so the
REST poll and the gateway push agree on who an Olm session belongs to.

### Attachments and emoji

Attachment URLs are absolute (the origin instance's nebula), so they render on any
instance. Encrypted attachments are fetched with `fetch()` and decrypted client-side, which
needs the CDN to allow cross-origin reads: nebula's `CORS_ORIGINS` must be empty (any
origin) or include the other instances. Custom emoji are referenced by id and resolved
through the origin's `/emojis/:id` only for local users; a remote emoji still renders
because its image URL is absolute, but the by-id lookup is local (falls back to `:name:`).

### Policy

`FEDERATION_ALLOWLIST` (when non-empty, the only peers) and `FEDERATION_BLOCKLIST` apply to
both directions. `GET /federation/peers` (session auth) lists instances seen so far.
`FEDERATION_STATIC_PEERS` and `FEDERATION_ALLOW_INSECURE` exist for development only.

## Not covered (yet)

- **Spaces** do not federate: a user can only join spaces on their own instance. The
  mirrored-room model extends to space channels in principle, but roles, permissions and
  member lists would need an authoritative-origin design first.
- **Presence and read receipts** are not relayed (remote users, friends included, show as
  offline).
- **Reactions** are not relayed: a remote participant never sees them.
- **Delivery guarantees**: a peer that is down when a message is relayed misses it; there is
  no outbox with retries. Adding one is the natural next step (persist the payload, retry
  with backoff, mark the peer degraded).
- **Media proxying**: attachments are loaded directly from the origin CDN, which exposes the
  reader's IP to that instance. A caching proxy on the reader's instance would fix that.
- **Key gating** on the S2S key endpoints is by signature only (any allowed instance can
  query/claim keys for your users), matching what Matrix does; a stricter "must share a
  room" check is possible with the mapping tables.

## Files

- `equinox/internal/federation/` - the engine: identity parsing, signing key, discovery,
  signed client, request-verifying middleware, mapping repository, outbound relays,
  inbound handlers.
- `equinox/internal/modules/{rooms,messages,devices,users,relationships}` - small
  `Federator`/`KeyRouter` hook interfaces the engine implements; nil when federation is off.
- `equinox/migrations/021_federation.cql` - shadow-user columns and mapping tables.
- `web.strafe.chat/src/stores/{instance,federationIds}.ts`, `src/lib/e2ee/constants.ts` -
  client-side identity.
- `deploy/` - production compose, Caddyfile, env template, runbook.
