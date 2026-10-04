# Federation

How independent StrafeChat instances talk to each other, what was true about the codebase
before this existed, and what the design does and doesn't cover.

## Starting point (codebase analysis)

StrafeChat is three services: **equinox** (Go/Fiber REST API and the **stargate**
WebSocket gateway, sharing ScyllaDB + Redis), **nebula** (a small object store serving
avatars, emoji and attachments over HTTP), and the **web** client (SolidJS). Before this
work the system was strictly single-instance:

- **Identity** was a local snowflake id plus a username (then paired with a #0001
  discriminator; usernames have since become unique on their own), with lookup tables
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
| User, as typed by people | `alice` | `alice@chat.example.com` |
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

PMs and group PMs are mirrored this way between the instances of their participants.
Space channels are mirrored too, but with one difference: a channel keeps the **origin's
message ids** on every instance (every message in it is stored by the origin first), so
replies, reactions and ordering agree everywhere without a lookup. See "Spaces across
instances".

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
| `GET /users/lookup?username` | resolve a handle to a profile |
| `GET /users/:id` | profile by origin id |
| `POST /users/update` | a user's profile changed |
| `POST /users/presence` | how a user now appears to others, for the receiver's users who are their friends or share a space with them |
| `POST /relationships` | a friend request, acceptance or teardown from the sender's user to one of the receiver's |
| `POST /rooms` | the origin announces a new room and its participants |
| `PUT /rooms/participants` | full member set after add/remove |
| `PATCH /rooms` | name / E2EE setting changed |
| `POST /rooms/typing` | typing indicator |
| `POST /rooms/messages`, `PATCH /rooms/messages`, `POST /rooms/messages/delete` | message lifecycle (including system messages) |
| `POST /rooms/reactions`, `POST /rooms/reactions/delete` | a reaction added to / withdrawn from a message |
| `POST /rooms/voice/join`, `/leave`, `/self`, `/ring`, `/decline` | asked of the room's origin: a token for the call it hosts, and the caller's later actions |
| `POST /rooms/voice/state`, `POST /rooms/voice/call` | pushed by the origin: a voice state changed or left, the call started / changed / ended |
| `GET /spaces/invites/:code`, `POST /spaces/join`, `POST /spaces/leave`, `POST /spaces/invites` | asked of a space's origin: preview an invite, redeem it for one of the asking instance's users (the answer is the whole space), leave, mint an invite |
| `POST /spaces/messages`, `PATCH /spaces/messages`, `POST /spaces/messages/delete`, `POST /spaces/reactions[/delete]`, `POST /spaces/messages/list`, `POST /spaces/messages/get` | asked of a space's origin by a mirror on behalf of a member: write into, react in and read a channel |
| `POST /spaces/manage` | asked of a space's origin by a mirror on behalf of a member who may manage it: one of `space.patch`, `space.image`, `role.create/update/delete`, `member.roles/kick/ban/unban`, `bans.list`, `invites.list`, `invite.delete`, `audit.list`, `room.create/update/delete`, `rooms.reorder`, `room.move`, `override.put/delete`, `emoji.create/rename/delete`, `space.transfer`, `space.delete`, `bot.install`, `member.add`; answers with the result and the relays captured for the asker |
| `POST /spaces/sync` | asked of a space's origin by a mirror: a fresh snapshot to reconcile against |
| `POST /spaces/members/list` | asked of a space's origin by a mirror: the next page of members (the join and sync replies carry the first page and a cursor) |
| `POST /spaces/update`, `/spaces/members`, `/spaces/roles`, `/spaces/rooms`, `/spaces/emoji`, `/spaces/peers`, `/spaces/delete` | pushed by the origin to every instance mirroring the space: settings, membership and roles, roles, channels and overrides (and their order), custom emoji, which instances are in the space, deletion |
| `POST /keys/query`, `POST /keys/claim`, `POST /to_device` | E2EE key exchange for the receiver's users |

