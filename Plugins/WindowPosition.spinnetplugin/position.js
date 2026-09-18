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
  // Keep the window's size, shrinking it only where it cannot fit.
  const fittedWidth = Math.min(window.frame.width, screen.width);
  const fittedHeight = Math.min(window.frame.height, screen.height);
  const { x, y, width, height } = window.frame;

  const layouts = {
    "window.maximize": () => screen,
    "window.center": () => centred(fittedWidth, fittedHeight),
    "window.left_half": () => grid(2, 1, 0, 0),
    "window.right_half": () => grid(2, 1, 1, 0),
    "window.top_half": () => grid(1, 2, 0, 0),
    "window.bottom_half": () => grid(1, 2, 0, 1),
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
