(() => {
  // Each Action carries its own "first, second" value: two lengths, each in
  // points or as a percentage of the visible frame. The Host checks the same
  // grammar when the Configuration Sheet saves; this refuses anything else
  // before touching a window.
  const allowsZero = commandID === "window.move";
  function parse(value) {
    const parts = typeof value === "string" ? value.split(",") : [];
    if (parts.length !== 2) throw new Error("Expected two values such as 800, 600 or 50%, 100%");
    return parts.map((part) => {
      const match = /^\s*(\d+(?:\.\d+)?)(%?)\s*$/.exec(part);
      const amount = match ? Number(match[1]) : NaN;
      const percent = match !== null && match[2] === "%";
      if (!Number.isFinite(amount) || (!allowsZero && amount === 0) || (percent && amount > 100)) {
        throw new Error("Invalid window value " + part.trim());
      }
      return (extent) => Math.round(percent ? extent * amount / 100 : amount);
    });
  }

  const [first, second] = parse(input);
  const window = requestHostService("read_focused_window");
  const screen = window.visibleFrame;
  const right = screen.x + screen.width;
  const bottom = screen.y + screen.height;
  let frame;
  switch (commandID) {
    case "window.resize": {
      // Keep the top-left corner (pulled inside the visible frame if the
      // window starts outside it) and shrink only where the size would leave.
      const x = Math.min(Math.max(window.frame.x, screen.x), right - 1);
      const y = Math.min(Math.max(window.frame.y, screen.y), bottom - 1);
      frame = {
        x, y,
        width: Math.max(1, Math.min(first(screen.width), right - x)),
        height: Math.max(1, Math.min(second(screen.height), bottom - y))
      };
      break;
    }
    case "window.move": {
      // Keep the size, shrinking only a window larger than the visible frame,
      // and keep the whole window inside it.
      const width = Math.min(window.frame.width, screen.width);
      const height = Math.min(window.frame.height, screen.height);
      frame = {
        x: screen.x + Math.min(first(screen.width), screen.width - width),
        y: screen.y + Math.min(second(screen.height), screen.height - height),
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
