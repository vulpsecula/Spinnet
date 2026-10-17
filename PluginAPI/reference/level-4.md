# Plugin API Level 4

Declare `"api_level": 4` without `candidate_contracts` to receive changed
`activities.list` source results at a minimum interval of **one second**.
The source must still request `every: 1` to sample once a second. Unchanged
results do not invoke the Plugin, and hiding or closing the page stops
sampling and delivery. The Host does not keep a Plugin runtime resident.

```js
const c = spinnet.ui.components;
return spinnet.ui.showPage(spinnet.ui.page({
  id: "tasks", title: "Tasks",
  sources: [spinnet.activities.list.source("activities", {every: 1, deliver: true})],
  content: [c.text({id: "waiting", text: "Waiting for task status…"})]
}));
```

The `source_delivered` handler renders the current stage, elapsed time and
bounded log while the task is running. Re-rendering never starts, resumes or
repeats a mutation. A gesture and the ordinary Host Confirmation remain
required to start a task or attempt Stop. A progress component may remain
indeterminate; a download percentage is not an overall installation percentage.

The one-second floor applies only to the local `activities.list` source.
Levels 1–3 retain their 15-second delivery floor, and every other source at
Level 4 also retains that floor. The per-source floor survives page/source
redefinitions. The maximum of eight sources per page, 512 KiB result bound,
one sample in flight, one pending result, change coalescing, owner checks,
visibility rules and queued-event validity all remain unchanged.

Use [the Level 4 types](../spinnet-level-4.d.ts) and
[manifest schema](../schemas/manifest-level-4.schema.json). The
[Level 3 catalogue](../catalogue-level-3.json), page schemas and SDK builders
are unchanged: Level 4 adds delivery behaviour, not a new operation or access.
Older Hosts refuse Level 4 before installation with an update message.

A [type-checked example](../fixtures/level-4/usage.ts) exercises the unchanged activity source builder.

The locally evaluated [`live_activity_delivery` r1](../candidates/live_activity_delivery/r1/candidate.json) is retired into this Level; candidate declarations receive the stable migration message.
