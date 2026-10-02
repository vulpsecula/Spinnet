// Reaches a member that only its declared Candidate Contract offers, through
// the raw call, so the Host's member check is all that lets it through.
(() => {
  const language = requestHostService("detect_language", "Bonjour tout le monde, comment allez-vous ?");
  return spinnet.ui.toast("Language: " + (language === null ? "unknown" : language));
})()
