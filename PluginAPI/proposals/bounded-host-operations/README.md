# Proposal: bounded script-requested Host operations

> **Status: design record; revision 1 is published.** #76 published
> Candidate Contract `host_operations` revision 1 from this proposal under
> [`../../candidates/host_operations/r1/`](../../candidates/host_operations/r1/reference.md),
> which the Host, helper, SDK and test kit implement: write Plugins against
> that revision, not against the files here. Its `candidate.json` records
> the operations an answer may request as `request` members, the kind #100
> added to #75's metadata, where the draft here used `request:<id>`
> behaviours. Its reasons drop `no_text_input` and `text_rejected`, which
> keyboard-event insertion (P3) cannot tell apart, and add the failure
> categories the other request IDs fail with; its SDK adds the
> `.operation(...)` builders, `host.showPluginSettings`, `ui.request` and
> `showsInsertionTarget` on `ui.view`. Focus moving inside the App refuses
> only where Accessibility exposed the focused element when the user acted;
> elsewhere the App alone is compared (#69). This directory stays as the
> design for issue #70. Revision 2 (#79, 2026-10-05), published under
> [`../../candidates/host_operations/r2/`](../../candidates/host_operations/r2/reference.md),
> delivers an outcome after its view closed; [`revision-2.md`](revision-2.md)
> is its design record.

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
An operation names the Host Service it performs by its ID in the namespace
catalogue of #99 ([`../namespaces/`](../namespaces/README.md)), in `perform`
with its `input`; every operation the catalogue offers as a request may be
requested. Insertion, `selection.replace`, is the first one worked through.
Quitting the working App (`apps.quit`) and starting a reviewed
task are worked through as illustrations so that the shape stays generic;
their real definitions belong to the tickets that own them (#83 and the
reviewed-task tickets).

Under the same candidate, every insertion path in a View Session (the
`selection.replace` action, a requested `selection.replace`, a synchronous
`selection.replace` call, and Level 1's standard `insert_text` in a Level 1
view the Plugin still answers) targets the App that is
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
  "candidate_contracts": [
    {"name": "host_operations", "revision": 1},
    {"name": "namespaces", "revision": 1}
  ],
  "id": "com.example.emoji"
}
```

[`candidate.json`](candidate.json) is the draft metadata that revision was
published from: it builds on Level 1, requires
[`namespaces` revision 1](../../candidates/namespaces/r1/reference.md) whose
IDs name its operations, excludes no other candidate, and lists its members
(the `operation` answer member, one `request:<id>` member per catalogue ID
it may request, the `operation_finished` View Event, the
`shows_insertion_target` view member, execution-time insertion targeting on
every View Session insertion path, and the `insertion_target_changed`
failure category). `check.py` checks that the published
[`candidate.json`](../../candidates/host_operations/r1/candidate.json) has
the same members, with requests as `request` members.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design: ownership, commit, confirmation, results, busy behaviour, deadlines, stale results, the insertion rules, permissions, what waits on #69, and the product choices returned to the user |
| [`reference.md`](reference.md) | A draft of the reference page a candidate revision would publish |
| [`candidate.json`](candidate.json) | Draft Candidate Contract metadata for `host_operations` revision 1, as published with requests recorded as behaviours |
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
  Level 1; after it, Level 1 delivers inserted text as keyboard events (P3). Every decision in `design.md` marked *waits on #69* stays open
  until that evidence exists.
- **#76** implements an accepted version of this proposal with insertion as
  its first complete operation; **#83** adds `apps.quit`.
- **#99** names every operation by its catalogue ID; this proposal requires
  the draft `namespaces` revision.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).
