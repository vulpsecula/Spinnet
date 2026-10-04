// Calls Host Services by their catalogue IDs through the namespaced SDK,
// which a Plugin declaring the namespaces Candidate Contract runs with.
(() => {
  const text = spinnet.selection.readText({ best_effort: true });
  if (text === null) return spinnet.ui.toast("Nothing is selected");
  spinnet.clipboard.write(text.toUpperCase());
  return spinnet.ui.toast("Copied in capitals");
})()
