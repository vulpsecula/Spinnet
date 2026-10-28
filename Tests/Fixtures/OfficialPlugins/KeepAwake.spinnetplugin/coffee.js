// SPDX-License-Identifier: MIT
(() => {
  const ui = spinnet.ui, c = ui.components;
  const s = state || {mode: "manual", minutes: "30", screen: "coffee"};
  const canStart = commandID !== "coffee.activities";
  const canReadApp = ["coffee.open", "coffee.app"].includes(commandID);
  if (event && event.values) {
    if (["manual", "duration", "app_alive"].includes(event.values.mode)) s.mode = event.values.mode;
    if (typeof event.values.minutes === "string") s.minutes = event.values.minutes;
  }
  function start(reset) {
    let request = {mode: "manual"};
    if (s.mode === "duration") {
      if (!/^\d+$/.test(s.minutes.trim()) || Number(s.minutes) < 1 || Number(s.minutes) > 1440)
        return page("Enter a whole number of minutes from 1 to 1440.");
      request = {mode: "duration", seconds: Number(s.minutes) * 60};
    }
    if (s.mode === "app_alive") {
      let app;
      try { app = spinnet.apps.frontmost(); }
      catch (error) {
        if (error.code !== "capability_denied") throw error;
        return page("Keep Awake cannot read the current App. Grant Identify the App in Front in Privacy & Permissions, or choose another mode.");
      }
      if (!app) return page("No App in front. Switch to an ordinary App, then start again.");
      request = {mode: "app_alive", target: app.target};
    }
    return page(undefined, spinnet.system.keepAwake.operation(request, {id: "start", notify: true, closesView: true}), reset);
  }
  function activities(toast, operation) {
    s.screen = "activities";
    const content = [
      c.activityList({id: "held", emptyText: "No active keep-awake effects"}),
      c.text({id: "activity-help", text: "Effects continue after this view closes. Stop one here or from Spinnet’s Status Item."})
    ];
    if (canStart) content.push(c.actions({id: "activity-controls", actions: [c.button({id: "back", title: "New Keep Awake"})]}));
    return ui.showPage(ui.page({id: "activities", title: "Keep Awake Activities", content}), {state: s, toast, operation});
  }
  function page(toast, operation, reset) {
    s.screen = "coffee";
    const content = [
      c.choiceField({id: "mode", title: "Keep awake", choices: ["manual", "duration"].concat(canReadApp ? ["app_alive"] : []),
        choiceTitles: ["Until stopped", "For a duration"].concat(canReadApp ? ["While current App runs"] : []), value: s.mode})
    ];
    if (s.mode === "duration") content.push(
      c.textField({id: "minutes", title: "Duration in minutes", placeholder: "1–1440", value: s.minutes,
        status: "Whole minutes, up to 24 hours"}));
    if (s.mode === "app_alive") content.push(
      c.text({id: "app-policy", text: "Uses the App in front when you press Start. Switching Apps later does not change it. Requires Identify the App in Front access."}));
    content.push(
      c.text({id: "scope", text: "Keeps the Mac and display awake while idle. Sleep, closing the lid and critical battery still apply. Stop from the Spinnet Status Item."}),
      c.actions({id: "controls", actions: [c.button({id: "start", title: "Start Keeping Awake"}), c.button({id: "activities", title: "Active Effects"})]})
    );
    return ui.showPage(ui.page({id: "coffee", title: "Keep Awake", reset, content}), {state: s, toast, operation});
  }
  if (event && event.type === "operation_finished") {
    if (event.view_closed) return null;
    const messages = {
      no_target: "That App is no longer running. Switch to an App and start again.",
      capability_denied: "Keep Awake’s access was denied or revoked. Review its Capabilities in Privacy & Permissions.",
      command_unavailable: "Keep Awake changed or became unavailable. Open its current installed copy again.",
      host_service_failed: "The Host could not start the effect. No new keep-awake effect was created."
    };
    if (event.outcome === "succeeded") return activities();
    const message = messages[event.reason] || "The operation did not complete. Check the Host’s message and try again.";
    return event.operation === "start" ? page(message) : activities(message);
  }
  if (event && event.type === "action_chosen") {
    if (event.action === "activities") return activities();
    if (event.action === "back") return page();
    if (event.action === "start" && canStart)
      return start();
  }
  if (event && event.type === "field_changed") return page();
  if (event === null || event.type === "called") {
    if (commandID === "coffee.manual") { s.mode = "manual"; return start(["mode"]); }
    if (commandID === "coffee.timed") { s.mode = "duration"; s.minutes = "30"; return start(["mode", "minutes"]); }
    if (commandID === "coffee.app") { s.mode = "app_alive"; return start(["mode"]); }
  }
  if (commandID === "coffee.activities") return activities();
  return page();
})();
