// A symbol picker written against Candidate Contract host_operations r1.
// Its view asks the Host to name where text goes; Return requests the
// insertion, which the Host performs after this answer commits.
(() => {
  const ui = spinnet.ui;
  const symbols = { star: "★", heart: "♥", arrow: "→" };
  const kept = state || { count: 0, last: null };

  function view(query, note) {
    return ui.view({
      title: "Symbols",
      subtitle: note,
      showsInsertionTarget: true,
      form: ui.form({ fields: [ui.textField({ key: "query", title: "Symbol", value: query })], submitOnReturn: true }),
      actions: [
        ui.insertText({ title: "Insert ★", text: "★" }),
        ui.action({ id: "copy", title: "Copy ♥" }),
        ui.action({ id: "type-now", title: "Type → now" })
      ]
    });
  }

  if (event === null) return ui.show(view("star"), { state: kept });
  switch (event.type) {
    case "submitted": {
      const text = symbols[event.values.query] || event.values.query;
      return ui.show(view(event.values.query), {
        state: { count: kept.count + 1, last: kept.last },
        operation: spinnet.selection.replace.operation({ text }, { id: "insert", closesView: true, notify: true })
      });
    }
    case "action_chosen":
      if (event.action === "copy") {
        return ui.request(spinnet.clipboard.write.operation("♥", { id: "copy" }), { toast: "Copying ♥" });
      }
      spinnet.selection.replace("→");
      return ui.show(view("arrow", "Typed →"), { state: kept });
    case "operation_finished":
      return ui.show(view("star", event.outcome + (event.reason ? " (" + event.reason + ")" : "")), {
        state: { count: kept.count, last: [event.operation, event.perform, event.outcome, event.reason || null] }
      });
    default:
      return ui.show(view(event.values ? event.values.query : "star"), { state: kept });
  }
})()
