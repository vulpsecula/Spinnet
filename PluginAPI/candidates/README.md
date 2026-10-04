# Candidate Contracts

A Candidate Contract is an explicitly provisional revision of the Documented
Plugin Interface, used to try an addition out before it joins a stable Plugin
API Level (ADR 0013). Nothing on this page or under this directory is part of
a stable Level, and nothing here changes what [Level 1](../README.md#what-level-1-offers)
promises. A Plugin that declares no candidate is unaffected by any of it.

| File | Contents |
| --- | --- |
| [`schemas/candidate-contracts.schema.json`](schemas/candidate-contracts.schema.json) | The `candidate_contracts` member a manifest adds to declare candidates |
| [`schemas/candidate-metadata.schema.json`](schemas/candidate-metadata.schema.json) | The `candidate.json` that pins one revision of a candidate |
| [`namespaces/r1/`](namespaces/r1/reference.md) | Candidate `namespaces` revision 1: one `namespace.verb` ID for every Host Service, its catalogue, schema, SDK and types |
| [`host_operations/r1/`](host_operations/r1/reference.md) | Candidate `host_operations` revision 1: Requested Host Operations an answer commits and the Host performs, and where insertion goes in a View Session; its schema, fixtures, SDK and types |
| [`collections/r1/`](collections/r1/reference.md) | Candidate `collections` revision 1: pages of identified components with a List or Grid, whose input the Host keeps across answers; its schema, fixtures, SDK and types |
| [`collections/r2/`](collections/r2/reference.md) | Candidate `collections` revision 2: revision 1 with repeated calls, which run a called Action in the open View Session as `called`; its schema, fixtures and types |

## Declaring a candidate

A Plugin names each candidate it was written against, at its exact revision,
beside the stable Level it needs:

```json
{
  "protocol_version": "1.0",
  "api_level": 1,
  "candidate_contracts": [{"name": "collections", "revision": 2}],
  "id": "com.example.emoji"
}
```

The rest of the manifest is the [stable manifest](../reference/manifest.md),
whose schema refuses `candidate_contracts`; check a candidate manifest
without that member against the stable schema, and with it against
[`candidate-contracts.schema.json`](schemas/candidate-contracts.schema.json).
A name is a lowercase identifier, a revision an integer of at least 1, and
each candidate is declared once. A revision is not a Plugin API Level and
reserves none.

A Bundled Plugin may not declare a candidate: Plugins shipped with Spinnet
use stable Levels only.

## What the Host checks

The Host checks the stable Level and every declared candidate when it reviews
a package for installation, installs or updates it, and registers it at
launch, and again before each scripted run. A Plugin is refused when, in
this order and for each declared candidate in turn:

1. its `api_level` is higher than the highest stable Level the Host supports;
2. it ships with Spinnet and declares any candidate;
3. it declares a revision the Host has retired, which names the stable Level
   the candidate became, if it was promoted;
4. the Host provides other revisions of the candidate, or none, but not the
   declared one: revisions must match exactly, so a Host providing revision
   3 refuses a Plugin declaring revision 2 or 4, and its refusal names the
   latest revision it provides;
5. its `api_level` is lower than the stable Level the candidate builds on;
6. it leaves out a candidate revision the declared one requires;
7. it declares two candidates either of which excludes the other.

The refusal's message is what the Library reports for an install, and what
an unavailable Menu Item shows.

At launch, an installed Plugin the Host refuses, or whose package cannot be
read, is a Refused Plugin rather than a removed one. Every other Plugin
restores. The Library lists it with the reason and a way to remove it, and it
cannot be added to the Menu. Its Menu Items stay in their Menu Slots,
unavailable with the reason; its Plugin Settings, Plugin Storage, credentials
and access decisions are kept for a Host that can run it. Installing a
revision the Host accepts over it is an update, and removing it removes it as
any Plugin is removed.

While a script runs, each Host Service it requests must belong to a stable
Level up to the Plugin's `api_level` or to a candidate revision it declares.
Any other request fails with `host_service_failed` and ends the run, even
when the Host provides that member to Plugins that declare it.
`spinnet.environment.apiLevel` stays the highest stable Level the Host
supports, whatever candidates it provides.

## The Plugin test kit

`PluginTestHelper(contracts:)` runs a Plugin against what a Host offers, by
default the Host the kit was built with. A run is refused as that Host
refuses the Plugin, and a request outside the Plugin's declared Levels and
candidates fails as it would in the Host, so an author sees a mismatch before
installing. A candidate's metadata decodes as a `CandidateContract`, which a
test can offer in a `PluginInterfaceContracts`.

## Revisions, attempts and tags

Each revision is published as `candidates/<name>/r<revision>/candidate.json`
([schema](schemas/candidate-metadata.schema.json)), beside its reference page
and any schema or type definitions it adds, at the git tag
`plugin-api-candidate/<name>/r<revision>`. The metadata names the stable
Level the candidate builds on, the candidate revisions it requires or
excludes, and its members: Host Services a script calls (`host_service`),
Host Services a Command runs directly (`host_command`), Host Services an
answer requests (`request`), view components, standard actions, View Events
and behaviours. The Host's own record of the revisions it
provides equals these files, which its tests check.

A published revision never changes. An attempt evaluates one revision on one
frozen Host build through two external Plugin rounds; changing either the
revision or the Host starts a fresh two-round attempt, under a new revision
if the contract changed. Candidate SDK wrappers and type definitions, when a
candidate adds them, live with its revision and never in the stable
`spinnet.js` or `spinnet.d.ts`: the helper injects a candidate's SDK, such as
`namespaces/r1/namespaces.js`, only into a Plugin that declares it,
`host_operations/r1/host_operations.js` over it into one that also declares
`host_operations`, and `collections/r1/collections.js` over that into one
that also declares `collections` r1 or r2: a revision that adds no builder,
as `collections` r2 adds none, publishes no SDK of its own and gets the
earlier revision's. Until a
candidate adds one, a script reaches its Host Services with
`requestHostService`, which the Host checks as above.

A Host may provide more than one revision of a candidate, as this one
provides `collections` r1 and r2; a Plugin declares exactly one of them and
gets exactly that revision's members.

## Promotion and retirement

Promoting a candidate gives the members of its latest provided revision the
next stable Level and retires every revision of it the Host provides in the
same Host change. Earlier Levels keep their vocabulary
and the behaviour Plugins declared against them. A Plugin moves by declaring
the new `api_level` and dropping the candidate; the Host then refuses the
retired declaration with the Level to declare instead, so no Plugin keeps
running against a provisional contract. Promotion is verified by running the
Plugin's candidate revision on the candidate Host and its stable revision on
the promoted Host, with the same result. Any stable promise, once published,
binds every later Host.

## Candidate Contracts this Host provides

| Candidate | Revision | Builds on | Tag |
| --- | --- | --- | --- |
| [`namespaces`](namespaces/r1/reference.md) | 1 | Level 1 | `plugin-api-candidate/namespaces/r1` |
| [`host_operations`](host_operations/r1/reference.md) | 1 | Level 1, with `namespaces` r1 | `plugin-api-candidate/host_operations/r1` |
| [`collections`](collections/r1/reference.md) | 1 | Level 1, with `host_operations` r1 and `namespaces` r1 | `plugin-api-candidate/collections/r1` |
| [`collections`](collections/r2/reference.md) | 2 | Level 1, with `host_operations` r1 and `namespaces` r1 | `plugin-api-candidate/collections/r2` |

## Retired candidate declarations

| Candidate | Revision | Became |
| --- | --- | --- |
| None yet | | |
