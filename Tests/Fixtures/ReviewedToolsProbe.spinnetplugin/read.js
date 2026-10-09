(() => {
  let result;
  try { result = spinnet.tools.read(input); }
  catch (error) {
    return spinnet.ui.showPage(spinnet.ui.page({id: "packages", title: "Local packages", content: [spinnet.ui.components.text({id: "error", text: error.message})]}), {state: {error: error.code}});
  }
  const rows = result.packages.map(p => ({id: p.kind + ":" + p.name, title: p.title || p.name, subtitle: p.version}));
  return spinnet.ui.showPage(spinnet.ui.page({id: "packages", title: "Local packages", content: [spinnet.ui.components.list({id: "packages", items: rows})]}), {state: result});
})()
