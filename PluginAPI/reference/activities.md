# Activity source delivery

Changed `activities.list` source results can reach the Plugin at a minimum interval of **one second**.
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
Other sources retain a 15-second delivery floor. The per-source floor survives page/source
redefinitions. The maximum of eight sources per page, 512 KiB result bound,
one sample in flight, one pending result, change coalescing, owner checks,
visibility rules and queued-event validity all remain unchanged.


See the [current types](../sdk/spinnet.d.ts) and [contract sample](../fixtures/sdk/activity-source.ts).
