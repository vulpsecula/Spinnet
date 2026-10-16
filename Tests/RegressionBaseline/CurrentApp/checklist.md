# Current App regression additions (#94)

This additive baseline extends the six-Plugin checklist in the parent directory.
The historical configuration, grants and Plugin Settings there stay unchanged.
Current App declares no Plugin Settings fields and has no External App dependency.
Its accepted package is 2.0.0, stable Plugin API Level 2, retaining
`com.spinnet.probe.current-app` from the ordinary installed proof in #89.

- `current.close`: the default Primary Action reviews the working App and offers
  Close Window first; opening the page performs no exit.
- `current.quit`: the default Alternate Action reviews the working App and offers
  Quit first. It retains a previously disclosed target until Refresh Target or an
  explicit configured call reads the current App again.
- `current.inspect`: review the working App, its bundle identity and available
  exits. A changed working App does not silently replace the disclosed target.
- Close Window acts on the disclosed App's enabled Command-W item; Quit acts on
  its enabled Command-Q item. Unsupported exits are omitted, and an unsupported
  configured preference is explained without substituting Force Quit.
- Force Quit is separate, warns about unsaved changes and always asks the Host's
  confirmation. Decline, expiry, target exit/PID reuse and revoked access cause no
  exit; Close/Quit of a target no longer in front require Host Confirmation.
- Both Identify the App in Front and Close or Quit the App in Front use ordinary
  grants. A denied grant is unavailable for a Bundled or user-installed copy.
  Without Accessibility only Force Quit is offered. Spinnet in front yields no
  target; no universal process list or App-specific exit policy is supplied.
- The fixture keeps a user alias, disabled Alternate Action and editor order.
  Launch and save retain all Action IDs, Menu Items, empty Settings and decisions.
- Removal leaves the configured Menu Item unavailable, forgets grants, clears
  Plugin Storage and Pin preference, and suppresses the shipped copy across
  launches. Installing a copy restores an ordinary installed Plugin which asks
  for access again; the shipped copy stays suppressed underneath it.
- View close cancels pending confirmations; late answers and owner invalidation
  never replay an exit. A completion after close cannot reopen a view or run the
  exit again. Helper retirement preserves the disclosed target in Plugin state.

The public kit suite exercises the shipped package and real helper; the existing
Current App session regressions cover shared Host cancellation/owner semantics.
Native Close/defaults/target-retention/Refresh acceptance from #89 and previously
accepted shared Close/Quit/Force Quit/confirmation behavior from #83 are reused.
This distribution change does not claim a new manual run of every system case.
