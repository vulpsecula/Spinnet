# Spotify onboarding regression (#96)

Additive baseline for the stable Level 3 Spotify 1.2.0 package accepted in #91.
Historical six-Plugin configuration, grants and settings fixtures stay unchanged.

- Restore all nine accepted Commands, Set Volume input 37, alias Desk Music,
  a disabled Mute Alternate Action and explicit Alternate Action order.
- Preserve the scoped Spotify playback grant and empty Plugin Settings through
  migration, persistence and registry reconciliation.
- A missing Spotify application or unready External App Connection prevents
  playback without launching the helper or replaying an earlier gesture.
- Bundled and installed origin require the same user authority; denial and
  revocation prevent external playback dispatch.
- Removal invalidates its owner, deletes Plugin Storage (remembered mute
  volume), forgets grants/Host preferences, keeps configured Menu Items, and
  suppresses the shipped copy across launch. Installing a copy asks again.
- Accepted public helper regressions cover viewless playback/volume, bounded
  next-track outcomes, invalid input, Mute storage/restart, native failure and
  passive/late events. No panel, Source or background resource is created.

Native playback and Host-owned connection/Automation UX were accepted in #91
on Host 91ff874 and independent package source 0aa11e8. Onboarding changes only
the stable declaration and packaging; it reuses that acceptance. Recorded
services cannot establish current physical playback or macOS permission UI.
VoiceOver remains excluded by the user's accepted scope.
