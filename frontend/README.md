# Reflex migration

This candidate is built on Linux in the `Reflex frontend` GitHub Actions workflow.
The minimal compiled page passed CI at commit
`f1913dafac8f70aea57ab37518415ba077303d73` (run `36482537418`). The full Reflex
candidate passed browser parity at `9293291323d68f77e38cb1949f853d5be026226d`
(run `36486451663`) before becoming the default page. The old JavaScript frontend
is preserved in Git history on `main`, not loaded alongside the Reflex application.

`default.nix` pins reflex-platform and its compiler/dependency graph by commit.
The workflow builds `ghcjs.ripy-frontend`, packages the browser JavaScript, and
loads it in Chromium through the ordinary Fastify server. No Haskell process is
used to serve the page. A native JSaddle development server is not part of this
build or runtime. The pin is
`f231e2425ac92339b8491cdd970930d63d9ad1ad`; its transitive package pins include
Reflex-DOM `5d1dbde4471d7f9be60977b972ab0219026ff5dc`. CI explicitly installs
Nix `2.35.2`, the version verified in the successful compiler build.

## Source responsibilities

- `src/Protocol.hs`: wire types, explicit JSON mappings and numeric validation.
- `src/Model.hs`: pure timeline, clamping, clock sampling and snapshot acceptance.
- `app/Catalog.hs`: catalog callbacks converted into a catalog `Dynamic`.
- `app/View.hs`: Reflex widgets that emit typed intentions carrying their values.
- `app/Network.hs`: snapshot acceptance, pure intention reactions and derived UI.
- `app/Connection.hs`: typed socket events around clock and reconnect resources.
- `app/Player.hs`: typed video inputs/state around loading, playback and drift resources.
- `app/Bindings.hs`: small foreign calls to browser APIs, without room policy.
- `src/VoiceProtocol.hs`: explicit JSON types for the independent voice protocol.
- `app/Voice.hs`: voice FRP state plus private WebRTC resource handles.
- `app/VoiceView.hs`: behavior-free voice presentation built from generic atoms.
- `app/VoiceBindings.hs`: small microphone, audio and WebRTC browser calls.
- `app/Main.hs`: recursive composition of the frontend event graph.

`Main.app` holds no application `IORef`. It composes intentions into reactions,
reactions into commands and local video effects, accepted snapshots into desired
playback, and current signals into `Ui`. The connection and player adapters keep
only resource handles, clock samples and asynchronous cancellation generations
mutable. `acceptSnapshots` is the single room-state fold, and `deriveUi` is a
pure projection from current signals.

The finite Kiroshi candidate model in `system-model-proposal.edn` records these
components, effect boundaries and invariants with repository evidence. Every
fact passes `kiroshi propose` and remains non-persisted pending human review.

The frontend uses GHCJS's browser FFI. These small bindings call APIs such as
`WebSocket`, `HTMLVideoElement.play()` and fullscreen. No handwritten JavaScript
module implements synchronization. Incoming snapshots do not produce explicit
user commands. `mergeWith (++)` preserves simultaneous event lists with user
commands ordered before media-observation commands.

Connection callbacks and asynchronous player work have separate generation
counters. Closing a socket invalidates its generation immediately. Replacing a
movie or disconnecting invalidates pending metadata/play effects. Video bytes
remain independent HTTP requests throughout.

Voice is a second network with no dependency on `Player`, `Connection`,
`Network`, or movie protocol types. `Main` is the specialization point that
connects raw voice view signals to `VoiceInputs`. The voice adapter keeps only
live browser resource handles, queued ICE, and callback generations mutable;
phase, mute, and autoplay-recovery state are folded in Reflex.

## Download and install a successful build

Choose a successful workflow run on the migration branch. Use its full commit
SHA, not the moving branch name, in the following commands:

```sh
gh run download RUN_ID --repo Semi-0/Ripy \
  --name reflex-frontend-COMMIT_SHA --dir /tmp/ripy-reflex-COMMIT_SHA
node scripts/install-frontend.js /tmp/ripy-reflex-COMMIT_SHA COMMIT_SHA
npm start
```

Open `http://localhost:3000/` (`/reflex/` also serves the compiled page). Stop the old server before `npm start` if
port 3000 is already in use. Downloads are not installed automatically.
Installation checks the expected commit and SHA-256 digests, copies into a
staging directory, validates those copied bytes, and only then replaces
`frontend-dist/`. The prior version is retained in `frontend-dist.previous/`.
Hashes detect corruption; download only artifacts from the trusted repository's
successful workflow. They are not an independent signature.

The server's media folder and `.lsp/` are not modified by installation. Browser
assets are ignored by Git; they belong to the CI artifact. CI publishes assets
even after a browser-test failure for diagnosis; install only a successful run
for normal use. The artifact's presence alone is not proof of passing tests.

## Protocol boundary

Video bytes use ordinary HTTP, including byte-range requests. WebSockets never
carry movie bytes. Fastify owns command validation, ordering, revision numbers,
and the authoritative room. The Haskell frontend owns decoding, clock
estimation, snapshot acceptance, UI intentions, and video effects.

| Transport | Direction | Message |
| --- | --- | --- |
| HTTP | browser → server | `GET /api/movies` |
| HTTP | browser → server | `GET /media/:filename`, optional `Range` |
| WebSocket `/room` | browser → server | `select`, `play`, `pause`, `seek`, `ping` |
| WebSocket `/room` | server → browsers | full `state` snapshot |
| WebSocket `/room` | server → requesting browser | `pong` or `error` |
| HTTP | browser → server | `GET /api/voice/ice` |
| WebSocket `/voice` | browser ↔ server | `offer`, `answer`, `ice`, `leave` and pairing events |
| WebRTC | browser ↔ browser or TURN | Opus audio track |

```json
{"type":"select","mediaId":"453.MP4"}
{"type":"play"}
{"type":"pause","reason":"buffering"}
{"type":"seek","positionSeconds":120}
{"type":"ping","clientSentAtMs":100000}
```

Pause reasons sent by clients are `user`, `buffering`, and `ended`. Omitting
`reason` retains the server's existing `user` default.

```json
{"type":"state","epoch":"server-start-uuid","revision":12,"mediaId":"453.MP4","mode":"playing","positionSeconds":120,"anchorServerTimeMs":100100,"pauseReason":null}
{"type":"pong","clientSentAtMs":100000,"serverTimeMs":100040}
{"type":"error","code":"UNKNOWN_MEDIA","message":"Movie is unavailable."}
```

At estimated server time `101100`, the example playing snapshot targets 121
seconds. A paused snapshot stays at its anchor position. A new epoch denotes a
server restart; revisions are compared only within an epoch.
