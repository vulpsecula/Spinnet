(() => {
  // The Host reports the focused window and the part of its screen windows
  // may occupy; each Command is a layout within that visible frame.
  const window = requestHostService("read_focused_window");
  const screen = window.visibleFrame;

  // Cells [first, last] of `count` equal parts of a span. Every boundary rounds
  // down, so adjacent cells share an edge (no gaps or overlaps) and the odd
  // points always land in the right-hand or lower cells.
  const cells = (start, length, count, first, last) => {
    const edge = (index) => start + Math.floor((length * index) / count);
    return { start: edge(first), length: edge(last + 1) - edge(first) };
  };
  const grid = (columns, rows, column, row, lastColumn = column, lastRow = row) => {
    const across = cells(screen.x, screen.width, columns, column, lastColumn);
    const down = cells(screen.y, screen.height, rows, row, lastRow);
    return { x: across.start, y: down.start, width: across.length, height: down.length };
  };
  // Thirds and fourths split the longer edge: columns on a landscape screen,
  // rows on a portrait one.
  const portrait = screen.height > screen.width;
  const strip = (count, first, last = first) =>
    portrait ? grid(1, count, 0, first, 0, last) : grid(count, 1, first, 0, last, 0);
  const centred = (width, height) => ({
    x: screen.x + Math.round((screen.width - width) / 2),
    y: screen.y + Math.round((screen.height - height) / 2),
    width,
    height
  });
  // Running a half again on a window already in the current step moves it to
  // the next one: 1/2, 2/3, 1/3, then back to 1/2. The script keeps no state,
  // so the step comes from the window's frame, within 2 points because apps
  // round their frames. The 2/3 and 1/3 steps are thirds cells, so a cycled
  // window lines up with the thirds layouts.
  const matches = (a, b) =>
    ["x", "y", "width", "height"].every((key) => Math.abs(a[key] - b[key]) <= 2);
  const cycle = (steps) => {
    const current = steps.findIndex((step) => matches(window.frame, step));
    return steps[(current + 1) % steps.length];
  };
  // `edge` 0 is the left (or top) half and 1 the right (or bottom) half.
  const halfCycle = (vertical, edge) => {
    const along = (count, first, last) =>
      vertical ? grid(1, count, 0, first, 0, last) : grid(count, 1, first, 0, last, 0);
    return edge === 0
      ? cycle([along(2, 0, 0), along(3, 0, 1), along(3, 0, 0)])
      : cycle([along(2, 1, 1), along(3, 1, 2), along(3, 2, 2)]);
  };
  // Keep the window's size, shrinking it only where it cannot fit.
  const fittedWidth = Math.min(window.frame.width, screen.width);
  const fittedHeight = Math.min(window.frame.height, screen.height);
  const { x, y, width, height } = window.frame;

  const layouts = {
    "window.maximize": () => screen,
    "window.center": () => centred(fittedWidth, fittedHeight),
    "window.left_half": () => halfCycle(false, 0),
    "window.right_half": () => halfCycle(false, 1),
    "window.top_half": () => halfCycle(true, 0),
    "window.bottom_half": () => halfCycle(true, 1),
    "window.first_third": () => strip(3, 0),
    "window.center_third": () => strip(3, 1),
    "window.last_third": () => strip(3, 2),
    "window.first_two_thirds": () => strip(3, 0, 1),
    "window.last_two_thirds": () => strip(3, 1, 2),
    "window.top_left_quarter": () => grid(2, 2, 0, 0),
    "window.top_right_quarter": () => grid(2, 2, 1, 0),
    "window.bottom_left_quarter": () => grid(2, 2, 0, 1),
    "window.bottom_right_quarter": () => grid(2, 2, 1, 1),
    "window.first_fourth": () => strip(4, 0),
    "window.second_fourth": () => strip(4, 1),
    "window.third_fourth": () => strip(4, 2),
    "window.last_fourth": () => strip(4, 3),
    "window.top_left_sixth": () => grid(3, 2, 0, 0),
    "window.top_center_sixth": () => grid(3, 2, 1, 0),
    "window.top_right_sixth": () => grid(3, 2, 2, 0),
    "window.bottom_left_sixth": () => grid(3, 2, 0, 1),
    "window.bottom_center_sixth": () => grid(3, 2, 1, 1),
    "window.bottom_right_sixth": () => grid(3, 2, 2, 1),
    "window.maximize_height": () => ({ x, y: screen.y, width, height: screen.height }),
    "window.maximize_width": () => ({ x: screen.x, y, width: screen.width, height }),
    // 60% of the visible frame, capped at 1025 x 900 points, centred.
    "window.reasonable_size": () =>
      centred(Math.min(Math.round(screen.width * 0.6), 1025), Math.min(Math.round(screen.height * 0.6), 900)),
    "window.move_up": () => ({ x, y: screen.y, width, height: fittedHeight }),
    "window.move_down": () => ({ x, y: screen.y + screen.height - fittedHeight, width, height: fittedHeight }),
    "window.move_left": () => ({ x: screen.x, y, width: fittedWidth, height }),
    "window.move_right": () => ({ x: screen.x + screen.width - fittedWidth, y, width: fittedWidth, height })
  };
  if (!Object.prototype.hasOwnProperty.call(layouts, commandID)) {
    throw new Error("Unknown Window Position Command " + commandID);
  }
  const frame = layouts[commandID]();
  requestHostService("set_focused_window_frame", {
    x: frame.x, y: frame.y, width: frame.width, height: frame.height
  });
  return null;
})()
