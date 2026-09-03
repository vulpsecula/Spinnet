# Broker Plugin network and external-app access

Spinnet will let Plugins integrate with remote services and External Apps only through Capability-checked Host Services scoped to declared network hosts, target application identities, and structured operations. The Host will prefer a target App's documented deep links, then its documented Apple Events interface, and will not give Plugin helpers arbitrary networking, shell execution, Apple Events, or Accessibility UI-scripting authority; this accepts less extension freedom than Raycast's Node runtime in exchange for enforceable data-flow disclosure, revocation, and per-Plugin isolation.

## Consequences

- A direct-API Plugin may request HTTPS operations only for disclosed hosts; redirect destinations and credential references remain Host-controlled.
- An External App Adapter may invoke only its declared target and operation family. Opening a documented deep link does not make Spinnet the owner of the target App's System Permissions, while sending Apple Events may require target-specific Automation consent.
- Adding a data category, network host, External App, or stronger operation in a Plugin update expands its Capability scope and requires new user consent before that version becomes active.
- Arbitrary shell execution and Accessibility-based GUI scripting remain outside the MVP integration contract.
