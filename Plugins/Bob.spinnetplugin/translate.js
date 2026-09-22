(() => {
  // Bob owns selection, clipboard, capture, input UI, and translation results.
  // This Plugin only chooses one of Bob's documented translation operations.
  const actions = {
    "bob.selection_translate": "selectionTranslate",
    "bob.snip_translate": "snipTranslate",
    "bob.input_translate": "inputTranslate",
    "bob.pasteboard_translate": "pasteboardTranslate",
    "bob.translate_text": "translateText"
  };
  const action = actions[commandID];
  if (!action) throw new Error("Unknown Bob Command " + commandID);

  const body = { action };
  if (action === "translateText") {
    if (typeof input !== "string") throw new Error("Configure the text Bob should translate");
    body.text = input;
  }

  requestHostService("invoke_external_app", {
    bundle_id: "com.hezongyidev.Bob",
    operation_family: "translate",
    request: { path: "translate", body }
  });
  return null;
})()
