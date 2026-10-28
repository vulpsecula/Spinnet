# Update Source

A Plugin may declare an Update Source: the GitHub repository where its newer
versions are published. A user who installed the Plugin, from a file or any
other way, can then check its Library entry for a Plugin Update and apply one
after reviewing any new Capabilities. Nothing installs by itself, and an
Update Source grants no authority. Publishing needs only a GitHub Release.

This is an addition to the current interface. It is declared in the
[manifest](manifest.md) and its shape is in the
[manifest schema](../schemas/manifest.schema.json) as `update_source`.

```json
{
  "protocol_version": "1.0",
  "engines": {"spinnet": "^1.0.0"},
  "id": "com.example.plugin",
  "name": "Example Plugin",
  "version": "1.2.0",
  "update_source": {"github": "example-org/spinnet-plugins"},
  "commands": [{"id": "example.run", "title": "Run", "execution": "javascript", "script": "run.js"}]
}
```

The [TypeScript types](../sdk/update-source.d.ts) describe this manifest data.

## Declaring it

`update_source.github` names one public repository on github.com as
`owner/repo`. The owner is 1 to 39 ASCII letters, digits and `-`, starting
with a letter or digit; the repository is 1 to 100 ASCII letters, digits, `.`,
`_` and `-`, other than `.` and `..`. No other member, host or URL is accepted.

A Plugin that declares an Update Source must also have:

- an `id` usable in a release tag: ASCII letters, digits, `.`, `_` and `-`,
  starting with a letter or digit and ending with a letter, digit, `_` or
  `-`, without `..` and not ending in `.lock`;
- a `version` that is a [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html)
  version `M.m.p` with an optional `-prerelease` and no `+build` metadata.

A manifest breaking these rules is refused when it is installed.

## Publishing a version

Publish each Plugin version as its own GitHub Release in the declared
repository:

| Part | Value | Example |
| --- | --- | --- |
| Release tag | `<id>/v<version>` | `com.example.plugin/v1.2.0` |
| Release asset name | `<id>.spinnetplugin.zip` | `com.example.plugin.spinnetplugin.zip` |
| Asset contents | A ZIP holding exactly one `.spinnetplugin` folder at its top level | `Example.spinnetplugin/manifest.json`, … |

Because each tag starts with the Plugin's identity, one repository can publish
several Plugins. Zipping the package folder with Finder's Compress or
`ditto -c -k --keepParent Example.spinnetplugin com.example.plugin.spinnetplugin.zip`
produces a suitable asset. The archive may hold only plain files and folders,
stored or deflated: links, absolute or `..` paths, two paths that differ only
in case or Unicode normalization, encryption and ZIP64 are refused. A
`__MACOSX` folder is ignored.

Mark a release that should not be offered yet as a prerelease or keep it as a
draft. A published version should never change; publish a new version instead.

## How a version is chosen

When the user checks a Plugin, the Host asks GitHub's public API,
unauthenticated:

1. Lists every tag in the repository that starts with `<id>/v`, however many
   releases the repository has (`GET /repos/<owner>/<repo>/git/matching-refs/tags/<id>/v`).
2. Keeps the tags whose version is strictly greater, by SemVer precedence,
   than the installed version. A tag under the prefix that is not a SemVer
   version is reported as refused.
3. Looks up the release of each of those tags from highest version to lowest
   (`GET /repos/<owner>/<repo>/releases/tags/<tag>`) and offers the first one
   it accepts. A tag without a published release, a draft and a release
   marked as a prerelease are skipped. The highest accepted version wins;
   lower ones are neither looked up nor downloaded.

A package is accepted only when all of these hold:

- it was fetched over HTTPS from the release's asset named above, at
  `https://github.com/<owner>/<repo>/releases/download/<tag>/…` for the
  declared repository and that release's own tag; the download may be
  redirected only to GitHub's download storage
  (`objects.githubusercontent.com` or `release-assets.githubusercontent.com`);
- it unpacks to one readable package;
- it has the same Plugin identity as the installed Plugin;
- it declares the same Update Source (owner and repository compare without
  regard to case);
- its `version` equals the version its tag names, so it is strictly greater
  than the installed one;
- its [Host Compatibility](compatibility.md) includes the running Host, and it
  passes every other check of an ordinary install.

A refused version is listed with its reason, and the next lower one is tried.
A version past the lookup or download bound below is listed as not tried, and
an update offered below refused versions is shown with their reasons. A failed
check, such as being offline, GitHub's rate limit or an unreadable tag list,
is reported. Either way the installed version keeps working.

| Bound | Value |
| --- | --- |
| Releases looked up per check | 10 |
| Packages downloaded per check | 5 |
| Tag list or release answer size | 4 MiB |
| Package asset size | 16 MiB |
| Unpacked package size | 64 MiB |
| Archive entries | 2048 |
| Download redirects | 3 |

## Applying a Plugin Update

Applying replaces the package through the same path as
[installing an update](manifest.md#installing-updating-and-removing): Plugin
Storage, Plugin Settings, Menu Items and Capability decisions for unchanged
scopes are kept, the version's migrations run, and Capabilities the new
version newly requests are shown for review before anything is replaced.
The review is made again when the user applies the update, so a decision or
Host change since the check counts. Cancelling keeps the installed version.

A Plugin without an Update Source offers no update controls; one the Host
refused to load still offers them, so a version it can run can be found. Downgrades,
rollback, automatic installation, signing, authenticated requests and
sources other than GitHub Releases are not offered.

The [Update Source fixtures](../fixtures/update-source/index.json) show which
version is offered for given tags; the
[conformance matrix](../fixtures/conformance/index.json) holds accepted and
refused declarations.