Authorization rules on the receiving side: an instance may only announce rooms it created,
relay messages/edits/deletes/typing for its **own** users, touch rooms one of its users
participates in, and act on relationships between its **own** user and one of ours. For a
space, only the origin may push changes to a mirror, and only an instance that mirrors the
space (one of its users is a member) may ask the origin for anything in it; the acting
user must belong to the asking instance. Profiles in payloads are trusted only for the
sender's own users; a third instance's user is fetched from their home before a shadow
is created (the origin of a space relays messages from members of any instance, so a
mirror may fetch a sender's profile from a third instance the first time).

Relays are fire-and-forget from the user's point of view: the local write and gateway
event happen first, then the relay is queued, and a slow or absent peer never fails or
delays the user's own request. Every relay but typing, presence and call state is written
to `federation_outbox` before it is sent and deleted once the peer has taken it. One
worker per peer sends that peer's entries in order (so a message sent right after its
room was created cannot overtake the room announce) and, when the peer cannot be reached,
retries with backoff (1 s doubling to 30 s) until it can - so a peer that was down gets
everything it missed, in order, when it comes back, and a mirror converges without a
resync. A reply the peer will only repeat (a 4xx other than 408, 425 and 429) drops the
entry; an entry nobody could deliver in seven days expires. While a peer is unreachable
its row in `GET /federation/peers` carries `last_error`, `last_failure` and `pending`
(entries waiting), cleared by the next relay it takes. The API process drains the outbox;
the gateway, which relays presence only, writes entries and wakes the API over Redis.
Typing, presence and call state describe the moment and are superseded within seconds,
so they are sent once, from memory, and dropped if the peer is away.

### Friends across instances

A friend request to `alice@chat.example.com` resolves the handle through
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

### Presence across instances

Whenever a user's presence changes - the gateway marking them online or offline, or a
status/custom-status change through `PATCH /users/@me` - the instance tells the home
instance of each remote *friend*, and every instance that shares a *space* with the user
(see "Spaces across instances"), how the user now appears to others (`POST
/users/presence`; invisible already reads as offline). The receiver writes it to the
shadow row and publishes `PRESENCE_UPDATE` to the shadow's local friends and shared
spaces, so the status dot moves live and the next READY carries it. A freshly accepted
friendship exchanges presence in both directions so the new friend starts with a real
status. Friends and fellow space members only, which is who the local gateway tells as
well; people who merely share a PM are not told, matching local behaviour. The gateway process therefore needs the same federation
configuration and signing key as the API (the compose file gives both services the
`federation-data` volume); it loads the key but never creates it, so the API always owns
the identity. If a peer goes down mid-session its users stay at their last known status.

### Reactions across instances

Reactions on messages in federated PMs and groups are relayed (`POST /rooms/reactions`,
`POST /rooms/reactions/delete`) with the message referenced by origin id, exactly like
edits and deletes, and applied with the same per-message cap and gateway events as a
local reaction. A `custom:<id>` reaction is the origin's custom emoji id; a client that
does not know that emoji shows an empty pill, as it already does for a local reaction with
an emoji from a space the viewer is not in.

### Calls across instances

LiveKit servers do not federate, so a call in a federated PM or group runs on **one**
LiveKit: the one belonging to the room's *origin* instance (every peer knows it from the
room mapping). The origin mints every token, owns the voice states and the ringing call
object, and relays each change to the other instances in the room, which mirror them so
their READY payload, `GET /rooms/:id/voice/states` and gateway events work unchanged. A
user on another instance joins through their own API as usual: it asks the origin
(`POST /rooms/voice/join`, synchronous) and hands back the origin's public LiveKit URL
and token; leave, mute/camera flags, ring and decline are relayed to the origin the same
way. Participants in such rooms are named `<federated id>.<session>` towards LiveKit, so a
client on any instance can tell who a participant is; the E2EE media keys reach them over
the federated to-device channel like all other Olm traffic, and a key announcement names
the call's room by its federated identity (`!origin:domain`), never by a local id - a PM
or a mirrored channel has a different local id on every instance, and a key filed under
the sender's id would never match the receiver's call. Consequences: the origin's
`LIVEKIT_URL` must be reachable from the other instance's users, both instances need
voice configured (an instance without LiveKit has no voice routes at all), and if the
origin has no LiveKit the call cannot happen in that room. Voice channels of a federated
space work the same way, on the space origin's LiveKit.

### Spaces across instances

A space is hosted by the instance that created it, its **origin**, which stays the one
authority for membership, roles, permissions, channels, bans and settings - the
Discord-shaped model, chosen over Matrix-style distributed state because every check a
space needs (role hierarchy, channel overrides, slowmode, bans) already runs on one
server here and would otherwise have to be resolved between servers that disagree.

