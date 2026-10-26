# Spinnet Plugin API

The Documented Plugin Interface is published under [MIT](LICENSE).
Plugins using it keep their own licence; the Host is GPL-3.0-only.

- **Build your first Plugin:** [Getting started](getting-started.md), with an installable [Hello package](examples/Hello.spinnetplugin/manifest.json).
- **Look up a contract:** [Reference by topic](reference/README.md), [catalogue](catalogue.json), [current TypeScript types](sdk/spinnet.d.ts).
- **Declare compatibility:** set `"engines": {"spinnet": "^1.0.0"}` in the manifest. See [version rules and migration](reference/compatibility.md).

There is one current interface, organized by feature. Compatible additions ship
with Host minor releases; breaking changes require a Host major release and an
explicit migration. Plugin package versions and the exact Host commit used by
tests remain independent. `protocol_version: "1.0"` frames helper messages.

Schemas check shapes. The reference and Host additionally check Command identity,
ownership, authority, budgets and compatibility with the running Host. The
[conformance fixtures](fixtures/README.md) exercise both accepted and refused
shapes; passing a schema alone does not establish native execution.
