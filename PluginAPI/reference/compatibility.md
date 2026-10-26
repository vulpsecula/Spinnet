# Host compatibility

Every manifest declares a Host range, for example `"engines": {"spinnet": "^1.0.0"}`. The Host checks this
range before installation, registration or helper launch. The Plugin's own
`version` identifies its package; it does not select a second interface.

Only exact `M.m.p` and caret `^M.m.p` are accepted. Each component is a decimal
UInt64 without leading zeros. Whitespace, prerelease/build suffixes, comparison
operators, wildcards, unions and other npm range syntax are refused.

| Requirement | Accepted Host versions |
| --- | --- |
| `1.2.3` | Exactly `1.2.3` |
| `^1.2.3` | `>=1.2.3` and `<2.0.0` |
| `^0.2.3` | `>=0.2.3` and `<0.3.0` |
| `^0.0.3` | `>=0.0.3` and `<0.0.4` |

A caret whose upper bound would overflow UInt64 is refused. Schemas check the
spelling; Host admission checks numeric bounds and the running version. A
mismatch asks for a compatible Plugin revision or Host update and launches no
helper. It does not remove saved Menu Items, settings, data or grants.

## Migrating development packages

`api_level` and `candidate_contracts` are retired. Their presence is refused,
even when null, empty or accompanied by `engines`. Remove both and declare the
compatible Host range. No historical interface mode or candidate promotion
catalogue is maintained.

Use the [catalogue](../catalogue.json) IDs at every offered entry point. For
example, `read_selected_text` becomes `selection.readText`, `url.open` becomes
`open.url`, and the old `clipboard.copy` Command becomes `selection.copy` for
current selection or `clipboard.write` for configured text. Screenshot Commands
name `screen.capture` and fix `input.source` to `area`, `fullscreen` or `window`.
Raw service names and undeclared/reserved entry points are refused. Capability
names and saved Plugin/Command IDs are unchanged.

Form/detail `view` answers and `page` answers are both current shapes. Their
respective component/state rules follow the shape, using the same catalogue
names, authority and current Host behaviours. `spinnet.environment` reports
`hostVersion` and `preferredLanguage`; invocation IDs are separate globals. It has no
API-Level field. The helper protocol rejects obsolete declaration fields.

A saved Action moves to an equivalent catalogue Command only when the Host can
prove the target and configured input are unchanged. Removed or changed
Commands keep their Menu position and require repair; a migration cannot
silently redirect execution or grant authority. Replacing a Refused Plugin
with a compatible package restores its identity and retained data.
