# Copyright risk of converting PopClip Extensions

Researched 2026-09-01. This is product and engineering risk analysis, not legal advice. Before operating a public conversion service or marketplace, Spinnet should obtain advice from an Australian copyright lawyer covering Australia and the principal markets in which the service will operate.

## Executive conclusion

There is a real copyright risk, but it is manageable if the product separates compatibility engineering from public conversion and redistribution.

- Implementing Spinnet's own Plugin API and a converter from publicly documented PopClip formats is the lower-risk activity.
- Copying a third-party Extension, translating its scripts or configuration, packaging the result as a native Spinnet Plugin, and distributing that result can exercise the copyright owner's reproduction, adaptation, publication, and communication rights.
- A clean Spinnet package or a rewrite into another language does not by itself remove those rights. Under Australia's Copyright Act, an adaptation of a computer program includes a version expressed in another language, code, or notation.
- The official `pilotmoon/PopClip-Extensions` repository is unusually favourable: its source is MIT-licensed unless an individual Extension readme says otherwise. The MIT licence permits modification and distribution if its copyright and permission notice is preserved.
- PopClip's own directory submission agreement gives Pilotmoon permission to store, package, sign, distribute, and update submitted Extensions. It does not grant those permissions to Spinnet.
- A public Spinnet marketplace should therefore accept only an author opt-in or a verified licence that permits the exact conversion and distribution performed. A public GitHub repository with no licence is not enough.

## What is protected

A PopClip Extension may contain several independently relevant materials:

- executable JavaScript, TypeScript, shell, or AppleScript source;
- expressive configuration, descriptions, documentation, and test fixtures;
- icons, screenshots, and other artwork;
- third-party libraries or assets under their own terms;
- names, logos, or branding that may raise trademark and passing-off concerns separately from copyright.

Facts, ideas, action semantics, public interfaces, and very short or purely mechanical declarations may receive less or no copyright protection, depending on the jurisdiction and facts. That is not a reliable bulk-conversion policy: a converter cannot assume that every simple Extension contains no protectable expression.

## Compatibility is not the same as copying

Spinnet can study PopClip's public developer documentation and independently implement equivalent concepts, such as URL actions or an input-text API. That is different from taking a particular Extension's implementation and translating it.

Australia's interoperability exception in section 47D is narrow. It applies to an owner or licensee of a copy, only to the extent reasonably necessary to obtain otherwise unavailable information needed to make an independently created interoperable program. Section 47G can remove that protection retrospectively when a copy, adaptation, or derived information is used or supplied for another purpose.

Because PopClip publishes developer documentation for its Extension format and APIs, Spinnet should not design its public conversion or marketplace policy around section 47D. In particular, the exception should not be assumed to authorize republishing converted third-party Extensions. This is a legal-risk inference from the statute, not a court-tested conclusion about this product.

## Risk by portal activity

| Portal activity | Indicative risk | Reason | Recommended treatment |
| --- | --- | --- | --- |
| Implement PopClip-compatible inputs and APIs from public documentation | Lower | Independent compatibility work need not copy a particular Extension's expression | Keep design notes and avoid copying closed-source PopClip application code |
| Scan an uploaded Extension and show a Compatibility Report | Low to medium | The service necessarily receives and temporarily processes a copy | Process ephemerally; do not publish, train on, or retain it without a separate basis |
| Convert a user's own Extension for that user | Lower, not zero | The user can grant the required rights, but the service should obtain that representation | Require an ownership/authority confirmation and keep the result private by default |
| Privately convert a third-party Extension supplied by a user | Medium | A server-side reproduction and adaptation may occur even if the result returns only to that user | Do not assume private use cures the issue; limit retention and obtain legal advice before launch |
| Publicly list and distribute a converted Extension | High unless licensed | This can reproduce, adapt, publish, and communicate the work and its assets | Require verified licence compliance or explicit author opt-in before conversion or publication |
| Monitor upstream and automatically publish converted updates | High unless licensed | Every release is a fresh input and may change its licence, authors, assets, and dependencies | Re-run provenance, licence, capability, and human-review gates for every version |

## Licence policy

### Separate the two licence decisions

Spinnet's licence for its own Host, SDK, converter, and original Plugin code is separate from the Upstream Licence that authorizes conversion of a PopClip Extension. Spinnet's licence cannot narrow, replace, or cure an upstream Extension licence. The portal must satisfy both layers independently.

Spinnet-Owned Code will use GPL-3.0-or-later. The Host will carry a narrow section 7 Plugin Exception so an Independent Plugin using only the Documented Plugin Interface can retain its Upstream Licence. Because the Free Software Foundation treats tightly linked or intimately communicating Plugins as potentially forming one combined program, the exception and the technical interface boundary require legal review before release.

### Suitable for an MVP allowlist

MIT, BSD-2-Clause, BSD-3-Clause, and Apache-2.0 generally permit modification and redistribution when their notice and other conditions are followed. They are good initial candidates, but the portal still needs to inspect per-Extension overrides, bundled dependencies, and asset licences.

