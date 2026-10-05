# Design record: `host_operations` revision 2

Status: published as
[`../../candidates/host_operations/r2/`](../../candidates/host_operations/r2/reference.md)
on 2026-10-05, beside revision 1, which stays provided. It answers finding 1
of the external Emoji proof's second stage (E2, Spinnet #79): an operation
that closes its view never told the Plugin how it went.

## Evidence

Emoji inserts with `selection.replace`, `closes_view` and, if it could,
`notify`. On success the view closes, and revision 1 delivers
`operation_finished` only while the View Session exists, so Emoji recorded
Recent when the user pressed Return: a refused insertion (Capability
denied, Accessibility off, target changed) still listed the emoji. In the
real Host an unpinned panel gives the keyboard to the target App before the
text is typed and closes then, so even an outcome the view would show is
reached after the view ended.

## Decision

With `notify: true`, an operation whose view closed after it started (by
the user, by the Host or by its own `closes_view` on success) delivers
`operation_finished` with `view_closed: true` to one viewless invocation of
the Action that requested it (`outcome_after_close`).

- **Input and state.** That Action's input as it is when the invocation
  runs, and the view's last good state when it closed.
- **The answer.** Use Host Services, such as Plugin Storage, and answer
  `null`. A toast is shown near the pointer, as for a viewless Action. A
  view, page, state, operation or `close` is a protocol violation: the
  Host reports it near the pointer and otherwise ignores it, since there is
  no view to update or end, and performs nothing.
- **Deadlines.** The script must start within four seconds of the outcome
  (else the Host drops it) and has four seconds from when it starts, as
  every invocation does. A failure, timeout or crash is reported as a
  viewless Action's is. Nothing is retried.
- **Order.** It holds the Plugin's operation slot until it ends, so the
  next gesture, including the Action's start from the Menu, runs after it
  and sees what it stored.
- **Not delivered** for an operation cancelled before it ran, one whose view
  ended because the Plugin changed, lost a Capability or broke the
  interface, or one requested without a view. The Host still shows each
  outcome as in revision 1, and a pinned view that stays open hears it in
  the view as before.

Revision 2 adds no builder: `notify` already exists on `.operation(...)`.
`collections` revision 3 requires it, so performed item actions with
`notify` and `closes_view` are heard after the close too.

## Considered

- Delivering to the closing session before it ends (keeping the view
  hidden until the answer): rejected, the user would wait on a script to see
  the panel go, and a pinned panel already hears it in the view.
- Letting the after-close answer update a state kept for the next
  session: rejected, business state belongs in Plugin Storage (ADR 0015),
  and a state with no view would be a second, hidden persistence.
- Delivering any close, including a Plugin change or revocation: rejected,
  the Plugin is no longer the one that asked or has lost the authority.

## Decision returned to the user

The after-close answer may show a toast; anything else is a reported
violation. Whether a toast near the pointer after an insertion is wanted,
or should be dropped too, is the user's call.
