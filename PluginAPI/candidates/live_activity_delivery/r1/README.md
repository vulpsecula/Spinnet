# Live activity delivery, revision 1

This revision was evaluated locally before Level 4 publication and retired into
[Level 4](../../../reference/level-4.md). It adds only the one-second minimum
interval for changed `activities.list` source deliveries. Other sources, unchanged
results, visibility, bounds and authority retain their earlier rules.

`ActivitySourceDeliveryTests` runs the real activity adapter and source engine
under both Level 3 plus this exact candidate and stable Level 4, proving the
same intermediate log delivery at one second while Levels 2 and 3 retain their
15-second floor. It also checks promotion assigns exactly Level 4's members.
`RecordedActivityDeliveryTests` exercises the public Test Kit at Levels 3 and 4.
The complete external Homebrew Plugin is checked with the native helper;
a 12-render one-second paced probe measured median 14 ms, maximum 422 ms and
0.14 seconds of child CPU time without running a Homebrew mutation.

Bundled Plugins declare stable Level 4. A remaining candidate declaration is
refused with the stable migration message. Exact public commits identify the
published Host, Test Kit and external Homebrew Plugin; no Git tag is required.
