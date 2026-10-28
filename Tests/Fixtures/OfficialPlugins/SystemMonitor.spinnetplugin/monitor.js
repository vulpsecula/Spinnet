// SPDX-License-Identifier: MIT
(() => {
  if (event && event.type !== "called") return null;
  const ui = spinnet.ui, c = ui.components;
  function value(id, title, symbol, pointer, format, detail, detailPointer) {
    return c.column({id: id + "-card", style: {background: {light: "#F2F2F7", dark: "#2C2C2E"}, padding: 8, cornerRadius: 10}, content: [
      c.row({id: id + "-header", content: [
        c.icon({id: id + "-icon", source: {symbol}, size: 18, style: {color: "accent"}}),
        c.text({id: id + "-title", text: title, style: {fontSize: 12, fontWeight: "semibold", color: "secondary"}})
      ]}),
      c.text({id: id + "-value", text: "—", bind: c.bind("metrics", pointer, {format, unavailable: "Unavailable"}), style: {fontSize: 26, fontWeight: "bold", monospacedDigits: true}}),
      c.text({id: id + "-detail", text: detail, bind: detailPointer ? c.bind("metrics", detailPointer, {format: id === "battery" ? "text" : "bytes", unavailable: id === "battery" ? "No battery or unavailable" : "Unavailable"}) : undefined, style: {fontSize: 11, color: "secondary"}})
    ]});
  }
  const metricIDs = ["cpu", "memory", "disk", "battery"];
  function profile(id, minCardWidth, minCardHeight, spacing, titles, valueSize, detailSize, hidesDetails) {
    return {id, minCardWidth, minCardHeight, spacing, overrides: metricIDs.flatMap((metric, index) => [
      {id: metric + "-title", text: titles[index], style: {fontSize: id === "compact" ? 11 : 12, fontWeight: "semibold", color: "secondary"}},
      {id: metric + "-value", style: {fontSize: valueSize, fontWeight: "bold", monospacedDigits: true}},
      hidesDetails ? {id: metric + "-detail", hidden: true} : {id: metric + "-detail", style: {fontSize: detailSize, color: "secondary"}}
    ])};
  }
  return ui.showPage(ui.page({id: "monitor", title: "System Monitor", subtitle: "Live while visible · Pin to keep nearby", resizable: {minWidth: 440, minHeight: 420},
    sources: [spinnet.system.metrics.source("metrics", {metrics: ["cpu", "memory", "disk", "battery"]}, {every: 1})],
    content: [c.adaptive({id: "metric-cards", minCardWidth: 320, spacing: 12, maxColumns: 2,
      fit: {profiles: [
        profile("compact", 180, 80, 8, ["CPU", "Memory", "Disk free", "Battery"], 20, 11, true),
        profile("standard", 280, 120, 12, ["CPU · all cores", "Memory · used", "Startup disk · available", "Internal battery"], 26, 11, false),
        profile("spacious", 320, 200, 16, ["CPU · all cores", "Memory · active + wired + compressed", "Startup disk · available", "Internal battery"], 32, 12, false)
      ]}, content: [
        value("cpu", "CPU · all cores", "cpu", "/cpu/busy", "percent", "Busy since the previous visible reading"),
        value("memory", "Memory · active + wired + compressed", "memorychip", "/memory/used_bytes", "bytes", "Physical memory", "/memory/total_bytes"),
        value("disk", "Startup disk · available", "internaldrive", "/disk/available_bytes", "bytes", "Volume capacity", "/disk/total_bytes"),
        value("battery", "Internal battery", "battery.100", "/battery/charge", "percent", "Power source", "/battery/power_source")
      ]})]}), {state: {page: "monitor"}});
})()
