(() => {
  // The Host reads the current selection when possible and otherwise presents
  // its input window. Effects stay separately authorized; no page or file
  // contents come back.
  requestHostService("smart_jump", null);
  return null;
})()
