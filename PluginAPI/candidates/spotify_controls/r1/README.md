# Spotify controls, revision 1

Declare `api_level: 2` and `candidate_contracts: [{"name":"spotify_controls","revision":1}]`.
This exact Candidate Contract adds operations to the Reviewed App Interface
`com.spotify.client` through existing `apps.perform` entry points. Stable Level 2
operations and their result shapes remain unchanged. Installation, recovery,
registration, runtime and helper invocation require the exact declaration;
Bundled Plugins cannot declare candidates. Pin public kit and helper to the same
exact source commit. This is no stable Level promotion.

[Declaration](candidate.json), [schema](spotify-controls.schema.json),
[types](spotify-controls.d.ts), [fixtures](fixtures/index.json).
The existing Level 2 SDK forwards these inputs; no new SDK builder is added.

| Operation | Arguments | Result | Scope family |
| --- | --- | --- | --- |
| `play_pause` | empty | `null` | `playback_control` |
| `volume` | empty | `{volume: integer 0..100}` | `playback_read` |
| `set_volume` | `{volume: integer 0..100}` | observed volume | `playback_control` |
| `adjust_volume` | `{delta: integer -100..100}` | observed volume | `playback_control` |
| `next_checked` | empty | `{outcome: ...}` | `playback_control` |

Inputs reject extra keys, missing keys, nonnumbers, nonfinite values, fractions
and values outside the declared bounds before native dispatch. Adjustment clamps
the resulting target to 0..100 and returns the volume read back after the write.
A concurrent external volume change may affect that observation. Volume refers
to Spotify's own sound volume, not system output volume. Concurrent adjustments
are separate requests and do not promise an atomic increment.

`next_checked` returns `stopped` without sending Next when Spotify is stopped,
or `no_current_track` on known absent current track. For playing or paused state
with a valid ID it sends at most one Next, waits 150 ms inside the shared execution
budget, and observes the track ID once. `changed` means the observed ID differs;
it does not establish causation. `unconfirmed` means unchanged, absent or invalid
post-command ID, or expired post-command observation. Expiry before the Next send is a typed Host failure and sends no
Next; it cannot report an attempted effect. It never retries Next.
Permission, app termination and other known native errors remain typed failures;
a timeout after the Next effect may already have occurred is not a safe retry.
Identical IDs, repeat, ads and delayed state cannot establish an empty queue.
The local Reviewed App Interface exposes no queue introspection; no cloud API,
OAuth scope, device selection or queue mutation is added.

A Plugin declaring this candidate never prompts for Automation permission during
a synchronous Spotify call, including its stable play/pause/previous operations.
Legacy manifests keep their existing stable prompting behavior. Only an explicit
Requested Host Operation for the stable playback read may prompt for a declaring
Plugin; the Host sets this provenance outside the wire protocol. New controls
remain prompt-free through every entry point.
`automation_permission_needed` uses existing Host repair guidance; an explicit
Requested Host Operation for the stable `playback` read can request consent.
New controls target an already-running process and never launch or reconnect to
Spotify. Native sends share a monotonic three-second deadline after permission
preflight; each send receives only the remaining budget. There is one bounded
observation delay and no polling. A write that times out may already have taken
effect; do not retry automatically. New operations are not Host-Run Sources;
the existing `playback` Source remains the only Spotify Source.
