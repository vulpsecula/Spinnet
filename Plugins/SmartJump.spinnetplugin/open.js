(() => {
  // The Plugin sees only the selected text. The Host checks the link again
  // before opening it, so only an http or https link reaches the browser,
  // and it returns nothing about the page.
  const selection = String(requestHostService("read_selected_text", null)).trim();
  if (selection === "") {
    throw new Error("No text is selected");
  }
  requestHostService("open_url", selection);
  return null;
})()
