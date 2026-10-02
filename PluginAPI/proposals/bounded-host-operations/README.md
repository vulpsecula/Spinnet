# Proposal: bounded script-requested Host operations

> **Status: proposal only.** Nothing in this directory is part of Plugin API
> Level 1, of any later stable Level, or of any published Candidate Contract
> revision. No Host, helper, SDK or test kit implements it. A Plugin must not
> declare or rely on anything described here. The files exist so the design
> for GitHub issue #70 can be reviewed as a diff; the implementation ticket
> (#76) turns an accepted version of them into a real candidate revision in
> whatever place and format #75 chooses for candidate material.

The Level 1 catalogue, reference pages and schemas one directory up are
unchanged by this proposal. Where these drafts reference a Level 1 schema,
they do so by relative path so that the proposal can be checked against the
published definitions it extends.

## What it proposes

A script may answer a gesture with one **requested Host operation**. The Host
commits the answer and the request together, then performs the operation
itself after the script's four-second invocation has ended: it checks
authority again, asks for a trusted Host confirmation when the kind of
operation requires one, resolves the real target, and reports the outcome in
the view or, when the Plugin asks, as an `operation_finished` View Event.
Insertion is the first kind. Quitting the working App and starting a reviewed
task are worked through as illustrations so that the shape stays generic;
their real definitions belong to the tickets that own them (#83 and the
reviewed-task tickets).

Under the same candidate, every insertion path in a View Session (the
standard `insert_text` action, an answer-requested insertion, and a
synchronous `insert_text` Host Service call) targets the App that is
frontmost when the text is inserted, and the Host shows that App's name. If
the App the Host showed is not the App in front at execution, nothing is
inserted, the operation is refused, and the hint updates. Level 1 Plugins keep
every Level 1 path exactly as published.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design: ownership, commit, confirmation, results, busy behaviour, deadlines, stale results, the insertion rules, permissions, what waits on #69, and the product choices returned to the user |
| [`reference.md`](reference.md) | A draft of the reference page a candidate revision would publish |
| [`host-operations.schema.json`](host-operations.schema.json) | Draft JSON Schema (draft 2020-12) for the answer member, the `operation_finished` event and the view member that shows the insertion target |
| [`host-operations.d.ts`](host-operations.d.ts) | Draft types and proposed `spinnet.ui` builders |
| [`verification-plan.md`](verification-plan.md) | Budgets to measure and the real-App verification matrix |
| [`fixtures/`](fixtures/) | Valid and invalid answers and events, and behaviour scenarios for the test kit and Host tests |
| [`check.py`](check.py) | A self-contained check that the fixtures agree with the schema |

Run the check with `python3 PluginAPI/proposals/bounded-host-operations/check.py`.
It implements the same JSON Schema subset as the Spinnet test suite's
`JSONSchemaSubsetValidator` and refuses any other keyword, so the draft schema
can move into a real candidate without needing a richer validator.

## Relation to other work

- **#75** decides how a candidate is declared, versioned and stored under
  `PluginAPI/`. This proposal names its candidate `host_operations` only as a
  placeholder and assumes nothing about the declaration format.
- **#69** records which Apps and controls accept Accessibility insertion on
  Level 1. Every decision in `design.md` marked *waits on #69* stays open
  until that evidence exists.
- **#76** implements an accepted version of this proposal with insertion as
  its first complete kind; **#83** adds the App-exit kinds.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).
