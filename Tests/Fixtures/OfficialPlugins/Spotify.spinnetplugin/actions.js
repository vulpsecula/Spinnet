(function () {
  if (event && event.type !== "called") return null;
  if (commandID === "spotify.mute") {
    const current = spinnet.apps.perform({bundle_id: "com.spotify.client", operation: "volume"});
    if (!current || !Number.isInteger(current.volume) || current.volume < 0 || current.volume > 100)
      return spinnet.ui.toast("Spotify volume could not be read. Mute was not changed.");
    const muting = current.volume > 0;
    let target = 0;
    if (muting) {
      // Persist before changing Spotify so a failed write cannot lose the restore level.
      spinnet.storage.set({key: "last-nonzero-volume", value: current.volume});
    } else {
      const remembered = spinnet.storage.get("last-nonzero-volume");
      target = Number.isInteger(remembered) && remembered >= 1 && remembered <= 100 ? remembered : 50;
    }
    const observed = spinnet.apps.perform({bundle_id: "com.spotify.client", operation: "set_volume", arguments: {volume: target}});
    if (!observed || !Number.isInteger(observed.volume) || observed.volume < 0 || observed.volume > 100)
      return spinnet.ui.toast("Spotify mute request was sent; the current volume could not be confirmed.");
    if (muting && observed.volume === 0) return spinnet.ui.toast("Spotify muted.");
    if (!muting && observed.volume > 0) return spinnet.ui.toast("Spotify unmuted: " + observed.volume + "%.");
    return spinnet.ui.toast("Spotify mute change was not confirmed. Current volume: " + observed.volume + "%.");
  }
  const operations = {
    "spotify.toggle": ["play_pause", "Play/Pause sent to Spotify."],
    "spotify.play": ["play", "Play sent to Spotify."],
    "spotify.pause": ["pause", "Pause sent to Spotify."],
    "spotify.previous": ["previous", "Previous sent to Spotify."]
  };
  if (commandID === "spotify.next") {
    const result = spinnet.apps.perform({bundle_id: "com.spotify.client", operation: "next_checked"});
    const feedback = {
      changed: "Spotify track changed.",
      unconfirmed: "No track change confirmed. Check Spotify's queue.",
      no_current_track: "No current track. Choose a song in Spotify.",
      stopped: "Spotify playback is stopped. Choose a song or resume playback."
    };
    return spinnet.ui.toast(feedback[result && result.outcome] || "No track change confirmed. Check Spotify's queue.");
  }
  const volumeAction = commandID === "spotify.volume-up" || commandID === "spotify.volume-down" || commandID === "spotify.volume";
  if (volumeAction) {
    let operation = "adjust_volume";
    let args = {delta: commandID === "spotify.volume-down" ? -5 : 5};
    if (commandID === "spotify.volume") {
      const text = typeof input === "string" ? input.trim() : "";
      if (!/^(0|[1-9][0-9]?|100)$/.test(text)) return spinnet.ui.toast("Set Volume needs a whole number from 0 to 100.");
      operation = "set_volume";
      args = {volume: Number(text)};
    }
    const result = spinnet.apps.perform({bundle_id: "com.spotify.client", operation, arguments: args});
    if (!result || !Number.isInteger(result.volume) || result.volume < 0 || result.volume > 100)
      return spinnet.ui.toast("Spotify volume request was sent; the current volume could not be confirmed.");
    return spinnet.ui.toast("Spotify volume: " + result.volume + "%.");
  }
  const selected = operations[commandID];
  if (!selected) throw new Error("Unknown Spotify Action.");
  spinnet.apps.perform({bundle_id: "com.spotify.client", operation: selected[0]});
  return spinnet.ui.toast(selected[1]);
})();
