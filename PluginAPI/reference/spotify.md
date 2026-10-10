# Local Spotify (Plugin API Level 2, #85)

`apps.perform` accepts the Reviewed App Interface for `com.spotify.client`:
`playback` belongs to `playback_read`; `play`, `pause`, `previous` and `next`
belong to `playback_control`. Each takes no arguments. The user's
`control_external_app` scope names the target and each required family.
There is no OAuth, cloud search, playlist, remote-device or arbitrary scripting API.

`playback` returns `{state, position, track}`. State is playing, paused or
stopped; position is seconds. Track is null when none is available, otherwise
contains bounded id, name, artist, album (512 characters each), duration in
seconds (the desktop Spotify API returns milliseconds despite its installed
scripting dictionary's description), and optional artwork_url. Position and
duration are bounded to 604800 seconds. Artwork is an HTTPS `i.scdn.co` address
of at most 2048 bytes; displaying it requires a separate declared and granted
`contact_https` capability. A URL carries no access of its own. Transport
returns null; play resumes, pause pauses, previous/next use Spotify's own
transport semantics. It never starts a chosen cloud track or remote device.

A visible page may declare the read only:

```js
spinnet.apps.perform.source("playback", {
  bundle_id: "com.spotify.client", operation: "playback"
}, {every: 1, deliver: {pointer: "/track"}})
```

Sources check running state before Automation permission and never launch
Spotify or prompt. They fail with external_app_missing, external_app_not_running,
automation_permission_needed (no decision yet), automation_permission_denied,
external_app_operation_unsupported or host_service_failed. A user-chosen page
action may request a harmless playback read to let macOS ask for Automation.
No automatic consent or dependency installation occurs. Samples have a
three-second deadline and fixed Apple Events have a two-second timeout.

Bindings update without a Plugin invocation; change-gated deliveries keep the
existing fifteen-second floor. A hidden/closed page cancels reads and discards
late answers. Revocation, replacement, disable and removal invalidate the
accepted owner; a revoke/regrant cannot admit a late result from the old read.
Already-sent transport operations cannot be undone by cancellation.

The Host's reviewed native adapter follows the installed Spotify.sdef, not
Plugin-supplied source. Real track values and transport UX still need checking
with Spotify and Automation allowed by the user. Schemas and recorded answers
alone cannot establish those native semantics.
