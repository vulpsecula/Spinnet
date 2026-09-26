(() => {
  // The Host reads the current selection when possible and otherwise presents
  // its input window. Effects stay separately authorized; no page or file
  // contents come back. Unrecognised text searches the first engine.
  requestHostService("smart_jump", { text: null, engines: input.search_engines });
  return null;
})()
