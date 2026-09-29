# Measurements

Raw samples and summaries of the runs that accepted a budget, kept so the
figures an ADR quotes can be checked again. Each run is a directory named for
when it started, as `script/measure_view_sessions.sh` writes it under
`tmp/measurements/`; a run is copied here only once its figures are accepted.

- `view-sessions/20260929-141629/`: W13 (#60), the View Session budgets in
  ADR 0010 and `ScriptedActionBudgets`.
- `view-sessions/20260929-164527/`: W14 (#61), Smart Jump's `open.js` within
  those budgets, typing p95 144.6 ms cold and 116.7 ms warm, the helper 4.7
  MiB over itself with the view open; the machine was not idle. The rig
  grants nothing, so the copy measured skipped the selection read at start
  and redrew its view for the `again` event the harness sends; typing ran
  the shipped script unchanged. Idle retirement was not measured.
