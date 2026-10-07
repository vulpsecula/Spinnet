// Spotify- and System Monitor-shaped pages written against Plugin API
// Level 2's Component Styles, columns, icons, images and progress (#81).
//
// "Now Playing" shows a track: its artwork, loaded by the Host from an HTTPS
// host the Command may contact or, with `offline`, from the package's own
// resource; the title, artist and album in their own sizes, weights and
// colours (one colour for each appearance); the known position as a value,
// which the Plugin knows; and transport buttons. The data are fixed here: a
// reviewed Spotify interface and source come with #85.
//
// "System Metrics" shows four cards, each with a background, a system icon,
// its value in large monospaced digits and a bar of the measured fraction;
// Refresh moves to the next fixed sample. Real samples come with #86.
(() => {
  const ui = spinnet.ui, c = ui.components;
  const TRACKS = [
    { id: "t1", title: "Weightless", artist: "Marconi Union", album: "Weightless", seconds: 485,
      artwork: "https://i.scdn.co/image/ab67616d0000b273weightless" },
    { id: "t2", title: "Clair de Lune", artist: "Claude Debussy", album: "Suite bergamasque", seconds: 302,
      artwork: "https://i.scdn.co/image/ab67616d0000b273clairdelune" }
  ];
  const SAMPLES = [
    { cpu: 0.23, memory: 0.61, disk: 0.48, battery: 0.87, charging: false },
    { cpu: 0.71, memory: 0.64, disk: 0.48, battery: 0.86, charging: true }
  ];

  function clock(seconds) {
    const s = Math.round(seconds);
    return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
  }

  function track(s) {
    const t = TRACKS[s.track];
    return ui.page({
      id: "track", title: "Now Playing",
      content: [
        c.row({ id: "now", content: [
          c.image({ id: "artwork", label: "Artwork of " + t.album, width: 96, height: 96, fit: "fill",
                    source: s.offline ? { resource: "artwork/offline.png" } : { url: t.artwork },
                    style: { cornerRadius: 6, background: "secondary" } }),
          c.column({ id: "info", content: [
            c.text({ id: "title", text: t.title, style: { fontSize: 17, fontWeight: "semibold" } }),
            c.text({ id: "artist", text: t.artist, style: { color: "secondary" } }),
            c.text({ id: "album", text: t.album, style: { fontSize: 11, color: { light: "#1A7F37", dark: "#1ED760" } } }),
            c.progress({ id: "position", title: "Position", value: s.position / t.seconds,
                         status: clock(s.position) + " of " + clock(t.seconds), style: { color: "#1DB954" } })
          ] })
        ] }),
        c.actions({ id: "transport", actions: [
          c.button({ id: "previous", title: "Previous" }),
          c.button({ id: "toggle", title: s.playing ? "Pause" : "Play" }),
          c.button({ id: "next", title: "Next" })
        ] })
      ]
    });
  }

  function card(id, symbol, title, value, fraction, detail) {
    return c.column({ id, style: { background: { light: "#F2F2F7", dark: "#2C2C2E" }, padding: 10, cornerRadius: 8 },
      content: [
        c.row({ id: id + "-head", content: [
          c.icon({ id: id + "-icon", source: { symbol }, size: 14, style: { color: "accent" } }),
          c.text({ id: id + "-title", text: title, style: { fontSize: 11, fontWeight: "medium", color: "secondary" } })
        ] }),
        c.text({ id: id + "-value", text: value, style: { fontSize: 28, fontWeight: "bold", monospacedDigits: true } }),
        c.progress({ id: id + "-bar", title: title, value: fraction, status: detail })
      ] });
  }

  function percent(fraction) { return Math.round(fraction * 100) + "%"; }

  function metrics(s) {
    const m = SAMPLES[s.sample % SAMPLES.length];
    return ui.page({
      id: "metrics", title: "System",
      content: [
        c.row({ id: "top", content: [
          card("cpu", "cpu", "CPU", percent(m.cpu), m.cpu, "All cores"),
          card("memory", "memorychip", "Memory", percent(m.memory), m.memory, "Of 16 GB")
        ] }),
        c.row({ id: "bottom", content: [
          card("disk", "internaldrive", "Disk", percent(m.disk), m.disk, "Of 494 GB"),
          card("battery", m.charging ? "battery.100.bolt" : "battery.75", "Battery", percent(m.battery), m.battery,
               m.charging ? "Charging" : "On battery")
        ] }),
        c.actions({ id: "buttons", actions: [c.button({ id: "refresh", title: "Refresh" })] })
      ]
    });
  }

  const isTrack = spinnet.environment.commandID === "media.track";
  const kept = state || (isTrack ? { track: 0, position: 133, playing: true, offline: !!(input && input.offline) }
                                 : { sample: 0 });
  const show = (s) => ui.showPage(isTrack ? track(s) : metrics(s), { state: s });
  if (event === null || event.type === "called") return show(kept);
  if (event.type !== "action_chosen") return null;
  switch (event.action) {
    case "toggle": return show(Object.assign({}, kept, { playing: !kept.playing }));
    case "next": return show(Object.assign({}, kept, { track: (kept.track + 1) % TRACKS.length, position: 0 }));
    case "previous": return show(Object.assign({}, kept, { position: 0 }));
    case "refresh": return show(Object.assign({}, kept, { sample: kept.sample + 1 }));
    default: return null;
  }
})()
