// Reads the App in front, which its Command may, then asks to force quit
// it, which its Command may not: identifying an App grants no exit (#83).
(() => {
  const app = spinnet.apps.frontmost();
  if (!app) return spinnet.ui.toast("No App in front");
  return spinnet.ui.request(spinnet.apps.quit.operation({ target: app.target, force: true }),
                            { toast: "Peeked at " + app.name });
})();
