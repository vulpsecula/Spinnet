// A Current App-shaped Plugin written against Plugin API Level 2's App in
// front (#83): it names the App behind Spinnet's panel, keeps its App
// Target, and offers what the Host says it would do to that App: Close
// Window and Quit, which are the App's own ⌘W and ⌘Q, and Force Quit. The
// Host confirms Force Quit, and a Close or Quit once that App is no longer
// in front. It records each outcome it hears, which never names the App.
(() => {
  const ui = spinnet.ui, c = ui.components;

  function page(s) {
    const app = s.app;
    const exits = app ? app.exits : [];
    const buttons = [];
    if (exits.includes("close")) buttons.push(c.button({ id: "close", title: "Close Window" }));
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
  if (event.type === "action_chosen" && ["close", "quit", "force"].includes(event.action)) {
    if (!s.app) return ui.showPage(page(s), { state: s, toast: "No App in front" });
    // Its work done, the view closes (unless the user pinned it); a
    // refusal keeps it open with the Host's reason.
    const operation = event.action === "close"
      ? spinnet.apps.close.operation({ target: s.app.target }, { id: "close", closesView: true, notify: true })
      : spinnet.apps.quit.operation({ target: s.app.target, force: event.action === "force" },
                                    { id: event.action, closesView: true, notify: true });
    return ui.showPage(page(s), { state: s, operation });
  }
  // Told after its view closed (its own closes_view on success): there is
  // no view to answer, so nothing is.
  if (event.type === "operation_finished" && event.view_closed) return null;
  if (event.type === "operation_finished") {
    // What the App offers may have changed (its last window closed, or it
    // quit), so the App in front is read again.
    const next = { app: spinnet.apps.frontmost(),
                   outcomes: s.outcomes.concat([[event.operation, event.outcome, event.reason || null]]) };
    return ui.showPage(page(next), { state: next });
  }
  return ui.showPage(page(s), { state: s });
})();
