# Frozen official Plugin packages

These packages are an unmodified copy of `Plugins/` from
[SpinnetPlugins](https://github.com/vulpsecula/SpinnetPlugins) at commit
`aefede85ebb7955e7a1e968c40dbb89618e3e2ce`, the last revision an app build
carried. They are fixed inputs for Host tests that register or install real
official Plugins, such as the per-Plugin regression baselines, the manifest
schema check and the architecture guard. The Host ships none of them.

Each package keeps its own MIT `LICENSE` and any `NOTICE`. Update them only
for a Host contract change; the live packages and their behaviour tests belong
to SpinnetPlugins.
