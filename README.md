# Ripy — cloud cinema

A small movie website you own: Fastify serves MP4 files, and one shared
WebSocket room coordinates two browser players. Either viewer can select a
movie, play, pause, or seek. Volume remains local. The frontend is written in
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

Use **[ fullscreen ]** or double-click the video to expand the player and shared
controls. Use **[ exit fullscreen ]** or Escape to leave fullscreen. This is
local to your browser. The page uses a monochrome, monospace interface.

Configuration is intentionally small:

```sh
PORT=3001 MEDIA_DIRECTORY=/absolute/path/to/movies npm start
```

The server always binds to `127.0.0.1`. There is no login system, upload endpoint,
database, Lain integration, transcoding, or public deployment in this example.

## How it works

```text
Browser A ── HTTP byte ranges ──┐
                              ├── Fastify ── approved media folder
Browser B ── HTTP byte ranges ──┘

Browser A ◀── commands/state ──▶ Shared room ◀── commands/state ──▶ Browser B
```

- `src/catalog.js`: reads approved files and creates public movie URLs.
- `src/room.js`: pure room transitions, with time supplied by the caller.
- `src/protocol.js`: validates incoming commands and produces precise errors.
- `src/server.js`: HTTP delivery and WebSocket effects; owns the in-memory room.
- `src/timeline.js`: pure authoritative server timeline calculation.
- `frontend/src/Protocol.hs`: explicit Aeson protocol encoders and decoders.
- `frontend/src/Model.hs`: pure position, revision, epoch and clock calculations.
- `frontend/app/View.hs`: Reflex-DOM interface and user intentions.
- `frontend/app/Connection.hs`: sockets, clock sampling, timeout and reconnection.
- `frontend/app/Player.hs`: media effects, cancellation, drift and recovery.
- `frontend/app/Bindings.hs`: small browser API bindings.
- `frontend/app/Main.hs`: composition and ordered command batches.
- `public/style.css`: monochrome terminal styling; no handwritten JS application remains.

The movie bytes never pass through WebSockets. `@fastify/static` handles HTTP
range requests, allowing the browser to request a portion and seek without
first downloading the entire file. Each viewer receives their own stream.

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
| `GET /media/:filename` | Approved MP4; supports `Range` / `206` responses |
| WebSocket `/room` | Room state, commands, ping/pong, errors |

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
the server tests remain. The final Node suite contains 12 tests.

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
volume. Additional checks inject malformed/stale snapshots and new epochs,
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

Use a process supervisor, persistent media storage, and monitor disk space and
outbound transfer. A 5 Mbps movie watched by two people uses roughly 10 Mbps
outbound and 9 GB over two hours, before overhead. Start with prepared files and
Direct Play-style delivery; live conversion needs a separate design and more
CPU/GPU resources. Test simultaneous playback from both homes before relying
on the setup for movie night.

The room is intentionally in memory. Scaling across multiple server processes,
durable sessions, adaptive streaming, and automated resume after buffering are
future work, not features of this prototype.
