(() => {
  // Bob owns clipboard, capture, input UI, and translation results. This
  // Plugin only chooses one of Bob's documented translation operations. The
  // selection is read by the Host, which falls back to a copy where Bob's own
  // read often fails; Bob reads it itself only when the Host cannot.
  const actions = {
    "bob.selection_translate": "selectionTranslate",
    "bob.snip_translate": "snipTranslate",
    "bob.input_translate": "inputTranslate",
    "bob.pasteboard_translate": "pasteboardTranslate",
    "bob.translate_text": "translateText"
  };
  let action = actions[commandID];
  if (!action) throw new Error("Unknown Bob Command " + commandID);

  let text = input;
  if (action === "selectionTranslate") {
    // null means the Host could not read the selection, so Bob tries itself.
    const selection = requestHostService("read_selected_text", { best_effort: true });
    if (typeof selection === "string") {
      action = selection.trim() ? "translateText" : "inputTranslate";
      text = selection;
    }
  }

  const body = { action };
  if (action === "translateText") {
    if (typeof text !== "string") throw new Error("Configure the text Bob should translate");
    body.text = text;
  }

  requestHostService("invoke_external_app", {
    bundle_id: "com.hezongyidev.Bob",
    operation_family: "translate",
    request: { path: "translate", body }
  });
  return null;
})()
