(() => {
  // Each Command names a capture source. The Host runs the capture itself and
  // the Plugin never receives the image. The configured folder is handed back
  // unchanged: the Host saves only to the folder configured for this Action.
  const sources = {
    "screenshot.capture_area": "area",
    "screenshot.capture_full_screen": "fullscreen",
    "screenshot.capture_window": "window"
  };
  if (!Object.prototype.hasOwnProperty.call(sources, commandID)) {
    throw new Error("Unknown Screenshot Command " + commandID);
  }
  const settings = input !== null && typeof input === "object" ? input : {};
  const after = settings.after_capture || "Copy to Clipboard";
  const save = after === "Save to Folder" || after === "Copy and Save";
  requestHostService("capture_screen", {
    source: sources[commandID],
    format: settings.format === "JPEG" ? "jpg" : "png",
    copy_to_clipboard: after === "Copy to Clipboard" || after === "Copy and Save",
    save_to_folder: save ? (settings.folder || "") : null
  });
  return null;
})()
