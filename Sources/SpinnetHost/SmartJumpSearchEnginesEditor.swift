import SpinnetCore
import SwiftUI

/// Edits the ordered search destinations as rows. The first row is the
/// default; values still use the manifest's stable line based format.
struct SmartJumpSearchEnginesEditor: View {
    @Binding private var value: String
    @State private var engines: [EngineDraft]
    @State private var lastWrittenValue: String

    init(value: Binding<String>) {
        _value = value
        let initial = value.wrappedValue
        _engines = State(initialValue: Self.drafts(from: initial))
        _lastWrittenValue = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Search URLs must use HTTPS and include {query}. The first engine is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Array(engines.enumerated()), id: \.element.id) { index, engine in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField("Engine name", text: nameBinding(at: index))
                            .textFieldStyle(.roundedBorder)
                        if index == 0 {
                            Label("Default", systemImage: "star.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                        }
                        Spacer(minLength: 0)
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(engine.name) up")
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .disabled(index == engines.count - 1)
                            .accessibilityLabel("Move \(engine.name) down")
                        Button(role: .destructive) { remove(index) } label: { Image(systemName: "minus.circle") }
                            .disabled(engines.count == 1)
                            .accessibilityLabel("Remove \(engine.name)")
                    }
                    TextField("Search URL containing {query}", text: templateBinding(at: index))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(engine.name) search URL")
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
            }

            Button(action: add) {
                Label("Add Search Engine", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(engines.count >= 10)
        }
        .onChange(of: value) { updated in
            guard updated != lastWrittenValue else { return }
            engines = Self.drafts(from: updated)
            lastWrittenValue = updated
        }
    }

    private func nameBinding(at index: Int) -> Binding<String> {
        Binding(get: { engines[index].name }, set: { updated in
            update(index) { $0.name = updated.replacingOccurrences(of: "|", with: "") }
        })
    }

    private func templateBinding(at index: Int) -> Binding<String> {
        Binding(get: { engines[index].template }, set: { updated in
            update(index) { $0.template = updated.replacingOccurrences(of: "\n", with: "") }
        })
    }

    private func update(_ index: Int, _ change: (inout EngineDraft) -> Void) {
        guard engines.indices.contains(index) else { return }
        change(&engines[index])
        writeValue()
    }

    private func move(_ index: Int, by offset: Int) {
        let destination = index + offset
        guard engines.indices.contains(index), engines.indices.contains(destination) else { return }
        engines.swapAt(index, destination)
        writeValue()
    }

    private func remove(_ index: Int) {
        guard engines.indices.contains(index), engines.count > 1 else { return }
        engines.remove(at: index)
        writeValue()
    }

    private func add() {
        guard engines.count < 10 else { return }
        let name = "Search Engine \(engines.count + 1)"
        engines.append(EngineDraft(name: name, template: ""))
        writeValue()
    }

    private func writeValue() {
        let serialized = engines.map { "\($0.name) | \($0.template)" }.joined(separator: "\n")
        lastWrittenValue = serialized
        value = serialized
    }

    private static func drafts(from value: String) -> [EngineDraft] {
        let parsed = (try? SmartJumpSearchEngine.parse(value)) ?? []
        if !parsed.isEmpty {
            return parsed.map { EngineDraft(name: $0.name, template: $0.template) }
        }
        let rows = value.split(whereSeparator: \.isNewline).compactMap { line -> EngineDraft? in
            let fields = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            return EngineDraft(name: fields[0].trimmingCharacters(in: .whitespaces),
                               template: fields[1].trimmingCharacters(in: .whitespaces))
        }
        return rows.isEmpty ? [EngineDraft(name: "Google", template: SmartJumpSearchEngine.google.template)] : rows
    }
}

private struct EngineDraft: Identifiable {
    let id = UUID()
    var name: String
    var template: String
}
