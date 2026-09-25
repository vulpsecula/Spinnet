# Spinnet Plugin API

This directory is the versioned home of the Documented Plugin Interface: the
contract a Plugin builds against (ADR 0013). Everything here is published under
the MIT licence in [`LICENSE`](LICENSE), so a Plugin can copy the schemas and
type definitions without taking on the GPL that covers the rest of Spinnet.

| File | Contents |
| --- | --- |
| [`schemas/manifest.schema.json`](schemas/manifest.schema.json) | JSON Schema (draft 2020-12) for a package's `manifest.json` |
| [`spinnet.d.ts`](spinnet.d.ts) | Types for the globals a Plugin script runs with |

## Plugin API Level

The interface is versioned by an integer Plugin API Level. Additive changes
raise it. A manifest's `api_level` is the lowest level the Plugin needs, and a
Host installs a Plugin only if it supports that level; otherwise it refuses and
asks the user to update Spinnet.

`protocol_version` is unrelated: it only frames the messages between the Host
and the Plugin's helper, and stays `"1.0"`.

Level 1 is the first level. It is still being shaped and may change until it
is published; no Plugin outside this repository depends on it yet.

The schema requires `api_level`. A Host reads a manifest written before the
field existed as needing Level 1, the level that interface became.

## What the manifest schema checks

The schema checks the shape of each member: which members exist, their types,
the allowed Capabilities, Host Commands, and field kinds, and the length limits.
The Host checks the rest when it loads a package, such as that the Preset names
declared Commands, that each Capability scope belongs to a declared Capability
and names the data and targets it affects, and that default inputs and settings
suit their fields.

A few older spellings the Host still reads are not part of the interface and
the schema rejects them: `script_path` and `javascript` for `script`,
`configuration` for `configuration_field`, and the `common_javascript` and
`script` executions.
