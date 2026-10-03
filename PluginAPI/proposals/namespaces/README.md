# Proposal: the Plugin API namespace boundary

> **Status: proposal only.** Nothing in this directory is part of Plugin API
> Level 1, of any later stable Level, or of any published Candidate Contract
> revision. No Host, helper, SDK or test kit implements it. A Plugin must not
> declare or rely on anything described here. The files exist so the design
> for GitHub issue #99 can be reviewed as a diff; the first new UI contract's
> implementation tickets (#76, #77) build on an accepted version of it, and it
> becomes a real candidate revision under
> [`../../candidates/`](../../candidates/README.md) with them.

The Level 1 catalogue, reference pages and schemas one directory up are
unchanged by this proposal, and `check.py` verifies that Level 1's schemas
still refuse every ID it adds.

## What it proposes

One explicit Plugin API boundary that every Plugin calls the same way and
the Host only implements, so that Plugins and the Host can be maintained
separately (#66). Every Host Service gets exactly one ID, `namespace.verb`,
where each namespace is one area of Spinnet's domain, ideally one Capability
boundary (`host`, `selection`, `keyboard`, `clipboard`, `clipboardHistory`,
`open`, `apps`, `system`, `window`, `screen`, `http`, `text`, `storage`),
and that ID is the same in the SDK
(`spinnet.clipboard.write`), a manifest Command that runs no script
(`"host_command": "clipboard.write"`), a page action and a Requested Host
Operation (`"perform": "clipboard.write"`), `operation_finished`, refusals
and Capability disclosure. Where an operation is offered follows stated
rules, every gap is recorded with its reason, and every Plugin API Level 1
name is mapped. Level 1 keeps its names for Level 1 Plugins.

The catalogue is compared with Raycast's API, but its namespaces and names
follow Spinnet's own domain and Level 1's SDK style; the areas Spinnet
deliberately does not offer are listed with reasons. The user accepted the
direction and decided the ten product choices on 2026-10-04
([`design.md`](design.md) section 13).

## Declaring the draft candidate

The proposal is written as Candidate Contract `namespaces`, revision 1, in
the format of [Candidate Contracts](../../candidates/README.md). It requires
no other candidate; the drafts of the first new UI contract build on it:
[`host_operations` r1](../bounded-host-operations/README.md) requires it, and
[`collections` r1](../collections/README.md) requires both. A Plugin that
uses all three declares:

```json
{
  "protocol_version": "1.0",
  "api_level": 1,
  "candidate_contracts": [
    {"name": "collections", "revision": 1},
    {"name": "host_operations", "revision": 1},
    {"name": "namespaces", "revision": 1}
  ],
  "id": "com.example.emoji"
}
```

[`candidate.json`](candidate.json) is the draft metadata that revision would
publish. Its `status` reads `supported` only because that is what the
metadata schema allows for a revision a Host would provide; it is not under
`../../candidates/`, the table of Candidate Contracts the Host provides does
not list it, its tag does not exist, and `check.py` fails if any of those
changes while it is a proposal.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design: principles, entry points and the rules for which an operation is offered at, naming rules, the namespaces and SDK layout, authority, the declaration and its grouping, how the other candidates and probes fit, the comparison with Raycast, separate maintenance, and the product choices the user decided |
| [`catalogue.json`](catalogue.json) | The machine-readable catalogue: every operation's ID, namespace, input and result, Capabilities, System Permission, failure categories, entry points and Level 1 names; Level 1's builders, values, globals, answer members, View Events and Capabilities; reserved IDs; areas not offered |
| [`catalogue.schema.json`](catalogue.schema.json) | JSON Schema (draft 2020-12) for `catalogue.json` |
| [`level1-mapping.md`](level1-mapping.md) | Every Level 1 name and the catalogue ID it maps to, generated from the catalogue |
| [`reference.md`](reference.md) | A draft of the reference page a candidate revision would publish |
| [`candidate.json`](candidate.json) | Draft Candidate Contract metadata for `namespaces` revision 1, provided by no Host |
| [`namespaces.schema.json`](namespaces.schema.json) | Draft JSON Schema for each operation's input and result, the IDs each entry point accepts, a call, a page action, the input a performed operation takes, and a manifest Command |
| [`namespaces.d.ts`](namespaces.d.ts) | Draft types for the namespaced SDK |
| [`fixtures/`](fixtures/) | Valid and invalid manifests, page actions, requests and calls, and given/when/expect scenarios, each stating its manifest |
| [`check.py`](check.py) | A self-contained check of the catalogue against Level 1 and its own schema, the schema, types and metadata against the catalogue, the fixtures, and the `host_operations` and `collections` drafts against the catalogue |

Run the check with `python3 PluginAPI/proposals/namespaces/check.py`. It
implements the same JSON Schema subset as the Spinnet test suite's
`JSONSchemaSubsetValidator` and refuses any other keyword. The other two
drafts keep their own checks, which still pass:
`python3 PluginAPI/proposals/bounded-host-operations/check.py` and
`python3 PluginAPI/proposals/collections/check.py`.

Host-internal design for this proposal lives in the Host's design notes, not
in `PluginAPI/`.

## Relation to other work

- **#70** (`host_operations`) and **#74** (`collections`) are updated to the
  catalogue's IDs here: an operation and a page action name their Host
  Service in `perform` with its `input`.
- **#75** defined the candidate format; the catalogue needs Command and
  request member kinds it does not have yet (design section 7.4).
- **#76** and **#77** implement the first new UI contract on these names;
  **#79** proves Emoji on it and promotes the three drafts together.
- **#66** depends on the boundary this catalogue makes explicit
  (design section 11).
- **#71**, **#81**, **#83** to **#88** fill the reserved IDs and the
  `source` entry point.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).
