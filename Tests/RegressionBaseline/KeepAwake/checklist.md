## Keep Awake (`com.spinnet.coffee`)

Accepted stable Level 2 external package 1.0.3, onboarding #95. The original
six-Plugin user-data fixtures remain unchanged; these are additive fixtures.

| Command | Entry and expected behaviour |
| --- | --- |
| `coffee.open` | Open the Ready-to-Use Preset; choose manual, duration or App mode before explicitly starting. Only the selected mode's fields show. |
| `coffee.manual` | Start until stopped; the Host effect continues after the Plugin View closes and the helper retires. |
| `coffee.timed` | Start 30 minutes; the Host countdown expires independently of the helper. |
| `coffee.app` | Bind the App in front at Start; switching Apps does not retarget the effect. App exit ends it. |
| `coffee.activities` | Show only this Plugin's Host Activities; Host-generated Stop needs no Plugin invocation. |

There are no Plugin Settings or external dependencies. The additive stored Menu
Item keeps an alias and a disabled Alternate Action, and explicitly records
empty Plugin Settings. `keep_awake` is granted and optional
`read_frontmost_app` is denied: manual and timed modes still work; App mode
offers access guidance. No System Permission is required for keep-awake.

Removal suppresses the Bundled copy across launches and forgets access. Installing
a copy restores ordinary installed origin and asks again. Revocation, disable,
replacement, removal and Host exit release owned effects; a new launch restores
none. Denied or late work creates no effect. Sleep, lid and critical-battery
policy uses the previously accepted #84/#90 native evidence; this onboarding
adds no new native UI and does not claim renewed physical-system acceptance.
