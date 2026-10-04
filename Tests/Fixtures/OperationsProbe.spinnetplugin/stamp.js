// Inserts a stamp without a view: nothing showed where it would go, so the
// Host refuses it whichever way it is asked for.
(() => {
  if (input && input.sync) {
    spinnet.selection.replace("2026-10-04");
    return spinnet.ui.toast("Stamped");
  }
  return spinnet.ui.request(spinnet.selection.replace.operation("2026-10-04"));
})()
