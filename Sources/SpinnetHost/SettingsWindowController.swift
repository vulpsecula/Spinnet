import AppKit
import SpinnetCore

final class SettingsWindowController: NSWindowController {
    private let editor: HostConfigurationEditor

    private let commandTable = NSTableView()
    private let actionTable = NSTableView()
    private let inputLabel = NSTextField(labelWithString: "Configuration input")
    private let inputField = NSTextField()
    private let menuItemPicker = NSPopUpButton()
    private let primaryActionPicker = NSPopUpButton()
    private let alternateActionStack = NSStackView()
    private var alternateActionButtons: [NSButton] = []

    private var createActionButton: NSButton!
    private var updateActionButton: NSButton!
    private var removeActionButton: NSButton!
    private var applyBindingButton: NSButton!
    private var addMenuItemButton: NSButton!
    private var removeMenuItemButton: NSButton!
    private var isRefreshing = false

    init(editor: HostConfigurationEditor) {
        self.editor = editor
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "Spinnet Settings"
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()
        window.initialFirstResponder = commandTable
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is not decoded from a nib")
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeContentView() -> NSView {
        configureTable(commandTable, accessibilityLabel: "Available Plugin Commands")
        configureTable(actionTable, accessibilityLabel: "Configured Actions")

        inputField.placeholderString = "Text or JSON value"
        inputField.setAccessibilityLabel("Action configuration input")
        inputLabel.setAccessibilityLabel("Action configuration input label")

        menuItemPicker.setAccessibilityLabel("Menu Item")
        menuItemPicker.target = self
        menuItemPicker.action = #selector(menuItemChanged(_:))
        primaryActionPicker.setAccessibilityLabel("Primary Action")
        primaryActionPicker.target = self
        primaryActionPicker.action = #selector(primaryActionChanged(_:))

        alternateActionStack.orientation = .vertical
        alternateActionStack.alignment = .leading
        alternateActionStack.spacing = 4
        alternateActionStack.setAccessibilityLabel("Alternate Actions")

        createActionButton = NSButton(
            title: "Create Action",
            target: self,
            action: #selector(createAction(_:))
        )
        updateActionButton = NSButton(
            title: "Save Action Changes",
            target: self,
            action: #selector(updateAction(_:))
        )
        removeActionButton = NSButton(
            title: "Remove Action",
            target: self,
            action: #selector(removeAction(_:))
        )
        applyBindingButton = NSButton(
            title: "Save Menu Binding",
            target: self,
            action: #selector(applyBinding(_:))
        )
        addMenuItemButton = NSButton(
            title: "Add Menu Item",
            target: self,
            action: #selector(addMenuItem(_:))
        )
        removeMenuItemButton = NSButton(
            title: "Remove Menu Item",
            target: self,
            action: #selector(removeMenuItem(_:))
        )
        for button in [
            createActionButton,
            updateActionButton,
            removeActionButton,
            applyBindingButton,
            addMenuItemButton,
            removeMenuItemButton
        ] as [NSButton] {
            button.setAccessibilityRole(.button)
        }
        applyBindingButton.keyEquivalent = "\r"

        let commandsSection = NSStackView(views: [
            sectionLabel("Available Plugin Commands"),
            tableScrollView(for: commandTable, height: 110)
        ])
        commandsSection.orientation = .vertical
        commandsSection.alignment = .leading
        commandsSection.spacing = 8

        let actionButtons = NSStackView(views: [
            createActionButton,
            updateActionButton,
            removeActionButton
        ])
        actionButtons.orientation = .horizontal
        actionButtons.spacing = 8

        let actionsSection = NSStackView(views: [
            sectionLabel("Configured Actions"),
            tableScrollView(for: actionTable, height: 130),
            inputLabel,
            inputField,
            actionButtons
        ])
        actionsSection.orientation = .vertical
        actionsSection.alignment = .leading
        actionsSection.spacing = 8

        let menuItemButtons = NSStackView(views: [
            addMenuItemButton,
            removeMenuItemButton
        ])
        menuItemButtons.orientation = .horizontal
        menuItemButtons.spacing = 8

        let menuSection = NSStackView(views: [
            sectionLabel("Menu Item Bindings"),
            menuItemPicker,
            primaryActionPicker,
            alternateActionStack,
            applyBindingButton,
            menuItemButtons
        ])
        menuSection.orientation = .vertical
        menuSection.alignment = .leading
        menuSection.spacing = 8

        let root = NSStackView(views: [commandsSection, actionsSection, menuSection])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            root.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
            inputField.widthAnchor.constraint(equalToConstant: 480),
            menuItemPicker.widthAnchor.constraint(equalToConstant: 260),
            primaryActionPicker.widthAnchor.constraint(equalToConstant: 420)
        ])
        return container
    }

    private func configureTable(_ table: NSTableView, accessibilityLabel: String) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.title = accessibilityLabel
        column.width = 620
        table.addTableColumn(column)
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 28
        table.headerView = NSTableHeaderView()
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel(accessibilityLabel)
    }

    private func tableScrollView(for table: NSTableView, height: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: height).isActive = true
        scrollView.widthAnchor.constraint(equalToConstant: 640).isActive = true
        return scrollView
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func reload() {
        let selectedActionID = selectedAction?.id
        let selectedMenuIndex = max(menuItemPicker.indexOfSelectedItem, 0)
        isRefreshing = true
        commandTable.reloadData()
        actionTable.reloadData()
        reloadMenuPickers(selectedIndex: selectedMenuIndex)
        isRefreshing = false

        if let selectedActionID,
           let index = editor.configuration.actions.firstIndex(where: { $0.id == selectedActionID }) {
            actionTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            populateFields(for: editor.configuration.actions[index])
        } else if !editor.configuration.actions.isEmpty {
            actionTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            populateFields(for: editor.configuration.actions[0])
        } else if !editor.availableCommands.isEmpty {
            commandTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            inputLabel.stringValue = "Configuration input for \(editor.availableCommands[0].title)"
            inputField.stringValue = ""
        }
        reloadAlternateActionControls()
    }

    private func reloadMenuPickers(selectedIndex: Int) {
        menuItemPicker.removeAllItems()
        for index in editor.configuration.menu.items.indices {
            menuItemPicker.addItem(withTitle: "Menu Item \(index + 1)")
        }
        guard !editor.configuration.menu.items.isEmpty else { return }
        menuItemPicker.selectItem(at: min(selectedIndex, editor.configuration.menu.items.count - 1))

        primaryActionPicker.removeAllItems()
        for action in editor.configuration.actions {
            primaryActionPicker.addItem(withTitle: actionTitle(for: action))
            primaryActionPicker.lastItem?.representedObject = action.id.rawValue
        }

        let menuItem = editor.configuration.menu.items[menuItemPicker.indexOfSelectedItem]
        if let primaryIndex = primaryActionPicker.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == menuItem.primaryActionID.rawValue
        }) {
            primaryActionPicker.selectItem(at: primaryIndex)
        }
    }

    private func reloadAlternateActionControls() {
        for button in alternateActionButtons {
            alternateActionStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        alternateActionButtons = []

        guard editor.configuration.menu.items.indices.contains(menuItemPicker.indexOfSelectedItem) else {
            return
        }
        let menuItem = editor.configuration.menu.items[menuItemPicker.indexOfSelectedItem]
        let primaryID = menuItem.primaryActionID
        for action in editor.configuration.actions where action.id != primaryID {
            let button = NSButton(
                checkboxWithTitle: actionTitle(for: action),
                target: nil,
                action: nil
            )
            button.identifier = NSUserInterfaceItemIdentifier(action.id.rawValue)
            button.setAccessibilityLabel("Alternate Action \(action.title)")
            button.toolTip = actionAvailabilityDescription(for: action)
            button.state = menuItem.alternateActionIDs.contains(action.id) ? .on : .off
            alternateActionButtons.append(button)
            alternateActionStack.addArrangedSubview(button)
        }
        if alternateActionButtons.isEmpty {
            let label = NSTextField(labelWithString: "Create another Action to add an Alternate Action.")
            label.textColor = .secondaryLabelColor
            label.setAccessibilityRole(.staticText)
            alternateActionStack.addArrangedSubview(label)
        }
    }

    private var selectedAction: ActionConfiguration? {
        guard actionTable.selectedRow >= 0,
              editor.configuration.actions.indices.contains(actionTable.selectedRow) else {
            return nil
        }
        return editor.configuration.actions[actionTable.selectedRow]
    }

    private var selectedCommand: AvailableCommand? {
        guard commandTable.selectedRow >= 0,
              editor.availableCommands.indices.contains(commandTable.selectedRow) else {
            return nil
        }
        return editor.availableCommands[commandTable.selectedRow]
    }

    private func populateFields(for action: ActionConfiguration) {
        isRefreshing = true
        if let commandIndex = editor.availableCommands.firstIndex(where: {
            $0.pluginID == action.pluginID && $0.commandID == action.commandID
        }) {
            commandTable.selectRowIndexes(IndexSet(integer: commandIndex), byExtendingSelection: false)
            inputLabel.stringValue = "Configuration input for \(action.title)"
        } else {
            commandTable.deselectAll(nil)
            inputLabel.stringValue = "Configuration input (Command unavailable)"
        }
        inputField.stringValue = displayValue(for: action.input)
        isRefreshing = false
    }

    private func inputValue() -> JSONValue {
        let text = inputField.stringValue
        if let data = text.data(using: .utf8),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return value
        }
        return .string(text)
    }

    private func displayValue(for value: JSONValue) -> String {
        if case .string(let value) = value { return value }
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func actionTitle(for action: ActionConfiguration) -> String {
        guard let availability = editor.availability(for: action.id), !availability.isAvailable else {
            return action.title
        }
        return "\(action.title) — Unavailable (\(availability.reason?.description ?? "unknown reason"))"
    }

    private func actionAvailabilityDescription(for action: ActionConfiguration) -> String {
        guard let availability = editor.availability(for: action.id), !availability.isAvailable else {
            return "Available"
        }
        return availability.reason?.description ?? "Command is unavailable"
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Spinnet Settings"
        alert.informativeText = error.localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func changed() {
        onConfigurationChanged?(editor.configuration)
        reload()
    }

    var onConfigurationChanged: ((HostConfiguration) -> Void)?

    @objc private func commandSelectionChanged(_ sender: Any?) {
        guard !isRefreshing, let command = selectedCommand else { return }
        inputLabel.stringValue = "Configuration input for \(command.title)"
    }

    @objc private func actionSelectionChanged(_ sender: Any?) {
        guard !isRefreshing, let action = selectedAction else { return }
        populateFields(for: action)
        reloadAlternateActionControls()
    }

    @objc private func menuItemChanged(_ sender: Any?) {
        guard !isRefreshing else { return }
        reloadAlternateActionControls()
    }

    @objc private func primaryActionChanged(_ sender: Any?) {
        guard !isRefreshing else { return }
        reloadAlternateActionControls()
    }

    @objc private func createAction(_ sender: Any?) {
        guard let command = selectedCommand else {
            report(ConfigurationError.invalidAction("Select an available Command first"))
            return
        }
        do {
            _ = try editor.createAction(
                pluginID: command.pluginID,
                commandID: command.commandID,
                input: inputValue()
            )
            changed()
        } catch {
            report(error)
        }
    }

    @objc private func updateAction(_ sender: Any?) {
        guard let action = selectedAction else {
            report(ConfigurationError.invalidAction("Select an Action first"))
            return
        }
        guard let command = selectedCommand else {
            report(ConfigurationError.invalidAction("Select an available replacement Command"))
            return
        }
        do {
            _ = try editor.updateAction(
                id: action.id,
                pluginID: command.pluginID,
                commandID: command.commandID,
                input: inputValue()
            )
            changed()
        } catch {
            report(error)
        }
    }

    @objc private func removeAction(_ sender: Any?) {
        guard let action = selectedAction else {
            report(ConfigurationError.invalidAction("Select an Action first"))
            return
        }
        do {
            try editor.removeAction(action.id)
            changed()
        } catch {
            report(error)
        }
    }

    @objc private func applyBinding(_ sender: Any?) {
        guard editor.configuration.menu.items.indices.contains(menuItemPicker.indexOfSelectedItem),
              let rawPrimaryID = primaryActionPicker.selectedItem?.representedObject as? String else {
            report(ConfigurationError.invalidMenu("Select a Primary Action first"))
            return
        }
        let alternateIDs = alternateActionButtons
            .filter { $0.state == .on }
            .map { ActionID($0.identifier?.rawValue ?? "") }
        do {
            try editor.updateMenuItem(
                at: menuItemPicker.indexOfSelectedItem,
                primaryActionID: ActionID(rawPrimaryID),
                alternateActionIDs: alternateIDs
            )
            changed()
        } catch {
            report(error)
        }
    }

    @objc private func addMenuItem(_ sender: Any?) {
        let boundIDs = Set(editor.configuration.menu.items.flatMap {
            [$0.primaryActionID] + $0.alternateActionIDs
        })
        guard let action = editor.configuration.actions.first(where: { !boundIDs.contains($0.id) }) else {
            report(ConfigurationError.invalidMenu("Create an unbound Action before adding a Menu Item"))
            return
        }
        do {
            try editor.addMenuItem(primaryActionID: action.id)
            changed()
        } catch {
            report(error)
        }
    }

    @objc private func removeMenuItem(_ sender: Any?) {
        do {
            try editor.removeMenuItem(at: menuItemPicker.indexOfSelectedItem)
            changed()
        } catch {
            report(error)
        }
    }
}

extension SettingsWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === commandTable { return editor.availableCommands.count }
        return editor.configuration.actions.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("value")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        let text: String
        let label: String
        if tableView === commandTable {
            let command = editor.availableCommands[row]
            text = "\(command.pluginName) — \(command.title) (\(command.commandID.rawValue))"
            label = "\(command.pluginName), \(command.title), Command \(command.commandID.rawValue)"
        } else {
            let action = editor.configuration.actions[row]
            text = actionTitle(for: action)
            label = "Action \(action.title), \(actionAvailabilityDescription(for: action))"
        }
        cell.textField?.stringValue = text
        cell.textField?.setAccessibilityLabel(label)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView === commandTable {
            commandSelectionChanged(tableView)
        } else if tableView === actionTable {
            actionSelectionChanged(tableView)
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
