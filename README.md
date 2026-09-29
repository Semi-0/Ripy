# Ripy — cloud cinema

A small movie website you own: Fastify serves MP4 files, one shared WebSocket
room coordinates two browser players, and an independent WebRTC connection
carries a private two-person voice call. Either viewer can select a movie,
play, pause, or seek. Volume and microphone mute remain local. The frontend is written in
Haskell with Reflex-DOM and compiled to browser JavaScript by Linux CI. The
server stays JavaScript; Node.js alone runs the installed application.

## Run

Requires Node.js 22 or newer, npm, and a compiled frontend artifact. Haskell,
GHCJS and Nix are not needed on your Mac or on the serving machine.

```sh
git clone https://github.com/Semi-0/Ripy.git
cd Ripy
npm ci
# Download and install the successful CI artifact as described below.
npm start
```

The existing local checkout is `/Users/linpandi/Ripy`. During migration, use
branch `codex/reflex-frontend`; `main` remains unchanged for review. Follow
[frontend/README.md](frontend/README.md) to download the artifact for a full
commit SHA and install it with:

```sh
node scripts/install-frontend.js DOWNLOAD_DIRECTORY COMMIT_SHA
```

The installer stages and verifies the artifact before replacing assets and
retains the preceding installation in `frontend-dist.previous/`. Without an
installed build, `/` returns installation instructions with HTTP 503. Runtime
does not build Haskell automatically. Paths below are relative to this checkout.

Open **http://localhost:3000** in two browser windows. Add your own
browser-compatible MP4 files to `media/`, restart the server, and
refresh both windows. H.264 video with AAC audio in an MP4 container is a useful
starting point. The server does not convert files. It reads the catalog once at
startup, including only immediate regular `.mp4` files (not symlinks).

No movie is bundled or downloaded automatically. For a local synthetic demo,
if FFmpeg is installed, run this from the repository root, then restart the server:

```sh
ffmpeg -f lavfi -i testsrc2=size=640x360:rate=24 -f lavfi -i sine=frequency=220:sample_rate=44100 -t 30 -c:v libx264 -pix_fmt yuv420p -c:a aac -movflags +faststart media/demo.mp4
```

The webpage explains where to add files when the catalog is empty. Browser
autoplay restrictions may require each viewer to click **Enable playback**.
Voice is opt-in: each viewer clicks **Join voice** and grants microphone
permission. **Leave voice** closes the peer connection and stops that browser's
microphone tracks. Movie playback continues when voice joins, leaves, or
reconnects. While the other viewer is speaking, the browser temporarily lowers
the movie to 25% of your chosen volume and restores your latest setting after
the remote microphone becomes quiet.

Use **[ fullscreen ]** or double-click the video to expand the player and shared
controls. Use **[ exit fullscreen ]** or Escape to leave fullscreen. This is
local to your browser. The page uses a monochrome, monospace interface.

Configuration is intentionally small:

```sh
PORT=3001 MEDIA_DIRECTORY=/absolute/path/to/movies npm start
```

The server defaults to `127.0.0.1`. To watch from devices on the same local
network, stop the existing server and run `npm run start:lan`. Open
`http://YOUR_MAC_LAN_IP:3000` on each device. Keep this Mac awake while watching.
`HOST` can also select a specific network interface address. LAN mode listens
on all IPv4 interfaces; anyone who can reach port 3000 can join the room and
access the movies.

Movie playback works over LAN HTTP, but browsers expose the microphone only in
a secure context. `http://localhost` is a special exception; a second device
opening `http://YOUR_MAC_LAN_IP:3000` needs HTTPS before voice can join.

There is no login system, upload endpoint,
database, Lain integration, transcoding, or public deployment in this example.

## How it works

```text
Browser A ── HTTP byte ranges ──┐
                              ├── Fastify ── approved media folder
Browser B ── HTTP byte ranges ──┘

Browser A ◀── commands/state ──▶ Shared room ◀── commands/state ──▶ Browser B

Browser A ◀────── WebRTC audio, peer to peer ──────▶ Browser B
           └── `/voice` signaling via Fastify ──┘
```

