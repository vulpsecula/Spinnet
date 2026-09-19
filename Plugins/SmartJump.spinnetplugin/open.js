(() => {
  // Recognition and the input window share the Host's classifier. Every
  // effect is separately authorized there; no page or file comes back.
  const selection = String(requestHostService("read_selected_text", null)).trim();
  requestHostService("smart_jump", selection);
  return null;
})()
