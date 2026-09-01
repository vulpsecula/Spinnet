# PopClip compatibility boundary scanner

This is a disposable, measurement-oriented prototype for GitHub issue #5. It asks which behaviors in a small representative PopClip Extension corpus can remain in the Host, which require a runtime process boundary, and which need explicit design or rejection. It does not convert a PopClip Extension, execute third-party code, or implement the Conversion Portal.

## Run

From this directory:

```sh
uv run scan.py
```

The command verifies and scans the committed behavior-relevant inputs for the 12 package paths in `corpus.json`, then replaces the JSON files in `reports/`. It does not require network access. To cross-check the committed inputs against an existing upstream checkout at the exact pinned commit:

```sh
uv run scan.py --source /path/to/PopClip-Extensions
```

The command prints aggregate counts. `reports/aggregate.json` is the machine-readable summary; every other file in `reports/` is one Compatibility Report per PopClip Extension. No extension code is evaluated.

## Corpus and provenance boundary

The corpus is a purposive maximum-variation sample, not a random sample. It covers the six configuration containers counted in the existing runtime-landscape research and deliberately includes examples that pressure each plausible process boundary. This makes the sample defensible for architectural discovery but unsuitable for claiming an ecosystem-wide compatibility percentage.

The reproducible input snapshot is committed under `inputs/`: `corpus.json` pins the official `pilotmoon/PopClip-Extensions` repository to commit `eda50d7e0286909f3437004ee47fd5316c37fcc3`, explicitly lists every sampled file, and records a deterministic snapshot hash. Each Compatibility Report records every sampled file hash and a deterministic per-extension input-tree hash. The upstream repository says its source is MIT-licensed; no selected package README overrides that licence, and `inputs/LICENSE.txt` preserves the required notice. The snapshot contains only configuration and executable text needed to reproduce detection; artwork, demos, and documentation are excluded.

## Measured result

The 12-package sample produced:

- 3 **Host Adapter** reports (`supported`): URL, key press, and macOS Service behavior needs no Plugin process;
- 3 **Invocation Script** reports (`degraded`): one Shell Script and two AppleScript forms need short-lived interpreter processes;
- 2 **Common JavaScript** reports (`degraded`): common bridge calls plus options/context require a shared JavaScript runtime facility and logical isolation per Plugin;
- 4 **Extended JavaScript Review** reports (`unsupported`): all four contain one or more unresolved surfaces such as PopClip util APIs, networking, external dependencies, retained state, or DOM processing.

Across the purposive sample, 9 of 12 PopClip Extensions need something beyond Host-only adaptation. This does **not** mean 75% of the ecosystem needs a Plugin process: the sample intentionally over-represents boundary-pressure cases. It does show that one universal execution boundary would erase material distinctions visible even in a small corpus. `reports/aggregate.json` contains the exact counts and links to all 12 Compatibility Reports.

The scanner has a detector for declarative Apple Shortcut actions, but none of the selected PopClip Extensions contains one; that behavior remains unmeasured in this corpus. Zero-count known categories and Compatibility Levels remain explicit in the aggregate output.

## Provisional Compatibility Levels

The levels are prototype labels, not an accepted product taxonomy:

- **Host Adapter** (`supported`): declarative URL, key press, Service, or Shortcut behavior maps to Host Commands and does not start a Plugin process.
- **Invocation Script** (`degraded`): Shell Script or AppleScript needs an invocation-only interpreter process, timeout, Capability checks, and result adaptation.
- **Common JavaScript** (`degraded`): common input, invocation context, options, and allowlisted `popclip` calls need a shared JavaScript runtime facility with a separate logical context per Plugin.
- **Extended JavaScript Review** (`unsupported`): networking, authentication, retained state, external dependencies, DOM/HTML processing, uncommon APIs, or dynamic behavior is not admitted automatically.
- **Reject** (`unsupported`): unknown configuration or native/unclassified executable content is not run.

`supported`, `degraded`, and `unsupported` describe the target treatment suggested by the architecture evidence; they do not claim that production support exists.

## Detection limits

The scanner uses conservative static pattern matching. It parses JSON and plist only for manifest metadata and does not parse or execute JavaScript, TypeScript, YAML scripts, Shell Script, or AppleScript.

False positives can arise from comments, dead code, bundled copies, similarly named fields, and mutable collections that do not actually survive an invocation. A package may be classified at its most demanding detected behavior even when a simpler Action could be imported separately.

False negatives can arise from computed property names, aliased APIs, generated/eval code, indirect imports, unconventional YAML, behavior hidden in excluded documentation or assets, or APIs reached through helper code. The scanner also does not validate runtime semantics, macOS version behavior, action results, timeouts, security, signing, dependencies, asset rights, or whether a Service/Shortcut exists on a user’s Mac. Because the committed input scope excludes binaries, the zero `native_executable` count means “not sampled,” not “absent upstream.”

## Human review checkpoint

Before these labels or dispositions influence the Documented Plugin Interface or user-facing import behavior, complete this exact checklist:

- [ ] Confirm the pinned repository, commit, MIT Upstream Licence basis, preserved notice, and absence of a package-level licence override for all 12 sampled PopClip Extensions.
- [ ] Manually compare every Compatibility Report with its listed input files and approve or override each detected behavior/API requirement.
- [ ] Approve, rename, split, or reject the five provisional Compatibility Levels and their `supported`/`degraded`/`unsupported` dispositions.
- [ ] Decide whether Shell Script and AppleScript share one Compatibility Level or require separate policy and runtime treatment.
- [ ] Decide which networked and common JavaScript behaviors are degraded versus rejected for the MVP.
- [ ] Decide whether a mixed PopClip Extension receives one package-level Compatibility Report disposition or separate dispositions per imported Command.
- [ ] Confirm that the sample is architectural discovery evidence, not an ecosystem coverage estimate, and that zero-count Shortcut/native-executable categories are unmeasured rather than proven absent.
- [ ] Record accepted domain-language changes in `CONTEXT.md` and hard-to-reverse process-boundary/API decisions in an ADR as a separate, reviewed task.

These are domain and hard-to-reverse product/API decisions; this disposable prototype deliberately does not make them or edit domain/decision records.