- `src/catalog.js`: reads approved files and creates public movie URLs.
- `src/room.js`: pure room transitions, with time supplied by the caller.
- `src/protocol.js`: validates incoming commands and produces precise errors.
- `src/server.js`: HTTP delivery and WebSocket effects; owns the in-memory room.
- `src/timeline.js`: pure authoritative server timeline calculation.
- `src/voice-protocol.js`: strict bounded SDP and ICE message validation.
- `src/voice-room.js`: two-person role assignment and signaling relay.
- `src/voice-ice.js`: STUN configuration and expiring TURN credentials.
- `frontend/src/Protocol.hs`: explicit Aeson protocol encoders and decoders.
- `frontend/src/Model.hs`: pure position, revision, epoch and clock calculations.
- `frontend/src/Ducking.hs`: pure remote-activity smoothing and effective-volume policy.
- `frontend/app/View.hs`: Reflex-DOM interface and user intentions.
- `frontend/app/Connection.hs`: sockets, clock sampling, timeout and reconnection.
- `frontend/app/Player.hs`: media effects, cancellation, drift and recovery.
- `frontend/app/Bindings.hs`: small browser API bindings.
- `frontend/src/VoiceProtocol.hs`: explicit voice signaling and ICE JSON types.
- `frontend/app/Voice.hs`: independent voice FRP network and resource boundary.
- `frontend/app/VoiceView.hs`: behavior-free composition of generic view atoms.
- `frontend/app/VoiceBindings.hs`: small WebRTC and microphone browser bindings.
- `frontend/app/Main.hs`: composition and ordered command batches.
- `public/style.css`: monochrome terminal styling; no handwritten JS application remains.

The movie bytes never pass through WebSockets. `@fastify/static` handles HTTP
range requests, allowing the browser to request a portion and seek without
first downloading the entire file. Each viewer receives their own stream.

Voice audio does not pass through Fastify. Fastify only pairs two clients and
relays SDP/ICE signaling. The browser sends media directly to the other browser,
or through TURN when direct connectivity fails.

The server processes commands in arrival order and broadcasts complete room
snapshots. When a movie is playing, its target position is:

```text
anchor position + max(0, estimated server time - anchor time) / 1000
```

Browsers take five ping/pong samples and use the sample with the shortest round
trip to estimate clock offset. They refresh this estimate every 30 seconds.
Once per second, an actively playing client corrects drift over 0.5 seconds.
This is approximate synchronization, not frame-accurate playback.

Remote state application does not send user commands back. Player updates are
guarded by a generation counter, and a newer snapshot cancels obsolete metadata loading and ignores
obsolete effects. Reconnection first recalibrates the clock and applies the
latest snapshot. During a disconnection the local player pauses and shared
controls are disabled; the other viewer may continue. The client retries every
two seconds. Server restart creates a new empty room and epoch.

If a player buffers during playback, it asks the room to pause. Both viewers
see the buffering reason and resume manually. If the browser blocks autoplay,
that viewer must explicitly enable playback and then catches up to the room.
An end-of-movie event pauses the room.

A play request still waiting for media data after two seconds also requests a
shared pause. This covers startup buffering before the first frame plays.

## Protocol

HTTP endpoints:

| Endpoint | Response |
| --- | --- |
| `GET /` | Movie webpage |
| `GET /assets/style.css` | Monochrome stylesheet |
| `GET /reflex/...` | Compiled Haskell assets (also available as a preview page) |
| `GET /api/movies` | `{ "movies": [{ "id", "title", "url" }] }` |
| `GET /api/voice/ice` | Browser ICE servers and short-lived TURN credentials |
| `GET /media/:filename` | Approved MP4; supports `Range` / `206` responses |
| WebSocket `/room` | Room state, commands, ping/pong, errors |
| WebSocket `/voice` | Two-person WebRTC signaling |

Browser-to-server messages:

```json
{"type":"select","mediaId":"example.mp4"}
{"type":"play"}
{"type":"pause"}
{"type":"pause","reason":"user"}
{"type":"pause","reason":"buffering"}
{"type":"pause","reason":"ended"}
{"type":"seek","positionSeconds":120}
{"type":"ping","clientSentAtMs":100000}
```

Optional pause reason defaults to `user`. Additional fields and unknown types
are rejected. Seek positions must be finite and nonnegative. The browser
bounds its slider to the actual duration; the server has no media-duration
probe and does not enforce an upper bound. Players clamp incoming targets to
their loaded duration.

State snapshots, sent on join and after each accepted playback command:

```json
{
  "type": "state",
  "epoch": "server-start-uuid",
  "revision": 12,
  "mediaId": "example.mp4",
  "mode": "playing",
  "positionSeconds": 120,
  "anchorServerTimeMs": 100100,
  "pauseReason": null
}
```

Modes are `empty`, `paused`, and `playing`. Empty rooms have no media and a zero
position. Selection pauses at zero with `pauseReason: "selected"`; playback
clears the reason. Revisions increase on accepted commands, including repeated
commands. Snapshots with old/duplicate revisions in the same epoch are ignored.

Private replies to the requesting client:

```json
{"type":"pong","clientSentAtMs":100000,"serverTimeMs":100040}
{"type":"error","code":"UNKNOWN_MEDIA","message":"Movie is unavailable."}
```