For the official PopClip Extensions repository, the repository states that all source is MIT-licensed unless the individual Extension readme says otherwise. Its MIT licence requires the copyright and permission notice to remain in all copies or substantial portions. A generated Plugin should therefore ship a machine-readable provenance record and the applicable notices.

### Defer until the compliance model is designed

GPL-family code can be converted and distributed only while satisfying the applicable copyleft terms. A distributed modified version may need modification notices, the same licence, and corresponding source. An offline compiled Plugin without an accompanying source path is not a safe default. Whether a Plugin's licence affects the Host is interface- and packaging-specific and needs separate analysis.

Extensions with custom, non-commercial, source-available, or conflicting licences need individual review.

### Do not publish by default

If an Extension or repository has no licence, default copyright rules apply. Public visibility and GitHub's fork feature do not grant a general right to modify and redistribute it. Treat missing, ambiguous, or unverified licensing as `private analysis only` until the author opts in or grants permission.

## Recommended product boundary

Use two distinct lanes rather than treating every submitted URL as marketplace content.

### Public conversion and marketplace lane

Only admit an Extension when one of these bases is recorded:

1. the author or rights holder explicitly opts the source repository into Spinnet conversion, distribution, and automatic updates; or
2. a verified licence permits modification and redistribution, and Spinnet has an implemented compliance recipe for that licence.

For each published version, retain:

- immutable upstream repository URL, commit, tag, and content hash;
- detected licence plus any per-Extension override;
- original and generated source needed to satisfy the licence;
- author and contributor attribution;
- copied asset and dependency provenance;
- converter version and Compatibility Report;
- review outcome and withdrawal/takedown state.

The generated package should say that it was converted by Spinnet, identify the upstream author, preserve required notices, and avoid implying that the author or PopClip endorses Spinnet.

### Private conversion lane

A user may upload a package or URL to receive a private Compatibility Report and, where the portal's legal basis permits, a private converted Plugin. The safer design is ephemeral processing with no public listing, sharing, indexing, source mirroring, or reuse for other users. Automatic updates should remain disabled unless the source licence or author authorization supports repeated conversion.

This lane still needs legal review: putting the conversion on a server rather than the user's Mac does not eliminate the reproduction or adaptation involved.

## Automatic-update safeguards

Automatic updates remain compatible with a low-friction user experience if publication is gated rather than legally assumed:

1. Watch only an explicitly recorded upstream repository and tag channel.
2. Pin and archive the exact input commit for reproducible public builds.
3. Treat a licence change, removed licence, new dependency, new asset, or changed author list as a blocking review event.
4. Re-run static security and Capability analysis for every release.
5. Publish only after the licence recipe, attribution bundle, and Compatibility Report pass.
6. Support author withdrawal and a documented notice-and-takedown process. Preserve audit records while stopping new distribution and updates.

## Naming and branding

No specific PopClip trademark permission or compatibility-brand policy was found in the official materials reviewed. Spinnet should use `PopClip-compatible` descriptively, clearly state that it is independent and not endorsed by Pilotmoon, and avoid copying PopClip logos, trade dress, signatures, or marketplace presentation. Counsel should review the final naming and disclaimer before launch.

## Consequence for the proposed native rewrite

`Pure Native Spinnet Plugin` should describe the output format and runtime, not its copyright status. The converter may generate a Plugin that uses only Spinnet APIs and contains no PopClip runtime, but if it translates protectable source or assets from an Extension, the output can still be an adaptation or derivative work.

The safest initial catalogue is therefore not "every technically compatible Extension." It is the intersection of:

- technically compatible;
- permissively licensed or explicitly opted in;
- dependency and asset provenance verified;
- attribution and source obligations automatically satisfiable;
- security review passed.

## Primary sources

- [Australian Copyright Act 1968, latest compilation](https://www.legislation.gov.au/C1968A00063/latest/text): sections 10, 31, 47D, and 47G.
- [U.S. Copyright Office Circular 61: Copyright Registration of Computer Programs](https://www.copyright.gov/circs/circ61.pdf): scripts as source code and treatment of derivative computer programs.
- [U.S. Copyright Act, chapter 1](https://www.copyright.gov/title17/92chap1.html): section 117's limited permissions for owners of copies of computer programs.
- [Official PopClip Extensions repository](https://github.com/pilotmoon/PopClip-Extensions): MIT by default unless an Extension readme says otherwise.
- [PopClip Extension submission agreement](https://www.popclip.app/extensions/submit): author opt-in, storage, packaging, distribution, and update permissions granted specifically to Pilotmoon.
- [PopClip Terms of License](https://www.popclip.app/terms): Extensions are outside the PopClip product licence and use their own licence terms.
- [GitHub documentation: Licensing a repository](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/licensing-a-repository): default copyright treatment when no licence is present.
- [GNU GPL version 3](https://www.gnu.org/licenses/gpl-3.0.html): conditions for conveying modified source and object-code versions.
