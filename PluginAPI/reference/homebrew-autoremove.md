# Homebrew unused dependencies

`tools.read({tool:"homebrew",operation:"previewAutoremove"})` reads a bounded
dry run and is also a visible-page source. It takes no selectors. The result
distinguishes failed or incomplete dry runs, truncation and an empty successful
result. It uses the native CLI without pinning private Homebrew source revisions.
`tools.startTask.operation({tool:"homebrew",operation:"autoremove"})` enters
the existing Host-reviewed Task flow with separate mutation authority and
a fresh Host Confirmation for the resolved targets. A Plugin cannot supply
argv, paths, shell text or repair scripts. Stop attempts never promise rollback;
recovery restores status without replaying a mutation. See the
[schema](../schemas/homebrew-autoremove.schema.json) and
[fixtures](../fixtures/homebrew-autoremove/index.json).