Every other instance with a member keeps a **mirror**: its own `spaces` row, room rows,
roles, overrides and member rows under local ids, so READY, local permission checks,
unread state, search and the gateway work unchanged for its users. `federated_spaces`
(and the room mapping tables for each channel) tie the mirror to the origin;
`federated_space_peers` is kept by the origin: which instances mirror each space.
Role ids are the origin's on every instance (they only need to be unique within the
space), room and space ids are local and mapped, members are shadow users, and - unlike
a PM - a channel's messages keep the origin's ids everywhere.

- **Joining.** An invite for a space on another instance is `code@domain`. The joining
  instance asks the origin to redeem it (`POST /spaces/join`) on behalf of its user; the
  origin applies the same checks a local join gets (invite validity, bans), adds the
  user as a shadow member, and answers with the whole space - settings, roles, channels
  with overrides, custom emoji, the other instances in the space, and the first page of
  members with profiles plus a cursor for the rest (`POST /spaces/members/list`,
  `FEDERATION_MEMBER_PAGE` members per page, 1000 by default, up to 100,000 members).
  The joiner builds the mirror from that and is a member from then on. A second user of
  the same instance just gets added to the existing mirror.
- **Writes go to the origin.** A member on a mirror sending a message, editing or
  deleting one, reacting, leaving, or minting an invite has their instance ask the origin
  (`/spaces/messages`, `/spaces/reactions`, `/spaces/leave`, `/spaces/invites`). The
  origin runs its usual checks - channel permissions, slowmode, @everyone gating, message
  ownership for edits, bans - stores the result, relays it to every *other* mirror, and
  answers; the asking instance applies the answer itself (it is skipped in that fan-out
  so nothing arrives twice). The origin's refusal is passed through to the member with
  its status and reason. Typing goes to the origin the same way and is passed on.
- **Reads come from the origin.** A mirror only holds what was relayed since one of its
  users joined, so a channel's history (`GET /rooms/:id/messages`) is read from the
  origin, as the asking member may see it, and kept locally as it is read; if the origin
  cannot be reached the local copy is served instead. The member list, roles and channel
  structure are read locally - they are complete.
- **Changes flow down.** Settings, icon/banner, role create/update/delete, member
  roles, channel create/update/delete and reorder, overrides, kicks, bans and the space's
  deletion are pushed by the origin to every mirror, which applies them and emits the
  same gateway events its own clients would see for a local change. A kicked, banned or
  departing member's instance drops the mirror once no local member is left; a banned
  user's rejoin is refused by the origin.
- **Management goes to the origin too.** A member on a mirror who may manage the space
  (by the mirrored roles, which are the origin's) changes settings, icon and banner,
  roles and members' roles, channels, their order and overrides, custom emoji, invites,
  kicks, bans and ownership, or deletes the space, through one call: `POST
  /spaces/manage {op, params}`. The origin runs the operation as that member with every
  check a local member gets (permissions, role hierarchy, owner-only rules, the typed
  name on delete), and answers with the operation's result **plus the relays the
  operation produced for the asking instance** - captured instead of sent. The mirror
  applies those exactly as it applies relays that arrive on their own, so after the call
  its state is what every other mirror has and the REST reply is served from it. Lists
  the mirror does not hold (bans, invites, the audit log) are read the same way, with
  users mapped to local ids and invite codes returned as `code@origin`.
- **Bots.** A bot is installed into a federated space by a member whose account lives on
  the bot's instance: they approve the bot's consent screen there (the mirrored space is
  listed as a target, marked with where it is hosted), and that instance asks the origin
  (`bot.install`) to add the bot as that member, with the member's own grantable
  permissions. The origin creates the bot's shadow, runs the install exactly as a local
  one (Manage Space or Administrator required, the managed role at position 1, the
  audit entry) and relays the member and the role to every mirror; on the bot's own
  instance the member row is the bot itself, so its gateway connection gets the space in
  READY and every relayed message in it, and what it posts goes to the origin like any
  member's. Re-authorising re-applies permissions, kicking the bot (from any instance
  with the right to) removes it and its role everywhere, and an app's `spaces.join`
  (`member.add`) adds one of its instance's users through the origin the same way. No
  instance can install another instance's bot or add another instance's users; a bot
  cannot be added to a space hosted elsewhere by someone from a third instance, because
  the consent happens where both the person and the bot live.
- **Custom emoji** are part of the snapshot and relayed on create/rename/delete, keeping
  the origin's ids, so `<:name:id>` renders on every instance and the picker shows them;
  an emoji uploaded from a mirror is stored on that instance's CDN and recorded by the
  origin with its URL.
