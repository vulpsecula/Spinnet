(() => {
  const routes = {
    "shottr.capture_area": "area",
    "shottr.capture_fullscreen": "fullscreen",
    "shottr.capture_window": "window",
    "shottr.capture_repeat_area": "repeat",
    "shottr.capture_scrolling": "scrolling",
    "shottr.capture_scrolling_reverse": "scrolling/reverse",
    "shottr.capture_delayed": "delayed",
    "shottr.append_capture": "append"
  };
  const route = routes[commandID];
  if (!route) throw new Error("Unknown Shottr Command " + commandID);

  const options = ["copy", "save", "edit", "pin", "thumbnail"];
  const postCapture = options.filter(option => input && input[option] === true);
  const request = { route, post_capture: postCapture };
  if (commandID === "shottr.capture_delayed") request.delay_seconds = input.delay_seconds;

  requestHostService("invoke_external_app", {
    bundle_id: "cc.ffitch.shottr",
    operation_family: "capture",
    request
  });
  return null;
})()
