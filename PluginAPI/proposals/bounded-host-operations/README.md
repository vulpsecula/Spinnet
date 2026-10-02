# Proposal: bounded script-requested Host operations

> **Status: proposal only.** Nothing in this directory is part of Plugin API
> Level 1, of any later stable Level, or of any published Candidate Contract
> revision. No Host, helper, SDK or test kit implements it. A Plugin must not
> declare or rely on anything described here. The files exist so the design
> for GitHub issue #70 can be reviewed as a diff; the implementation ticket
> (#76) turns an accepted version of them into a real candidate revision
> under [`../../candidates/`](../../candidates/README.md).

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
the App the Host showed is not the App in front at execution, or focus has
moved to another element of it, nothing is inserted, the operation is
refused, and the hint updates. An insertion that no Host-shown target
preceded, such as one from a Menu Action without a view, is refused. Level 1
Plugins keep every Level 1 path exactly as published.

## Declaring the draft candidate

The proposal is written as Candidate Contract `host_operations`, revision 1,
in the format of [Candidate Contracts](../../candidates/README.md). A Plugin
written against it would declare, beside its stable Level:

```json
{
  "protocol_version": "1.0",
  "api_level": 1,
  "candidate_contracts": [{"name": "host_operations", "revision": 1}],
  "id": "com.example.emoji"
}
```

[`candidate.json`](candidate.json) is the draft metadata that revision would
publish: it builds on Level 1, requires and excludes no other candidate, and
lists its members (the `operation` answer member, the `insert_text`
operation kind, the `operation_finished` View Event, the
`shows_insertion_target` view member, execution-time insertion targeting on
every View Session insertion path, and the `insertion_target_changed` failure
category). It is a draft that no Host provides. Its `status` reads
`supported` only because that is what the metadata schema allows for a
revision a Host would provide; it is not under `../../candidates/`, the
table of Candidate Contracts the Host provides does not list it, its tag does
not exist, and `check.py` fails if either of those changes while it is still
a proposal.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design: ownership, commit, confirmation, results, busy behaviour, deadlines, stale results, the insertion rules, permissions, what waits on #69, and the product choices returned to the user |
| [`reference.md`](reference.md) | A draft of the reference page a candidate revision would publish |
| [`candidate.json`](candidate.json) | Draft Candidate Contract metadata for `host_operations` revision 1, provided by no Host |
| [`host-operations.schema.json`](host-operations.schema.json) | Draft JSON Schema (draft 2020-12) for the answer member, the `operation_finished` event and the view member that shows the insertion target |
| [`host-operations.d.ts`](host-operations.d.ts) | Draft types and proposed `spinnet.ui` builders |
| [`verification-plan.md`](verification-plan.md) | Budgets to measure and the real-App verification matrix |
| [`fixtures/`](fixtures/) | Valid and invalid answers and events, and behaviour scenarios for the test kit and Host tests, each scenario stating the manifest's `api_level` and `candidate_contracts` |
| [`check.py`](check.py) | A self-contained check that the fixtures agree with the schema and the draft metadata and declarations agree with the Candidate Contract schemas |

Run the check with `python3 PluginAPI/proposals/bounded-host-operations/check.py`.
It implements the same JSON Schema subset as the Spinnet test suite's
`JSONSchemaSubsetValidator` and refuses any other keyword, so the draft schema
can move into a real candidate without needing a richer validator. It checks
`candidate.json` against
[`candidate-metadata.schema.json`](../../candidates/schemas/candidate-metadata.schema.json)
and each scenario's declarations against
[`candidate-contracts.schema.json`](../../candidates/schemas/candidate-contracts.schema.json).

Host-internal design for this proposal lives in the Host's design notes, not
in `PluginAPI/`.

## Relation to other work

- **#75** defined how a candidate is declared, versioned and stored under
  `PluginAPI/candidates/`. This proposal uses that format for its draft
  `host_operations` revision 1; publishing it there is #76's work.
- **#69** records which Apps and controls accept Accessibility insertion on
  Level 1. Every decision in `design.md` marked *waits on #69* stays open
  until that evidence exists.
- **#76** implements an accepted version of this proposal with insertion as
  its first complete kind; **#83** adds the App-exit kinds.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).
