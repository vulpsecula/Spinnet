(() => {
  // Full screen is not a frame: the Host moves the focused window into or out
  // of it, and the Plugin names neither the window nor the direction.
  requestHostService("toggle_focused_window_full_screen");
  return null;
})()
