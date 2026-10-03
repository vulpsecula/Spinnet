# Proposal: minimal composable pages and collections

> **Status: proposal only.** Nothing in this directory is part of Plugin API
> Level 1, of any later stable Level, or of any published Candidate Contract
> revision. No Host, helper, SDK or test kit implements it. A Plugin must not
> declare or rely on anything described here. The files exist so the design
> for GitHub issue #74 can be reviewed as a diff; the implementation tickets
> (#77 for pages and collections, #78 for repeated calls) turn an accepted
> version of them into a real candidate revision under
> [`../../candidates/`](../../candidates/README.md).

The Level 1 catalogue, reference pages and schemas one directory up are
unchanged by this proposal, and `check.py` verifies that Level 1's schemas
still refuse everything it adds.

## What it proposes

A Plugin View may be described as a **page**: an ID and a small tree of
identified components (text and choice fields, text, a button row, rows,
and one List or Grid). The Host keeps what the user is doing in a page
(typed text, caret, input-method composition, focus, selection, scroll)
across the Plugin's answers until the Plugin explicitly resets it, and
remembers the last few pages by ID. A List or Grid gives the Host native
selection, arrow keys, Return and double-click for the default item action,
a context menu and selection bar for secondary actions, scrolling and
bounded load-more; the Plugin keeps the data, search, filtering, sorting
and every batch. No component carries a Plugin-bound shortcut, and the
search field's caret editing and IME candidates always come first. Gestures
carry snapshots of the values, selection and item they were made with.

It is checked against the external Emoji probe's real data (1,906 emoji,
measured payloads) and against a Brew-shaped list, detail and progress
workflow. Together with `host_operations` (#70) and repeated calls (#78) it
forms the first new UI contract.

## Declaring the draft candidate

The proposal is written as Candidate Contract `collections`, revision 1, in
the format of [Candidate Contracts](../../candidates/README.md). It requires
the draft [`host_operations` revision 1](../bounded-host-operations/README.md),
so a Plugin declares both:

```json
{
  "protocol_version": "1.0",
  "api_level": 1,
  "candidate_contracts": [
    {"name": "collections", "revision": 1},
    {"name": "host_operations", "revision": 1}
  ],
  "id": "com.example.emoji"
}
```

[`candidate.json`](candidate.json) is the draft metadata that revision would
publish. Its `status` reads `supported` only because that is what the
metadata schema allows for a revision a Host would provide; it is not under
`../../candidates/`, the table of Candidate Contracts the Host provides does
not list it, its tag does not exist, and `check.py` fails if any of those
changes while it is a proposal. The schema refers to the draft
`host_operations` schema by relative path; publishing both moves those
references with them.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design, answering each #74 criterion: page and component identity, immediate state, reset, collections, keyboard roles, budgets and measurements, the Brew check, the grouping into the first new UI contract, verification, and the product choices returned to the user |
| [`level1-mapping.md`](level1-mapping.md) | What Level 1 keeps, how each Level 1 view element relates to a page component, and Emoji from E1 to E2 |
| [`reference.md`](reference.md) | A draft of the reference page a candidate revision would publish |
| [`candidate.json`](candidate.json) | Draft Candidate Contract metadata for `collections` revision 1, provided by no Host |
| [`collections.schema.json`](collections.schema.json) | Draft JSON Schema (draft 2020-12) for the answer, page, components, collection and page events |
| [`collections.d.ts`](collections.d.ts) | Draft types and proposed `spinnet.ui` builders |
| [`fixtures/`](fixtures/) | Valid and invalid answers and events, and given/when/expect behaviour scenarios for #77's and #78's tests, each stating its manifest |
| [`check.py`](check.py) | A self-contained check of the schema, the page rules the schema cannot state, the fixtures, the draft metadata and the budgets stated in `reference.md` |
| [`measure-emoji.js`](measure-emoji.js) | The payload and build-time measurement over the Emoji probe's own data, whose results are in `design.md` section 8 |

Run the check with `python3 PluginAPI/proposals/collections/check.py`. It
implements the same JSON Schema subset as the Spinnet test suite's
`JSONSchemaSubsetValidator` and refuses any other keyword. Run the
measurement with JavaScriptCore's shell and a checkout of the Emoji probe:

```sh
JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
$JSC PluginAPI/proposals/collections/measure-emoji.js -- <emoji>/Emoji.spinnetplugin/emoji.js
$JSC PluginAPI/proposals/collections/measure-emoji.js -- <emoji>/Emoji.spinnetplugin/emoji.js browse-all-1906
```

Host-internal design for this proposal lives in the Host's design notes, not
in `PluginAPI/`.

## Relation to other work

- **#69** supplied the evidence: Level 1's six-result cap and ⌘1–⌘6
  shortcuts, unobservable insertion, the typing and payload figures.
- **#70** (`host_operations`) supplies insertion: `item_action` is a
  gesture whose answer may request `insert_text` into the App in front.
- **#75** defined the candidate format used here.
- **#77** implements pages and collections; **#78** implements repeated
  calls, entering through the `called` event defined here; **#76** implements
  requested insertion. **#79** proves Emoji on them and promotes the group.
- **#81** (styles, images, Progress) and **#71** (Host-run sources) add
  components and deliveries to the same tree later; this revision does not
  include them.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).
