# Plugin API Level 3

Level 3 promotes the proved `spotify_controls` r1, `external_app_connections`
r1, `adaptive_layout` r2 and `homebrew_autoremove` r1 contracts for first-party
onboarding (#94–#98). Declare `"api_level": 3` and omit `candidate_contracts`.
The Host refuses their retired declarations, including `adaptive_layout` r1,
with the Level to declare instead. Older Hosts refuse Level 3 and ask for an
update. Level 1 and Level 2 retain their names, shapes and behaviour.

Use [the Level 3 types](../spinnet-level-3.d.ts),
[catalogue](../catalogue-level-3.json), [manifest schema](../schemas/manifest-level-3.schema.json),
[pages](../schemas/pages-level-3.schema.json), [namespace inputs/results](../schemas/namespaces-level-3.schema.json)
and [type-checked example](../fixtures/level-3/usage.ts).
Runtime entry points keep the existing catalogue IDs; none grants authority.

## Spotify controls and External App connections

`apps.perform` adds `play_pause`, `volume`, `set_volume`, `adjust_volume` and
`next_checked` for the reviewed Spotify interface. Volume is Spotify's own
integer 0–100; adjustment is an integer delta −100–100, clamped on the Host.
The result is the observed volume. `next_checked` makes at most one Next send
and one delayed observation, returning `changed`, `unconfirmed`,
`no_current_track` or `stopped`. It never infers an empty queue or retries a send.
All native calls share the reviewed deadline; a timeout after an effect does
not establish that nothing happened. No cloud account, queue mutation or
arbitrary Apple Events interface is exposed.

Level 3 Spotify calls are prompt-free and target an already-running App.
The manifest's optional `external_app_connections` member names reviewed
Apps and dependent Command IDs. Plugin Settings owns connection status and an
explicit Connect action; only that action may request Automation consent.
Connection setup never starts playback, launches the target or replays an
Action. Required scoped grants still apply, and removal, replacement,
revocation and disable invalidate pending connection work. See the
[connection schema](../schemas/external-app-connections.schema.json) and
[control schema](../schemas/spotify-controls.schema.json).

## Adaptive cards and passive viewport fit

`spinnet.ui.components.adaptive` lays out 1–8 identified cards, using a
160–600 pt desired minimum width, 0–24 pt spacing and at most four columns.
Optional `fit.profiles` declares bounded passive density profiles, ordered
from least to most detailed. The Host selects a profile from available width
and height, distributes remaining height, and retains readable overflow
below the supported minimum. Profiles may override existing passive text,
style and visibility; they cannot supply replacement trees, hide controls,
run a resize script or receive a resize event. Component identity and page
state rules remain those of Level 2. See the [schema](../schemas/adaptive-layout.schema.json)
and [valid/invalid fixtures](../fixtures/level-3/adaptive-layout/index.json).

Native regression tests exercise responsive card layout, readable overflow and
preserved field/editor identity, text, caret and source cadence across size and
density changes. They do not establish current performance, VoiceOver coverage
or acceptance of an installed Plugin.

### Adaptive layout bounds

There are 1–8 children in an adaptive container. `min_card_width` is 160–600 points (default 200).
`spacing` is 0–24 points (default 12); `max_columns` is 1–4 (default 4).
Viewport fit declares 1–3 profiles, each with 0–40 overrides and a
`min_card_height` of 48–600 points. Page-wide component and container-depth
bounds still apply; profiles never introduce replacement components.
The [card fixtures](../fixtures/level-3/adaptive-cards/index.json) also cover
adaptive containers without viewport fit.

## Homebrew unused dependencies

`tools.read({tool:"homebrew",operation:"previewAutoremove"})` reads a bounded
dry run and is also a visible-page source. It takes no selectors. The result
distinguishes failed or incomplete dry runs, truncation and an empty successful
result. It uses the native CLI without pinning private Homebrew source revisions.
`tools.startTask.operation({tool:"homebrew",operation:"autoremove"})` enters
the existing Host-reviewed Task flow with separate mutation authority and
a fresh Host Confirmation for the resolved targets. A Plugin cannot supply
argv, paths, shell text or repair scripts. Stop attempts never promise rollback;
recovery restores status without replaying a mutation. See the
[schema](../schemas/homebrew-autoremove.schema.json) and
[fixtures](../fixtures/level-3/homebrew-autoremove/index.json).

## Distribution and evidence

Bundled Plugins declare only stable Levels, use ordinary scoped grants and
remain removable. Promotion and packaging reuse the accepted external UX;
public-schema and helper checks prove contract compatibility, while native
permissions and actual system effects retain their separately recorded
acceptance limits. The deferred Homebrew mutation/recovery/authorization
observations remain tracked by #101.
