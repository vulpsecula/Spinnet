# Homebrew additive onboarding baseline

| Command | Behaviour retained from the accepted package |
| --- | --- |
| `brew.open` | Open the management navigation page |
| `brew.installed`, `brew.search`, `brew.outdated` | Browse installed, discoverable and outdated packages |
| `brew.update` | Refresh the Homebrew catalog under its separately scoped Level 7 grant before browsing |
| `brew.vulnerabilities`, `brew.doctor` | Scoped advisory reports and reviewed diagnostic guidance |
| `brew.adopt` | Review candidate applications before explicit adoption |
| `brew.upgrade` | Preview selected or all upgrades before confirmation |
| `brew.services`, `brew.services-menu` | Browse services or open the controlled Services menu |
| `brew.taps` | Review taps and trust changes |
| `brew.cleanup`, `brew.autoremove` | Review cleanup and unused-dependency removal |
| `brew.clear-cache` | Clear this Plugin's cache |

Accepted source: independent #93, `f6a9d91c96f12e0d23697f9802f3d29228483978`, version 1.5.0. Packaging promotes retired `adaptive_layout` r2 and `homebrew_autoremove` r1 to stable API Level 3. The historical manifest is byte-preserved here solely to prove saved Action identity. No retired candidate is registered. The six-Plugin historical baseline remains unchanged.

Automated seams:
- All 14 saved Commands, alias, primary/alternate order and disabled choices survive migration and restart. Empty Plugin Settings remain byte-preserved; grant/denial scopes survive reconciliation and serialization.
- All 66 accepted public helper tests cover actual generated scripts, bounded browsing, package details, search, preview, selected/all upgrades, taps/trust, services, Doctor, adoption, vulnerability selection/batching, link/unlink, cache, and viewless Task outcome/reopen without replay. Recorded answers never perform real mutations.
- Bundled origin has no authority: the real broker denies an undecided read before tool discovery and reports a typed missing dependency only after a valid grant.
- Removal forgets grants, Plugin Storage and Host preferences, invalidates its owner, retains unavailable Menu Actions, and stays suppressed after launch. Installing a copy has installed origin and undecided grants.
- Shared reviewed-Task lifecycle tests cover owner detachment, retained Host Stop, confirmation and journal recovery without replay. Removing a Plugin detaches confirmed work; it does not imply rollback or cancellation.

Native acceptance remains explicit: verify missing/denied states visually, all Homebrew workflows in Runtime Mode, Pin/resize layout, readable full Doctor diagnostics, and Status Item/Stop/normal exit. Actual package/service/trust mutations, privileged authorization, crash recovery and administrator/system observations remain deferred in #101. No live Homebrew mutation or administrator operation is run by this baseline.