- **Resync.** A mirror asks its origin for a fresh snapshot (`POST /spaces/sync`) soon
  after the API starts and every half hour, and reconciles settings, roles, channels,
  members (fetched page by page; if a page cannot be fetched the reconcile adds members
  but removes none), emoji and the list of instances against it - the catch-up for
  anything that went wrong while the instance was down, on top of the outbox replaying
  the relays themselves. A member can ask for one any time (`POST /spaces/:id/resync` on
  their own instance). A space the origin no longer has is dropped.
- **Presence and profiles.** The origin keeps the list of instances in each space and
  hands it to every mirror - in the snapshot, then `POST /spaces/peers` as instances come
  and go - and a mirror stores it under its own space id. A member's home instance
  therefore sends their presence and profile changes to every instance in the space
  itself, the origin and the other mirrors alike, and no instance ever relays what
  another instance's user is doing: `POST /users/presence` and `/users/update` keep the
  rule that a peer speaks only for its own users with any number of instances, so a
  space's origin cannot make one of its members look different elsewhere. A joining
  member's status travels with the join, so the member-add every mirror gets already
  carries it, and the snapshot carries every member's.
- **Voice channels** of a federated space run on the origin's LiveKit exactly like a
  call in a federated PM (the origin mints the token, mirrors keep the states).
- **Clients** see a `federation: {origin_domain, origin_id}` field on a mirrored space
  and on each of its rooms, show "hosted on domain" from it, render remote members'
  handles with their domain, and accept `code@domain` wherever an invite code goes
  (invite page, pasted links, the "have an invite?" box). Managing a mirrored space
  needs no client changes: the same settings pages work, with the origin's answer. An
  invite link opened on an instance where the visitor has no account offers "continue
  on your instance": they name the instance their account is on (remembered for next
  time) and are sent to `/invite/<code>@<origin>` there, where they are logged in - so a
  plain link to a space on one instance works for someone whose account is on another.

What the origin does not do: it never trusts a mirror's permission decisions (a mirror's
local checks are a convenience), never lets one instance act for another's users, and
never accepts a mirror's claims about structure. What a mirror cannot do: read pre-join
history while the origin is down.

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
`FEDERATION_MEMBER_PAGE` (default 1000, at most 1000) is how many members go in one page
when another instance builds or resyncs a mirror of a space hosted here.

## Not covered (yet)

- **Spaces, the rest of it**: a mirror that cannot reach the origin serves only the
  history it has seen; when the last local member leaves, the mirror and its local copy
  of the history are dropped; a mirror holds at most 100,000 members.
- **Read receipts** are not relayed, and presence reaches remote friends and instances
  sharing a space only (not people who merely share a PM).
- **Several API replicas** would each deliver the same outbox entry (every receiver is
  idempotent for messages, rooms and reactions, so nothing breaks, but a per-entry claim
  belongs in front of that step before the API is scaled out).
- **Media proxying**: attachments are loaded directly from the origin CDN, which exposes the
  reader's IP to that instance. A caching proxy on the reader's instance would fix that.
- **Key gating** on the S2S key endpoints is by signature only (any allowed instance can
  query/claim keys for your users), matching what Matrix does; a stricter "must share a
  room" check is possible with the mapping tables.

## Files

- `equinox/internal/federation/` - the engine: identity parsing, signing key, discovery,
  signed client, request-verifying middleware, mapping repository, outbound relays
  (`outbox.go`: the durable per-peer queue), inbound handlers; `spaces_peers.go` holds
  the instance list of a space and the paged member sync.
- `equinox/internal/modules/{rooms,messages,devices,users,relationships,spaces,voice}` -
  small `Federator`/`KeyRouter` hook interfaces the engine implements; nil when federation
  is off. `spaces/federation.go` holds the mirror side (building and updating a mirror),
  `federation/spaces.go` the wire types and both directions of the space protocol.
- `equinox/migrations/021_federation.cql` - shadow-user columns and mapping tables;
  `035_federated_spaces.cql` - space mappings and the space peer list;
  `036_federation_outbox.cql` - the relay outbox and the peer failure marks.
- `web.strafe.chat/src/stores/{instance,federationIds}.ts`, `src/lib/e2ee/constants.ts` -
  client-side identity.
- `deploy/` - production compose, Caddyfile, env template, runbook.
