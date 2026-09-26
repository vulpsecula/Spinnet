(() => {
  // Bob owns clipboard, capture, input UI, and translation results. This
  // Plugin only chooses one of the translation operations in the Host's
  // Reviewed App Interface for Bob. The selection is read by the Host, which
  // falls back to a copy where Bob's own read often fails; Bob reads it
  // itself only when the Host cannot.
  const operations = {
    "bob.selection_translate": "selectionTranslate",
    "bob.snip_translate": "snipTranslate",
    "bob.input_translate": "inputTranslate",
    "bob.pasteboard_translate": "pasteboardTranslate",
    "bob.translate_text": "translateText"
  };
  let operation = operations[commandID];
  if (!operation) throw new Error("Unknown Bob Command " + commandID);

  let text = input;
  if (operation === "selectionTranslate") {
    // null means the Host could not read the selection, so Bob tries itself.
    const selection = requestHostService("read_selected_text", { best_effort: true });
    if (typeof selection === "string") {
      operation = selection.trim() ? "translateText" : "inputTranslate";
      text = selection;
    }
  }

  const request = { bundle_id: "com.hezongyidev.Bob", operation };
  if (operation === "translateText") {
    if (typeof text !== "string") throw new Error("Configure the text Bob should translate");
    request.arguments = { text };
  }

  requestHostService("perform_app_operation", request);
  return null;
})()
