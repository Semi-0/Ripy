# Migration verification

The minimal browser build passed in GitHub Actions run `36482537418` at
`f1913dafac8f70aea57ab37518415ba077303d73`. This established the pinned compiler
before implementing the full frontend.

The complete Reflex candidate passed run `36486451663` at
`9293291323d68f77e38cb1949f853d5be026226d`, including:

- GHCJS browser compilation and a real Chromium load through Node/Fastify.
- Native Haskell tests for JSON, finite numbers, clocks, timeline, bounds,
  late joins, revisions, duplicate/stale snapshots and new epochs.
- Haskell decoding of actual Fastify WebSocket snapshots and JavaScript
  validation of Haskell-encoded commands.
- Two browsers playing, pausing and seeking, either-viewer control and late join.
- Controlled buffering, startup stalls and autoplay rejection/recovery.
- Drift correction, disconnect/reconnect, end-of-movie and rapid replacements.
- Fullscreen entry, exit, double-click, visible errors and local volume.
- Narrow layouts, malformed/stale snapshots and epoch reset.
- Obsolete socket callbacks and a delayed obsolete metadata request.
- Five initial clock samples, 30-second refresh and five-second ping timeout.

The downloaded artifact was also tested on macOS with system Chrome. One local
run timed out during rapid replacement; the subsequent full run passed. The test
now waits for both server acknowledgements before examining decoded video, and
a stress run of 25 replacements passed. Failure diagnostics retain the actual
snapshot, source, position, ready state and error text. CI repeats this transition
five times. This records the observation without claiming a proven cause for
the initial timeout.

The original 11 JavaScript model/server tests passed before retiring the old
frontend. Client clock/snapshot tests were ported to Haskell. The current Node
suite has 12 tests, including artifact validation and missing-build handling.
The final migration commit is rebuilt and tested through the default `/` route.

Browser tests use a generated 30-second H.264/AAC clip. Buffering and autoplay
failures are controlled simulations; real network congestion, Netherlands–Taiwan
throughput, Safari/iOS policies and arbitrary movie codecs are not established
by these tests. No VPS deployment was performed.
