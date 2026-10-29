import SpinnetCore
import Foundation

/// Converts frozen native CLI package targets into Host-owned review rows.
/// Every target shares one aggregate bound.
enum HomebrewTaskNativeConfirmation {
    /// The same frozen inputs drive execution, summary and paged target rows.
    /// Batch steps take precedence; a selected batch uses resolvedInput.names.
    static func selectedPackages(_ plan: HomebrewTaskPlan) throws -> [(kind: String, name: String)] {
        if plan.input.operation == "autoremove", case .array(let packages)? = plan.package.value(atPointer: "/packages") {
            return try packages.map { record in
                guard record.value(atPointer: "/kind") == .string("formula"), case .string(let name)? = record.value(atPointer: "/name"), HomebrewTaskInput.validPackageName(name) else { throw PluginHostServiceError.tool(.planChanged) }
                return ("formula", name)
            }
        }
        var targets: [(kind: String, name: String)] = []
        for input in plan.steps.isEmpty ? [plan.resolvedInput] : plan.steps {
            guard ["formula", "cask"].contains(input.kind) else { continue }
            if case .array(let names)? = input.fields["names"] {
                for name in names {
                    guard case .string(let value) = name, HomebrewTaskInput.validPackageName(value) else { throw PluginHostServiceError.tool(.planChanged) }
                    targets.append((input.kind, value))
                }
            } else if HomebrewTaskInput.validPackageName(input.name) { targets.append((input.kind, input.name)) }
        }
        return targets
    }

    static func details(_ plan: HomebrewTaskPlan,
                        cancellation: HostFetchedSections.Cancellation) throws -> HostConfirmationDetails {
        if plan.input.operation == "autoremove" {
            let targets = try selectedPackages(plan)
            let rows = targets.map { target in
                HostConfirmationDetails.Row(id: "autoremove/" + target.name, title: HostText("Remove %@", .verbatim(target.name)),
                    detail: [HostText("Installed formula dependency that Homebrew considers unused. No cask App is removed.")])
            }
            return try HostConfirmationDetails(title: HostText("Remove Unused Dependencies"),
                summary: [HostText("%@ installed formula dependencies will be uninstalled. Every candidate is listed below. Stopping does not undo removals.", .verbatim(String(targets.count)))], rows: rows)
        }
        var rows: [HostConfirmationDetails.Row] = []
        var totalBytes = 0
        func add(_ id: String, _ title: HostText, _ detail: [HostText], presentation: HostConfirmationDetails.Row.Presentation = .action) throws {
            guard !cancellation.isCancelled else { throw HomebrewNativeInspection.Failure.authorizationCancelled }
            let row = HostConfirmationDetails.Row(id: id, title: title, detail: detail, presentation: presentation)
            let size = id.utf8.count + row.title.utf8.count + row.detail.utf8.count
            guard rows.count < HostConfirmationDetails.maximumRows, size <= HostConfirmationDetails.maximumBytes - totalBytes else {
                throw PluginHostServiceError.tool(.outputTooLarge)
            }
            totalBytes += size
            rows.append(row)
        }
        let metadata: [JSONValue] = { if case .array(let values)? = plan.package.value(atPointer: "/packages") { return values }; return [plan.package] }()
        let selectedPackages = try selectedPackages(plan)
        let operation = ["upgrade", "upgradeAll", "upgradeSelected"].contains(plan.input.operation) ? "Upgrade" : plan.input.displayOperation
        // The Host shows these words in the interface language; versions,
        // sources, dependencies and warnings stay as Homebrew reports them.
        for target in selectedPackages {
            let record = metadata.first { $0.value(atPointer: "/name") == .string(target.name) && $0.value(atPointer: "/kind") == .string(target.kind) }
            func value(_ field: String) -> String? { if case .string(let text)? = record?.value(atPointer: "/" + field) { return text }; return nil }
            let from = value("installed_version").map(HostText.verbatim) ?? HostText("not installed")
            let to = value("version").map(HostText.verbatim) ?? HostText("unknown")
            var description = [HostText("%@ → %@ · %@", from, to, .verbatim(target.kind)),
                               HostText("Source: %@", value("tap").map(HostText.verbatim) ?? HostText("unknown"))]
            if case .array(let dependencies)? = record?.value(atPointer: "/dependencies"), !dependencies.isEmpty {
                description.append(HostText("Declared dependencies: %@", .verbatim(dependencies.compactMap { if case .string(let text) = $0 { return text }; return nil }.joined(separator: ", "))))
            }
            if case .array(let warnings)? = record?.value(atPointer: "/warnings"), !warnings.isEmpty {
                description.append(HostText("Warnings:"))
                description.append(.verbatim(warnings.compactMap { if case .string(let text) = $0 { return text }; return nil }.joined(separator: "\n")))
            }
            try add("package-target/" + target.kind + "/" + target.name,
                    HostText("%@ %@", HostText(key: operation, arguments: []), .verbatim(target.name)), description)
        }
        if case .array(let paths)? = plan.package.value(atPointer: "/repair_directories") {
            for (index, path) in paths.enumerated() {
                guard case .string(let text) = path else { throw PluginHostServiceError.tool(.planChanged) }
                try add("repair/\(index)", HostText("Restore reviewed Homebrew directory ownership"),
                        [.verbatim(text), HostText("Restore this reviewed directory's root-owned entries to the requesting account; permissions are not changed.")])
            }
        }
        return try HostConfirmationDetails(title: HostText("Packages and Changes"), summary: [HostText("Review the selected packages and any additional changes below.")], rows: rows)
    }
}
