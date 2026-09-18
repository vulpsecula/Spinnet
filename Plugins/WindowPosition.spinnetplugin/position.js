(() => {
  // The Host reports the focused window and the part of its screen windows
  // may occupy; each Command is a layout within that visible frame.
  const window = requestHostService("read_focused_window");
  const screen = window.visibleFrame;
  const leftWidth = Math.floor(screen.width / 2);
  let frame;
  switch (commandID) {
    case "window.maximize":
      frame = screen;
      break;
    case "window.left_half":
      frame = { x: screen.x, y: screen.y, width: leftWidth, height: screen.height };
      break;
    case "window.right_half":
      frame = { x: screen.x + leftWidth, y: screen.y, width: screen.width - leftWidth, height: screen.height };
      break;
    case "window.center": {
      // Keep the window's size, shrinking it only where it cannot fit.
      const width = Math.min(window.frame.width, screen.width);
      const height = Math.min(window.frame.height, screen.height);
      frame = {
        x: screen.x + Math.round((screen.width - width) / 2),
        y: screen.y + Math.round((screen.height - height) / 2),
        width,
        height
      };
      break;
    }
    default:
      throw new Error("Unknown Window Position Command " + commandID);
  }
  requestHostService("set_focused_window_frame", {
    x: frame.x, y: frame.y, width: frame.width, height: frame.height
  });
  return null;
})()