Errors include `INVALID_MESSAGE`, `UNKNOWN_MEDIA`, `NO_MEDIA`, and
`INTERNAL_ERROR`. Invalid commands leave the room unchanged. Messages have a
4 KiB maximum size. Cross-origin browser WebSocket connections are rejected;
this is a local-demo safeguard, not authentication.

Voice signaling uses:

```json
{"type":"offer","sdp":"..."}
{"type":"answer","sdp":"..."}
{"type":"ice","candidate":"...","sdpMid":"0","sdpMLineIndex":0}
{"type":"leave"}
```

The server assigns the first participant `offerer` and the second `answerer`.
It sends `waiting`, `peer-ready`, relayed `offer`/`answer`/`ice`, `peer-left`,
or an `error`. A third participant receives `ROOM_FULL`. SDP is limited to
32 KiB and ICE candidates to 4 KiB.

## Verify

```sh
npm test
npm run test:browser
```

`npm test` uses Node's test runner and real Fastify HTTP/WebSocket handlers.
It covers transitions, timing, ordering, epochs, malformed input,
late joining, reconnection snapshots, catalog restrictions, range responses,
blocked traversal paths, artifact validation and frontend serving. All original
11 JavaScript tests passed before removal of the legacy browser modules. The two
client-only calculation tests moved to Haskell with the functions they exercise;
the server tests remain. The current Node suite contains 22 tests.

Linux CI also runs the Haskell model tests, feeds actual Fastify snapshots into
the Haskell decoder, and sends Haskell-encoded commands through the JavaScript
validator. The pinned toolchain and source layout are documented in
[frontend/README.md](frontend/README.md).

`npm run test:browser` additionally requires **Google Chrome** and **FFmpeg**
on your machine. It generates a temporary 30-second synthetic clip, starts an
ephemeral localhost server, and checks two headless Chrome pages. It verifies
shared playback/seek, late joins, reconnection, and the end of a movie. Buffering
and autoplay rejection are controlled simulations. It also checks drift correction,
startup stalls, movie-selection reset, narrow layouts, fullscreen and local
volume. It also uses fake microphone devices to verify two-person WebRTC audio,
local mute, automatic local movie-volume ducking, leave/rejoin, voice autoplay
recovery, and signaling reconnection without changing movie state. Additional
checks inject malformed/stale snapshots and new epochs,
delay an obsolete metadata request, dispatch events from a closed socket,
observe the 30-second clock refresh and suppress pongs to trigger the five-second
timeout. Screenshots are written to
`test-results/`; temporary movies are removed afterward.

Cross-country throughput, real congestion, Safari/mobile autoplay policies,
and arbitrary movie formats require testing on your actual devices. Two tabs
on one machine do not measure the Netherlands–Taiwan connection.

## Later: Vultr deployment

Keep the application bound to localhost and put an HTTPS reverse proxy in
front of it. Configure WebSocket upgrades and HTTP range forwarding. Add access
protection to **both video URLs and room connections**, such as a shared login
implemented by your proxy or a private VPN. Protect the catalog and webpage as
well. Configure trusted proxy/origin handling for the chosen HTTPS deployment;
the current origin check assumes direct localhost HTTP access.

Voice also requires HTTPS/WSS and a TURN server for reliable Netherlands–Taiwan
connectivity. Ripy is ready for a coturn-style shared secret:

```sh
VOICE_STUN_URLS=stun:turn.example.com:3478 \
VOICE_TURN_URLS=turn:turn.example.com:3478?transport=udp,turns:turn.example.com:5349?transport=tcp \
VOICE_TURN_SHARED_SECRET='replace-with-coturn-static-auth-secret' \
VOICE_TURN_TTL_SECONDS=3600 \
npm start
```

Comma separates multiple URLs. `VOICE_TURN_URLS` and
`VOICE_TURN_SHARED_SECRET` must be configured together. The server derives
temporary HMAC-SHA1 credentials and returns them with `cache-control: no-store`;
the shared secret stays on the server. Configure the same secret in coturn,
restrict relay ports in the firewall, and test from both homes. TURN bandwidth
is separate from movie delivery and is much smaller for audio, but it still
uses server transfer when direct peer connectivity fails.

Use a process supervisor, persistent media storage, and monitor disk space and
outbound transfer. A 5 Mbps movie watched by two people uses roughly 10 Mbps
outbound and 9 GB over two hours, before overhead. Start with prepared files and
Direct Play-style delivery; live conversion needs a separate design and more
CPU/GPU resources. Test simultaneous playback from both homes before relying
on the setup for movie night.

The room is intentionally in memory. Scaling across multiple server processes,
durable sessions, adaptive streaming, and automated resume after buffering are
future work, not features of this prototype.
