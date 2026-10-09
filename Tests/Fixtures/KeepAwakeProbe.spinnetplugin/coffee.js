(() => {
  if (event && event.type === "operation_finished" && event.view_closed) return null;
  let request = input;
  if (event && event.type === "action_chosen") {
    request = event.action === "timed" ? {mode: "duration", seconds: 5}
      : {mode: event.action === "app" ? "app_alive" : "manual"};
  }
  if (request && request.mode) {
    if (request.mode === "app_alive") {
      const app = spinnet.apps.frontmost();
      if (!app) return {toast: "No App in front"};
      request = {mode: "app_alive", target: app.target};
    }
    return spinnet.ui.request(spinnet.system.keepAwake.operation(request, {notify: true, closesView: true}));
  }
  const c = spinnet.ui.components;
  return spinnet.ui.showPage(spinnet.ui.page({id: "coffee", title: "Coffee Host Fixture", content: [
    c.text({id: "scope", text: "Keeps the Mac and display awake while idle. Sleep, lid closure and low battery still apply. Stop from the Spinnet Status Item."}),
    c.actions({id: "start", actions: [c.button({id: "manual", title: "Until stopped"}), c.button({id: "timed", title: "For 5 seconds"}), c.button({id: "app", title: "While App in front runs"})]})
  ]}));
})();
