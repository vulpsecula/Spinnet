(() => {
  // The Host remembers where the focused window was before Spinnet last moved
  // it and puts it back; the Plugin names neither the window nor the frame.
  requestHostService("restore_focused_window_frame", null);
  return null;
})()
