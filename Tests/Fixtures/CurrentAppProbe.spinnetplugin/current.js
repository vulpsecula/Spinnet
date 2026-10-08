// A Current App-shaped Plugin written against Plugin API Level 2's App in
// front (#83): it names the App behind Spinnet's panel, keeps its App
// Target, and offers Quit and Force Quit of that App; the Host confirms
// Force Quit, and a Quit once that App is no longer in front. It records each outcome it hears, which never names the App.
(() => {
  const ui = spinnet.ui, c = ui.components;

  function page(s) {
    const app = s.app;
    const exits = app ? app.exits : [];
    const buttons = [];
    if (exits.includes("quit")) buttons.push(c.button({ id: "quit", title: "Quit" }));
    if (exits.includes("force_quit")) buttons.push(c.button({ id: "force", title: "Force Quit" }));
    // A page action quitting whatever App is in front when the Host acts.
    buttons.push(spinnet.apps.quit.action(null, { id: "quit-front", title: "Quit App in Front", notify: true }));
    return ui.page({
      id: "current", title: "Current App",
      content: [
        c.text({ id: "name", text: app ? app.name + " (" + (app.bundle_id || "no bundle ID") + ")" : "No App in front" }),
        c.actions({ id: "exits", actions: buttons })
      ]
    });
  }

  const s = state || { app: null, outcomes: [] };
  if (event === null) {
    const app = spinnet.apps.frontmost();
    const next = { app, outcomes: s.outcomes || [] };
    return ui.showPage(page(next), { state: next });
  }
  if (event.type === "action_chosen" && (event.action === "quit" || event.action === "force")) {
    if (!s.app) return ui.showPage(page(s), { state: s, toast: "No App to quit" });
    const operation = spinnet.apps.quit.operation(
      { target: s.app.target, force: event.action === "force" },
      { id: event.action, notify: true });
    return ui.showPage(page(s), { state: s, operation });
  }
  if (event.type === "operation_finished") {
    const next = { app: s.app, outcomes: s.outcomes.concat([[event.operation, event.outcome, event.reason || null]]) };
    return ui.showPage(page(next), { state: next });
  }
  return ui.showPage(page(s), { state: s });
})();
