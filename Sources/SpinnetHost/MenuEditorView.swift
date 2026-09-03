import SwiftUI
import SpinnetCore

struct MenuEditorView: View {
    let editor: HostConfigurationEditor
    let onConfigurationChanged: (HostConfiguration) -> Void

    @State private var selectedCommandIndex = 0
    @State private var selectedActionIndex = 0
    @State private var inputText = ""
    @State private var selectedMenuIndex = 0
    @State private var selectedPrimaryActionID: ActionID?
    @State private var selectedAlternateActionIDs = Set<ActionID>()
    @State private var errorMessage: String?

    private var commands: [AvailableCommand] {
        editor.availableCommands
    }

    private var actions: [ActionConfiguration] {
        editor.configuration.actions
    }

    private var menuItems: [MenuItemConfiguration] {
        editor.configuration.menu.items
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                pageHeader(
                    title: SettingsPage.menu.title,
                    description: "Configure the Actions exposed by the current Menu."
                )

                Text("Create an Action from an available Command, then bind it as the Primary Action or one of the Alternate Actions for a Menu Item.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Available Plugin Commands") {
                    if commands.isEmpty {
                        Text("No Plugin Commands are currently available.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Available Plugin Commands", selection: $selectedCommandIndex) {
                            ForEach(commands.indices, id: \.self) { index in
                                Text(commandTitle(commands[index])).tag(index)
                            }
                        }
                        .accessibilityLabel("Available Plugin Commands")
                    }
                    Button("Create Action") {
                        createAction()
                    }
                    .disabled(commands.isEmpty)
                    .accessibilityLabel("Create Action")
                }

                GroupBox("Configured Actions") {
                    if actions.isEmpty {
                        Text("No Actions are configured.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Configured Actions", selection: $selectedActionIndex) {
                            ForEach(actions.indices, id: \.self) { index in
                                Text(actionTitle(actions[index])).tag(index)
                            }
                        }
                        .accessibilityLabel("Configured Actions")
                        TextField("Text or JSON value", text: $inputText)
                            .accessibilityLabel("Action configuration input")
                        HStack(spacing: 8) {
                            Button("Save Action Changes") {
                                updateAction()
                            }
                            Button("Remove Action", role: .destructive) {
                                removeAction()
                            }
                        }
                    }
                }

                GroupBox("Bind Actions to a Menu Item") {
                    if menuItems.indices.contains(selectedMenuIndex) {
                        Picker("Menu Item", selection: $selectedMenuIndex) {
                            ForEach(menuItems.indices, id: \.self) { index in
                                Text("Menu Item \(index + 1)").tag(index)
                            }
                        }
                        .accessibilityLabel("Menu Item")
                        .accessibilityHint("Choose the Menu Item whose Actions you want to bind.")

                        Picker("Primary Action", selection: primaryActionBinding) {
                            ForEach(actions, id: \.id) { action in
                                Text(actionTitle(action)).tag(action.id)
                            }
                        }
                        .accessibilityLabel("Primary Action")
                        .accessibilityHint("This Action runs when the Menu Item is selected normally.")

                        Text("Alternate Actions")
                            .font(.headline)
                        ForEach(actions.filter { $0.id != selectedPrimaryActionID }, id: \.id) { action in
                            Toggle(
                                actionTitle(action),
                                isOn: alternateBinding(for: action.id)
                            )
                            .accessibilityLabel("Alternate Action \(action.title)")
                        }
                        if actions.count <= 1 {
                            Text("Create another Action to add an Alternate Action.")
                                .foregroundStyle(.secondary)
                        }
                        Button("Save Menu Binding") {
                            saveBinding()
                        }
                        .accessibilityLabel("Save Menu Binding")

                        HStack(spacing: 8) {
                            Button("Add Menu Item") {
                                addMenuItem()
                            }
                            Button("Remove Menu Item", role: .destructive) {
                                removeMenuItem()
                            }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(errorMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Menu Editor")
        .onAppear {
            refreshSelection()
        }
        .onChange(of: selectedActionIndex) { _ in
            updateActionSelection()
        }
        .onChange(of: selectedMenuIndex) { _ in
            updateBindingSelection()
        }
    }

    private var primaryActionBinding: Binding<ActionID> {
        Binding(
            get: {
                selectedPrimaryActionID
                    ?? menuItems[safe: selectedMenuIndex]?.primaryActionID
                    ?? actions.first?.id
                    ?? ActionID("")
            },
            set: { newValue in
                selectedPrimaryActionID = newValue
                selectedAlternateActionIDs.remove(newValue)
            }
        )
    }

    private func alternateBinding(for actionID: ActionID) -> Binding<Bool> {
        Binding(
            get: { selectedAlternateActionIDs.contains(actionID) },
            set: { isSelected in
                if isSelected {
                    selectedAlternateActionIDs.insert(actionID)
                } else {
                    selectedAlternateActionIDs.remove(actionID)
                }
            }
        )
    }

    private func refreshSelection() {
        selectedCommandIndex = min(selectedCommandIndex, max(commands.count - 1, 0))
        selectedActionIndex = min(selectedActionIndex, max(actions.count - 1, 0))
        selectedMenuIndex = min(selectedMenuIndex, max(menuItems.count - 1, 0))
        updateActionSelection()
        updateBindingSelection()
        errorMessage = nil
    }

    private func updateInputFromSelection() {
        guard let action = actions[safe: selectedActionIndex] else {
            inputText = ""
            return
        }
        inputText = displayValue(for: action.input)
    }

    private func updateActionSelection() {
        updateInputFromSelection()
        guard let action = actions[safe: selectedActionIndex],
              let commandIndex = commands.firstIndex(where: {
                  $0.pluginID == action.pluginID && $0.commandID == action.commandID
              }) else {
            return
        }
        selectedCommandIndex = commandIndex
    }

    private func updateBindingSelection() {
        guard let menuItem = menuItems[safe: selectedMenuIndex] else {
            selectedPrimaryActionID = nil
            selectedAlternateActionIDs = []
            return
        }
        selectedPrimaryActionID = menuItem.primaryActionID
        selectedAlternateActionIDs = Set(menuItem.alternateActionIDs)
    }

    private func commit(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
            refreshSelection()
            onConfigurationChanged(editor.configuration)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createAction() {
        guard let command = commands[safe: selectedCommandIndex] else { return }
        commit {
            _ = try editor.createAction(
                pluginID: command.pluginID,
                commandID: command.commandID,
                input: inputValue()
            )
        }
    }

    private func updateAction() {
        guard let action = actions[safe: selectedActionIndex],
              let command = commands[safe: selectedCommandIndex] else {
            errorMessage = "Select an Action and an available replacement Command first"
            return
        }
        commit {
            _ = try editor.updateAction(
                id: action.id,
                pluginID: command.pluginID,
                commandID: command.commandID,
                input: inputValue()
            )
        }
    }

    private func removeAction() {
        guard let action = actions[safe: selectedActionIndex] else {
            errorMessage = "Select an Action first"
            return
        }
        commit {
            try editor.removeAction(action.id)
        }
    }

    private func saveBinding() {
        guard menuItems.indices.contains(selectedMenuIndex),
              let primaryActionID = selectedPrimaryActionID else {
            errorMessage = "Select a Menu Item and Primary Action first"
            return
        }
        let alternateActionIDs = actions
            .map(\.id)
            .filter { $0 != primaryActionID && selectedAlternateActionIDs.contains($0) }
        commit {
            try editor.updateMenuItem(
                at: selectedMenuIndex,
                primaryActionID: primaryActionID,
                alternateActionIDs: alternateActionIDs
            )
        }
    }

    private func addMenuItem() {
        let boundIDs = Set(menuItems.flatMap { [$0.primaryActionID] + $0.alternateActionIDs })
        guard let action = actions.first(where: { !boundIDs.contains($0.id) }) else {
            errorMessage = "Create an unbound Action before adding a Menu Item"
            return
        }
        commit {
            try editor.addMenuItem(primaryActionID: action.id)
        }
    }

    private func removeMenuItem() {
        commit {
            try editor.removeMenuItem(at: selectedMenuIndex)
        }
    }

    private func inputValue() -> JSONValue {
        if let data = inputText.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value
        }
        return .string(inputText)
    }

    private func displayValue(for value: JSONValue) -> String {
        if case .string(let value) = value { return value }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func commandTitle(_ command: AvailableCommand) -> String {
        "\(command.pluginName) — \(command.title) (\(command.commandID.rawValue))"
    }

    private func actionTitle(_ action: ActionConfiguration) -> String {
        guard let availability = editor.availability(for: action.id), !availability.isAvailable else {
            return action.title
        }
        return "\(action.title) — Unavailable (\(availability.reason?.description ?? "unknown reason"))"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
