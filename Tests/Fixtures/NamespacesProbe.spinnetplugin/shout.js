// Calls Host Services by their catalogue IDs through the namespaced SDK,
// which the current Plugin interface exposes.
(() => {
  const text = spinnet.selection.readText({ best_effort: true });
  if (text === null) return spinnet.ui.toast("Nothing is selected");
  spinnet.clipboard.write(text.toUpperCase());
  return spinnet.ui.toast("Copied in capitals");
})()
