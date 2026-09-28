# Reflex migration

This candidate is built on Linux in the `Reflex frontend` GitHub Actions workflow.
The first milestone is a minimal compiled browser page. The working JavaScript
application stays at `/` until the full Reflex candidate passes browser parity.

`default.nix` pins reflex-platform and its compiler/dependency graph by commit.
The workflow builds `ghcjs.ripy-frontend`, packages the browser JavaScript, and
loads it in Chromium through the ordinary Fastify server. No Haskell process is
used to serve the page. A native JSaddle development server is not part of this
build or runtime.

## Download and install a successful build

Choose a successful workflow run on the migration branch. Use its full commit
SHA, not the moving branch name, in the following commands:

```sh
gh run download RUN_ID --repo Semi-0/Ripy \
  --name reflex-frontend-COMMIT_SHA --dir /tmp/ripy-reflex-COMMIT_SHA
node scripts/install-frontend.js /tmp/ripy-reflex-COMMIT_SHA COMMIT_SHA
npm start
```

Open `http://localhost:3000/reflex/`. Stop the old server before `npm start` if
port 3000 is already in use. Downloads are not installed automatically.
Installation checks the expected commit and SHA-256 digests, copies into a
staging directory, validates those copied bytes, and only then replaces
`frontend-dist/`. The prior version is retained in `frontend-dist.previous/`.
Hashes detect corruption; download only artifacts from the trusted repository's
successful workflow. They are not an independent signature.

The server's media folder, `.lsp/`, and JavaScript frontend are not modified by
installation. Browser assets are ignored by Git; they belong to the CI artifact.

## Protocol boundary

Video bytes use ordinary HTTP, including byte-range requests. WebSockets never
carry movie bytes. Fastify owns command validation, ordering, revision numbers,
and the authoritative room. The Haskell frontend will own decoding, clock
estimation, snapshot acceptance, UI intentions, and video effects.

| Transport | Direction | Message |
| --- | --- | --- |
| HTTP | browser → server | `GET /api/movies` |
| HTTP | browser → server | `GET /media/:filename`, optional `Range` |
| WebSocket `/room` | browser → server | `select`, `play`, `pause`, `seek`, `ping` |
| WebSocket `/room` | server → browsers | full `state` snapshot |
| WebSocket `/room` | server → requesting browser | `pong` or `error` |

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
