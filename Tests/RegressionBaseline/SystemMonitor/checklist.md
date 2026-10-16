# System Monitor regression additions (#97)

This additive baseline extends the six-Plugin checklist in the parent directory.
Historical configuration, grants and Plugin Settings there stay unchanged.
System Monitor 1.3.0 retains the accepted #92 identity and runtime script from
source dd12f91314c4a0d74eb7c3db3e4f954050cfa361, migrating its manifest to stable
Plugin API Level 3 from adaptive_layout revision 2. It declares no Plugin Settings
fields or External App dependency, and needs no macOS System Permission.

- `monitor.show`: open one resizable page with CPU busy fraction, used physical
  memory, available startup Data-volume capacity and internal battery charge.
  No historical chart, process ranking, temperature or network rate is added.
- The same four cards and seven source bindings survive compact, standard and
  spacious presentation. All primary labels/values stay visible. Minimum outer
  size is 440 × 420 pt; supported 440 × 700, 860 × 420, 860 × 650 and 1200 × 800
  frames retain readable content and fill usable space. Unsupported extremes
  use bounded readable overflow. No editable fields make IME checks applicable.
- `system.metrics` samples once per second only while visible, with no Plugin
  deliveries or resident helper. Hide/close stops sampling and discards the CPU
  baseline. Reopening starts fresh, without catching up on hidden time.
- First CPU reading, unavailable disk and absent battery show unavailable values;
  a missing battery's detail says no battery or unavailable. Primary unavailable
  values remain visible even when the compact profile hides auxiliary details.
- Pin and resizing retain their accepted shared Host behavior. Denying or revoking
  `read_system_status` prevents reads for Bundled and user-installed copies alike.
  Late answers after hide, close or owner invalidation never replace the page.
- Fixture launch/save retains the Action ID, user alias, empty Menu Slot, empty
  Plugin Settings and exact grant scope. A denied stored grant remains unavailable.
- Removal keeps the configured Menu Item unavailable, forgets grants, clears Plugin
  Storage and Pin preference, invalidates its owner and suppresses the shipped
  copy across launches. Installing a copy restores installed origin and asks for
  access again, while the shipped copy stays suppressed underneath it.

The imported complete-package/helper tests retain recorded lifecycle/authority
checks and actual read-only OS sampling. New distribution and Host regression
checks cover ordinary grants, saved data, removal and suppression. The accepted
#92 native metrics/Pin/resize and five-size visual UX evidence is reused because
monitor.js is byte-identical; this onboarding does not claim a new manual visual
run or batteryless hardware test. VoiceOver remains excluded by user decision.
