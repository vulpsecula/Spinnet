// MIT License, Copyright (c) 2026 Dzx. See LICENSE.
(() => {
  const ui = spinnet.ui;
  const c = ui.components;
  if (event && event.type === "operation_finished" && event.view_closed) return null;
  const previous = state || { app: null, preferred: "close" };
  const refresh = event && event.type === "action_chosen" && event.action === "refresh";
  const next = !event || event.type === "called"
    ? { app: spinnet.apps.frontmost(), preferred: commandID === "current.quit" ? "quit" : "close" } : previous;
  if (refresh) next.app = spinnet.apps.frontmost();
  const exits = next.app ? next.app.exits : [];
  let operation;
  if (event && event.type === "action_chosen" && event.action === "close" && exits.includes("close")) {
    operation = spinnet.apps.close.operation({ target: next.app.target },
      { id: "close", closesView: true, notify: true });
  }
  if (event && event.type === "action_chosen" && event.action === "quit" && exits.includes("quit")) {
    operation = spinnet.apps.quit.operation({ target: next.app.target, force: false },
      { id: "quit", closesView: true, notify: true });
  }
  if (event && event.type === "action_chosen" && event.action === "force" && exits.includes("force_quit")) {
    operation = spinnet.apps.quit.operation({ target: next.app.target, force: true },
      { id: "force", closesView: true, notify: true });
  }
  const actions = [];
  const preferred = next.preferred || "close";
  const ordinary = preferred === "quit" ? ["quit", "close"] : ["close", "quit"];
  for (const exit of ordinary) {
    if (exits.includes(exit)) actions.push(c.button({ id: exit, title: exit === "close"
      ? "Close " + next.app.name + "'s Window" : "Quit " + next.app.name }));
  }
  const content = [c.text({ id: "target", text: next.app ? next.app.name : "No App in front" })];
  if (next.app) content.push(c.text({ id: "bundle", text: next.app.bundle_id || "No bundle ID" }));
  if (next.app && !exits.includes(preferred)) {
    content.push(c.text({ id: "preferred-status", text: (preferred === "quit" ? "Quit" : "Close Window")
      + " is unavailable for this App. Choose a supported exit or Refresh Target." }));
  }
  if (actions.length) content.push(c.actions({ id: "exits", actions }));
  if (exits.includes("force_quit")) {
    content.push(c.text({ id: "force-warning", text: "Force Quit discards unsaved changes. Spinnet asks before ending the App." }));
    content.push(c.actions({ id: "force-exit", actions: [c.button({ id: "force", title: "Force Quit " + next.app.name })] }));
  }
  content.push(c.text({ id: "refresh-hint", text: "Actions keep the App shown here. Refresh Target reads the App now in front." }));
  content.push(c.actions({ id: "target-actions", actions: [c.button({ id: "refresh", title: "Refresh Target" })] }));
  return ui.showPage(ui.page({
    id: "current", title: "Current App",
    content
  }), { state: next, operation });
})();
