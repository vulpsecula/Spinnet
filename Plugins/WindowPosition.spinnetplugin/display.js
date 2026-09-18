(() => {
  // The Host lists every display's visible frame left to right, then top to
  // bottom, and says which one holds the focused window.
  const window = requestHostService("read_focused_window");
  const displays = window.displays;
  let step;
  switch (commandID) {
    case "window.next_display":
      step = 1;
      break;
    case "window.previous_display":
      step = -1;
      break;
    default:
      throw new Error("Unknown Window Position Command " + commandID);
  }
  if (displays.length < 2) {
    return null;
  }
  const source = displays[window.displayIndex];
  const target = displays[(window.displayIndex + step + displays.length) % displays.length];

  // Keep the window's size, shrinking it only where it cannot fit, and keep
  // the same share of the free space before it on each axis, so a window
  // against an edge or centred stays so.
  const place = (origin, size, from, fromSize, to, toSize) => {
    const free = fromSize - size;
    const share = free > 0 ? Math.min(Math.max((origin - from) / free, 0), 1) : 0;
    return to + Math.round(share * (toSize - Math.min(size, toSize)));
  };
  requestHostService("set_focused_window_frame", {
    x: place(window.frame.x, window.frame.width, source.x, source.width, target.x, target.width),
    y: place(window.frame.y, window.frame.height, source.y, source.height, target.y, target.height),
    width: Math.min(window.frame.width, target.width),
    height: Math.min(window.frame.height, target.height)
  });
  return null;
})()
