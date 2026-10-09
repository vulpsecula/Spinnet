(() => {
  const held = spinnet.activities.list();
  const c = spinnet.ui.components;
  return spinnet.ui.showPage(spinnet.ui.page({id: "activities", title: "Coffee Activities", content: [
    c.text({id: "status", text: held.length ? held.map(a => a.name + ": " + a.status).join("\n") : "No active effects"}),
    c.actions({id: "stop", actions: held.map(a => spinnet.activities.stop.action({id: a.id}, {id: a.id, title: "Stop " + a.name, notify: true}))})
  ]}), {state: held});
})();
