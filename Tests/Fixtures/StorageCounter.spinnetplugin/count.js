// Counts this Plugin's own runs in Plugin Storage and shows the count as a
// toast, so the user can see it carry on across launches.
(() => {
  const runs = (spinnet.storage.get("runs") ?? 0) + 1;
  spinnet.storage.set({ key: "runs", value: runs });
  return { toast: `Storage Counter has run ${runs} ${runs === 1 ? "time" : "times"}` };
})()
