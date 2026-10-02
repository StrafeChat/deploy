# Voice and video

Calls in PMs and group PMs, and the voice rooms of a space, run on a self-hosted
[LiveKit](https://livekit.io) server. LiveKit only carries media; the API owns everything
that decides *who is where and what they may do*. The media itself is end-to-end
encrypted, so the SFU forwards ciphertext it cannot read - see
[End-to-end encryption](#end-to-end-encryption). This document is the map.

## Pieces

| Piece | Where | Job |
| --- | --- | --- |
| LiveKit SFU | `deploy/docker-compose.yml` → `livekit`; root `docker-compose.yml` for dev | WebRTC media routing, participant tracking, webhooks |
| Voice module | `equinox/internal/modules/voice` | Tokens, voice states, permissions, moderation, PM call ringing, webhook + reconciler |
| Call keys | `web.strafe.chat/src/lib/e2ee/callKeys.ts`, `lib/voice/e2ee.ts` | Per-sender media keys, Olm-distributed; the LiveKit key provider |
| Gateway | `equinox/cmd/stargate` | Puts current voice states and calls in `READY`; relays `VOICE_STATE_UPDATE` / `CALL_*` |
| Client store | `web.strafe.chat/src/stores/voice.ts` | The LiveKit connection, audio context, mic pipeline (RNNoise in `lib/voice/rnnoise.ts`), self controls, per-user volume, speaking, ringing |
| Client UI | `web.strafe.chat/src/components/voice/` | Stage (tiles + controls), dock, sidebar rows, per-user menu, incoming call |

## Configuration

The API needs three variables; without them voice is off and every call control is
hidden (`GET /` → `features.voice.enabled`):

```
LIVEKIT_URL=wss://chat.example.com/livekit     # what browsers connect to
LIVEKIT_INTERNAL_URL=http://livekit:7880       # server API; defaults to LIVEKIT_URL with ws->http
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...                         # 32+ characters
```

The compose deployment generates the key pair in `setup.sh`, proxies the signalling
WebSocket through Caddy at `/livekit`, and publishes the media ports straight from the
LiveKit container: `7881/tcp` (ICE over TCP), `50000-50200/udp` (media), `3478/udp`
(built-in TURN). LiveKit discovers its public IP through STUN; `LIVEKIT_NODE_IP` pins it.

## Data model

A **voice state** (`voice.State`) is one user in one voice room - Discord's VoiceState:
self mute/deaf, moderator mute/deaf, camera and screen flags, `suppress` (no Speak
permission), `priority_speaker`, `connected`, and a `user` summary so clients can draw
a tile without a member fetch. A user is in at most one voice room across the instance;
joining another leaves the first.

States live in Redis (`voice:room:<id>` hash, `voice:user:<id>` pointer, `voice:rooms`
set) - they describe running connections, nothing that should outlive them. PM / group
PM calls add a `voice:call:<room>` object with who started it and who is still being
rung.

A state is written when a token is issued, confirmed (`connected`) by LiveKit's
`participant_joined` webhook, updated by `track_published`/`track_unpublished` (camera
and screen flags are LiveKit's word, not the client's), and removed by `participant_left`,
`room_finished`, an explicit leave, a moderator, or the reconciler (every 30 s, drops
states LiveKit no longer backs after a 45 s grace).

LiveKit identities are `<user id>.<session id>`; the session part is fresh per join so a
late `participant_left` from an earlier connection cannot remove a newer state. LiveKit
rooms are named `strafe_<room id>`.

## Permissions

Eight room-scoped bits in `permissions/bits.go`, mirrored in
`web.strafe.chat/src/lib/spacePermissions.ts`:

| Bit | Meaning |
| --- | --- |
| Connect | Join the room at all |
| Speak | Publish a microphone; without it the state is `suppress`ed |
| Video | Camera and screen share (with its audio) |
| Use voice activity | Otherwise the client must use push to talk (client-enforced, as on Discord) |
| Priority speaker | Others are ducked while they talk (client-side ducking) |
| Mute members / Deafen members | Server mute / deafen people in the room |
| Move members | Move people between voice rooms, and disconnect them |

`@everyone` gets Connect, Speak, Video and voice activity by default. Existing spaces
were backfilled once at startup (`spaces.BackfillVoicePermissions`, tracked in the
`data_migrations` table). PMs and group PMs need no permissions.

Speak, Video and moderator mute/deafen are enforced by LiveKit, not just the client: the
join token's `canPublishSources` and `canSubscribe` follow the permissions and the
state, and `UpdateParticipant` changes them live when a moderator acts. A server-muted
member cannot re-publish a microphone; a deafened one receives no tracks.

Voice rooms also carry a **user limit** (0-99; Move members bypasses it) and an
audio **bitrate** (8-384 kbps, default 64) - `PATCH /spaces/:id/rooms/:roomId`.

## HTTP API

| Route | Notes |
| --- | --- |
| `POST /rooms/:id/voice/join` | `{self_mute?, self_deaf?}` → `{url, token, room_name, state, states, bitrate, call?}`. Leaves any other room first. Same room again re-issues the token. |
| `POST /voice/leave` | |
| `PATCH /voice/state` | `{self_mute?, self_deaf?, self_video?, self_stream?}` |
| `GET /rooms/:id/voice/states` | `{states, call}` |
| `POST /rooms/:id/call/ring` | `{user_ids?}` - group calls; everyone not yet in it when omitted |
| `POST /rooms/:id/call/decline` | Stops ringing the caller on every device |
| `PATCH /spaces/:id/members/:userId/voice` | `{mute?, deaf?, room_id?}` - each needs its permission in the target's room; audited |
| `DELETE /spaces/:id/members/:userId/voice` | Disconnect (Move members); audited |
| `POST /voice/webhook` | LiveKit → API, verified by LiveKit's signature |

## Gateway events

- `VOICE_STATE_UPDATE` - a full state; with `left: true` for a leave (and `moved_to`
  when a moderator moved them, which is the client's cue to rejoin there). Space rooms:
  on the space channel. PMs: to each participant.
- `CALL_CREATE` / `CALL_UPDATE` / `CALL_DELETE` - PM calls: started (rings the others),
  ringing list changed (`rerung: true` restarts the ringtone), ended. To each participant.
- `READY` carries `voice_states` and `calls` for every room the user can see.

PM rooms also get `call_started` / `call_ended` system messages.

## Client notes

- One `AudioContext` per call, at 48 kHz, carries both directions: the microphone
  pipeline captures into it and LiveKit mixes remote audio out of it (`webAudioMix` with
  our context; LiveKit keeps a muted `<audio>` element per track underneath, which is
  what feeds Chrome's echo canceller its reference). It is created - or resumed -
  *synchronously inside the click that joins*, because that is the only moment browsers
  that gate audio behind a gesture let one start; created later, after the join request
  returned, it would sit suspended and the call would be silent until a tap. Between
  calls it is suspended, and a rejoin nobody clicked for (a moderator move, a reconnect)
  reuses it.
- The microphone is published through a Web Audio pipeline (`lib/voice/micPipeline.ts`):
  input gain → noise suppression → level meter → gate → the track LiveKit sends. Push to
  talk, the manual sensitivity threshold and self-mute drive the gate, so nothing is
  renegotiated when you press a key. Capture-time options (device, suppression, echo
  cancellation, gain control) cannot be changed on a running track, so changing one
  rebuilds the pipeline and republishes.
- **Everything that publishes or unpublishes the microphone goes through one queue**
  (`queueMicWork` in `stores/voice.ts`), the join's first publish included. Two
  overlapping rebuilds each unpublish what they find and publish their own track, which
  leaves a publication nobody is tracking: still transmitting, invisible to the UI, and
  out of reach of mute — the call looks muted while the far end still hears you. A
  request made while a rebuild is already queued folds into it, since a queued rebuild
  reads the settings when it runs. Unpublishing goes by track *source*, not by the
  publication being held, so a session that has already grown a stray microphone heals on
  the next change; mute likewise applies to every microphone publication, not just the
  tracked one. Opus DTX is off: with it the encoder stops between words and the far end fills
  the gaps with generated comfort noise, so the noise floor audibly switches on and off
  around speech (a breathing, pulsing sound). The closed gate sends digital silence,
  which Opus VBR encodes in a few bytes a frame, so continuous frames cost nothing.
- **Noise suppression is RNNoise** (`lib/voice/rnnoise.ts`), Xiph's recurrent-network
  suppressor, shipped with the client as a WebAssembly asset and run in an AudioWorklet
  on the user's device - nothing about the microphone leaves the browser, which is why it
  is the default over the cloud suppressors Discord licenses. It needs the 48 kHz context
  above and adds ~27 ms of latency. The browser's own suppression is a setting
  (`browser`), as is none (`off`); RNNoise replaces the browser's rather than stacking on
  it, since two suppressors in a row eat consonants. The settings page's mic test runs
  the same pipeline, so its meter shows what others hear. There is a toggle on the call
  controls and in the dock too: it switches between off and whichever suppressor settings
  last chose, and rebuilds the microphone pipeline live, because suppression is applied
  at capture and cannot be changed on a running track.
- **Screen share quality is chosen per share** (`lib/voice/screenShare.ts`): 720p / 1080p
  / 1440p / Source, at 15, 30 or 60 fps, defaulting to 1080p30 and remembering the last
  choice. The browser's own "what do you want to share" dialog has no quality controls
  and cannot be extended, so the picker opens first and the choice becomes both the
  capture constraints and the publish encoding - the constraint decides what is grabbed,
  the encoding what LiveKit may spend sending it (1.5-9 Mbps depending on the pair), and
  a high frame rate under a low ceiling only looks smeared. 15 fps also switches the
  content hint to `detail`, which holds text sharp at the cost of motion.
- The **dock** (`VoiceDock.tsx`) is laid out the way Discord's is: the connection status,
  noise suppression and hang up share the top line, the room sits on its own line so a
  long name is readable, then the avatars of *everyone else* in the call (your own is
  left out - you are the user area directly below it), then camera and screen share as
  two wide buttons. On mobile it is portaled to `document.body`: AppShell's swipe track
  is `transform`ed, and a `position: fixed` child of a transformed ancestor is laid out
  against that box, which stretched the dock across the full 200vw track.
- Deafen implies mute (Discord semantics); per-user volume and "mute for me" are local,
  persisted in `localStorage`. Volumes are Web Audio gains, so up to 200%.
- **Voice statistics** (`lib/voice/stats.ts`, the popover behind the dock's status line and
  the stage's wave button) read WebRTC's `getStats()` per track: transport (UDP/TCP, relay),
  round trip, what we send, and per person loss, jitter, concealment and video fps. Loss
  and concealment at zero with audio that still sounds bad means the problem is acoustic
  (two devices in one room feeding each other, a suppressor eating speech), not the
  network.
- Speaking rings come from LiveKit's active-speaker updates, for everyone including you.
  A priority speaker ducks everyone else; the ducking is released 700 ms after they
  stop, because speaker detection flips on every breath and following each flip pumped
  the others' volume.
- Camera and screen tracks are attached straight to `<video>` elements in the tiles. The
  stage measures its tile area and gives every tile an exact 16:9 size that fits
  (`fitTiles` in `VoiceStage.tsx`) - a CSS aspect ratio alone ignored the height and let
  tiles run over the controls on short stages.
- Because the audio context starts in the join click, playback needs no second gesture.
  The "click to enable" banner on the stage is the last resort for a browser that still
  refuses (an autoplay setting that blocks even after a click, iOS Low Power Mode for
  video); its click resumes the context and calls LiveKit's `startAudio` and
  `startVideo` inside the gesture. Nothing on a web page can bypass those settings.
- A page that reloads or closes simply drops the LiveKit connection; the webhook removes
  the state. A LiveKit disconnect we did not initiate waits briefly for the server's
  word (moved? removed?) before acting.

## End-to-end encryption

Calls are end-to-end encrypted, always, with no plaintext fallback. Each media frame is
encrypted on the sending device and decrypted on the receiving ones, so the SFU forwards
ciphertext it cannot read - and neither can the API, the instance operator, or anyone who
captures the traffic.

**Per-sender keys.** Every participant generates their own 32-byte media key and hands it
to the others (`lib/e2ee/callKeys.ts`). Nobody has to agree on one shared secret, so
there is no key-owner election and no race when two people join at once: each person owns
exactly one key and is the only one who rotates it. LiveKit's key provider is built for
this - keys are set per participant identity, with a 16-slot key ring so a rotation and
the key it replaces are both briefly live and nobody's audio cuts out.

**Distribution rides the existing Olm channel.** A key is Olm-encrypted separately to each
recipient *device* and sent over the same to-device channel Megolm room keys already use.
The server relays ciphertext. That means call keys inherit the text E2EE's properties:
real per-device sessions, and safety numbers as the out-of-band backstop against a server
substituting device keys. The sender of an incoming key is taken from the Olm decryption,
never from the payload, and a key claiming a LiveKit identity its sender doesn't own is
dropped. The announcement names the call's room by its federated identity
(`!origin:domain`, the same on every instance) alongside the sender's local id: a PM or a
mirrored channel has a different local id on each instance, and a receiver only installs
a key for the call it is in, so a key filed under someone else's local id would sit
unused and the peer's media would never decrypt.

**Rotation on membership change.** Joining or leaving makes everyone roll their key onto
the next ring slot and redistribute (debounced, so a burst of joins costs one rotation;
serialised, so a change that lands mid-rotation queues rather than races). Someone who
leaves cannot decrypt what follows; someone who joins cannot decrypt what the SFU already
carried. Same policy Megolm text rooms use.

**Order matters.** A key is always handed out *before* a frame uses it: on join, our key
goes to everyone present before the microphone is published, and a rotation sends the
new slot's key first and switches the encoder only once the to-device messages are away.
Switching first would drop our audio at every peer for as long as delivery takes - and
their decoder, having lost the keyframe, would show nothing until the next one. When a
peer's key does arrive late (we joined after their camera was on), the frames before it
were dropped, so the store re-attaches that peer's video once the key is installed; under
adaptive stream that pauses and resumes the subscription and the server answers with a
keyframe at once, instead of waiting for the browser's own request seconds later.

**No silent downgrade.** A browser without insertable streams / encoded transforms is
refused the join with an explanation rather than connecting in the clear, and if enabling
encryption or installing the local key fails the client hangs up instead of continuing.
The stage shows a lock while encrypted, and names anyone whose key hasn't arrived yet.

What this does *not* cover: the server still decides who is in a room, so it could add a
participant your client would then encrypt to - the same trust boundary the text E2EE has,
and the same answer (verify safety numbers). Codec headers stay in the clear because the
SFU needs them to route, so frame sizes and timing are visible; the picture and audio are
not. Verified by pointing a client with valid credentials but no key at a call: it
receives every packet and decodes none of them, rendering noise instead of the picture.

## Calls across instances

A PM or group shared with another instance is hosted by the room's **origin** instance:
its LiveKit carries the media, it mints every token, and it owns the voice states and the
call object. The other instances mirror those over federation (see
`FEDERATION.md`, "Calls across instances"), so everything above - states, events, ringing,
`call_started` / `call_ended` system messages - looks the same there. Two details differ:
participants in such rooms are named `<federated id>.<session>` towards LiveKit (the
`identity` field on a voice state carries it, and the client maps it back through its
federated-id registry), and the join result's `url` is the origin's LiveKit, which the
user's browser must be able to reach. The origin's reconciler and webhooks are the only
ones that matter for these rooms; a mirror never reconciles them against its own LiveKit.

## Not done

- Stage-style rooms, soundboards, and "Go Live" stream discovery.
- Cross-signing, so a new device of someone you already verified is trusted automatically;
  today each device is verified on its own (this is inherited from the text E2EE).
