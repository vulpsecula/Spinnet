import Foundation
import Darwin

/// Converts the complete authenticated disclosure and fixed native graph into
/// Host-owned rows. Every concrete category shares one aggregate bound.
enum HomebrewTaskNativeConfirmation {
    static func details(_ plan: HomebrewTaskPlan, disclosure: HomebrewNativeInspection.Disclosure,
                        cancellation: HostFetchedSections.Cancellation) throws -> HostConfirmationDetails {
        var rows: [HostConfirmationDetails.Row] = []
        var totalBytes = 0
        func add(_ id: String, _ title: String, _ detail: String) throws {
            guard !cancellation.isCancelled else { throw HomebrewNativeInspection.Failure.authorizationCancelled }
            let size = id.utf8.count + title.utf8.count + detail.utf8.count
            guard rows.count < HostConfirmationDetails.maximumRows, size <= HostConfirmationDetails.maximumBytes - totalBytes else {
                throw PluginHostServiceError.tool(.outputTooLarge)
            }
            totalBytes += size
            rows.append(.init(id: id, title: title, detail: detail))
        }
        func scriptText(_ script: HomebrewPrivilegePlan.NativeScript) -> String {
            let args = script.arguments.enumerated().map { "Argument \($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            return "Program: \(script.executable)\nPhase: \(script.phase.rawValue)\n" + args
                + (script.input.map { "\nStandard input:\n" + $0 } ?? "")
                + "\n" + (script.mustSucceed ? "Failure stops this Task." : "A nonzero result may be tolerated by the declared installer.")
        }
        func packageText(_ package: HomebrewPrivilegePlan.PackageInstaller) -> String {
                let choices = (package.choices ?? []).map { "\($0.identifier): \($0.effectiveAttribute.rawValue) = \($0.customLocation ?? ($0.selected ? "yes" : "no"))" }.joined(separator: "\n")
                let toggles = (package.choiceToggles ?? []).joined(separator: ", ")
                return "Package member: \(package.path)\nChoices:\n" + choices + "\nChoice toggles: " + (toggles.isEmpty ? "none" : toggles) + "\n" + (package.allowUntrusted ? "allowUntrusted: Homebrew explicitly allows an untrusted package signature." : "Package signature remains required.")
        }
        for receipt in disclosure.receipts {
            try add("receipt/" + receipt.identifier, "Forget exact receipt after successful removal",
                "\(receipt.identifier)\n\(receipt.fileCount) existing entries." +
                (receipt.fileCount == 0 ? " No payload remains; remove only this receipt's metadata after fresh complete ownership proof." : " Remove only confirmed exclusive entries; keep nonempty directories."))
        }
        for target in disclosure.targets {
            let title: String
            switch target.action {
            case .removeFile: title = "Remove exclusive receipt-owned file"
            case .removeEmptyDirectory: title = "Remove directory only if empty"
            case .handledByDeclaration: title = "Handled by separately reviewed native action"
            case .retainDirectory: title = "Retain nonempty directory"
            }
            try add("receipt-target/" + target.path, title,
                "\(target.path)\nReceipts: \(target.receiptIDs.joined(separator: ", "))\n\(target.size) bytes.")
        }
        let deadline = Date().addingTimeInterval(30)
        func paths(_ grant: HomebrewNativePathGrant, id: String, title: String) throws {
            let manifest = try grant.load(owner: getuid(), deadline: deadline)
            for entry in manifest.entries { try add(id + "/target/" + entry.path, title, "\(entry.path)\nAction: \(entry.operation.rawValue).") }
            for retained in manifest.retainedDirectories { try add(id + "/retain/" + retained.path, "Retain nonempty directory", "\(retained.path)\n\(retained.reason)") }
            for pattern in manifest.unmatchedPatterns { try add(id + "/unmatched/" + pattern, "Expression has no current match", pattern) }
        }
        for (index, cask) in plan.privilegedCasks.enumerated() {
            let base = "cask/\(index)/\(cask.name)"
            try add(base, "Selected package and installed history", "\(cask.name)\nVersion: \(cask.uninstallVersion ?? cask.version)\nInstalled source: \(cask.installedTap ?? "not installed"). Current source and configuration are rechecked before admission.")
            if let proof = cask.sourceProof { try add(base + "/source", "Verified publisher source", "Homebrew's signed cask catalog was verified for \(cask.name). Languages: \(proof.configuration.languages.joined(separator: ", ")).\nApplication directory: \(proof.configuration.appDirectory.path).\nDownload: \(cask.downloadURL ?? "No new download")") }
            if let snapshot = cask.downloadSnapshot { try add(base + "/snapshot", "Exact downloaded snapshot without publisher checksum", "\(snapshot.sourceURL.absoluteString)\n\(snapshot.byteCount) bytes. SHA-256: \(snapshot.sha256). This exact downloaded snapshot is used; no latest-download retry.") }
            for (i, package) in (cask.packageInstallers ?? []).enumerated() {
                try add(base + "/package/\(i)", "Run native package installer with these exact choices", packageText(package))
            }
            if (cask.packageInstallers ?? []).isEmpty {
                for (i, package) in cask.packages.enumerated() { try add(base + "/package/\(i)", "Run native package installer", package) }
            }
            for (i, script) in (cask.nativeScripts ?? []).enumerated() { try add(base + "/script/\(i)", "Execute reviewed vendor script", scriptText(script)) }
            for (i, generated) in (cask.generatedResources ?? []).enumerated() { try add(base + "/generated/\(i)", "Stage reviewed generated resource", "\(generated.path)\n\(generated.content.utf8.count) bytes of reviewed generated content:\n\(generated.content)") }
            for (i, daemon) in (cask.launchDaemons ?? []).enumerated() { try add(base + "/daemon/\(i)", "Remove exact system launch daemon", "Label: \(daemon.label)\nStop the exact system service and remove \(daemon.path).") }
            for action in cask.pathRemovals ?? [] {
                try paths(action.grant, id: base + "/" + action.phase.rawValue,
                    title: action.phase.rawValue.hasSuffix("Rmdir") ? "Remove only if empty" : "Remove related path; shared data may be deleted")
            }
            if let code = cask.removalCode {
                try add(base + "/removal-source", "Verified immutable removal source", code.confirmationDetails)
                for (i, action) in code.actions.enumerated() {
                    try add(base + "/removal/\(i)", "Execute reviewed removal action", scriptText(action.script) + (action.package.map { "\n" + packageText($0) } ?? ""))
                }
            }
            if let kernel = cask.kernelExtensionRemoval {
                try add(base + "/kernel", "Remove reviewed kernel extensions; restart or manual approval may be required", kernel.confirmationDetails)
                if let grant = kernel.paths { try paths(grant, id: base + "/kernel", title: "Remove reviewed kernel-extension path") }
            }
            for grant in cask.launchServiceRemovals ?? [] {
                let manifest = try grant.load(owner: getuid(), deadline: deadline)
                let key = base + "/launch/" + grant.phase.rawValue
                for (i, entry) in manifest.entries.enumerated() {
                    let files = entry.plists.map { "\($0.removeFile ? "Remove" : "Retain") \($0.path.path)\nProgram: \($0.program)" }.joined(separator: "\n")
                    try add(key + "/entry/\(i)", "Remove reviewed launch service and its selected files", "Label: \(entry.label)\nDomain: \(entry.domain.target)\n" + files + "\nRetain domains: " + entry.retainedDomains.map(\.target).joined(separator: ", "))
                }
                for (i, unmatched) in manifest.unmatched.enumerated() { try add(key + "/unmatched/\(i)", "Launch-service expression has no match", "\(unmatched.pattern)") }
            }
            for (i, installer) in (cask.manualInstallers ?? []).enumerated() { try add(base + "/manual/\(i)", "Open native installer for manual completion", installer + "\nOpening is not verified installation; the Task reports manual completion required.") }
        }
        if case .array(let paths)? = plan.package.value(atPointer: "/repair_directories") {
            for (index, path) in paths.enumerated() {
                guard case .string(let text) = path else { throw PluginHostServiceError.tool(.planChanged) }
                try add("repair/\(index)", "Restore reviewed Homebrew directory ownership", text + "\nRestore this reviewed directory's root-owned entries to the requesting account; permissions are not changed.")
            }
        }
        return try HostConfirmationDetails(title: "Complete Native Changes", summary: "\(disclosure.receipts.count) receipts; \(disclosure.targets.count) receipt-owned targets; \(disclosure.targetBytes) bytes. Every retained path and other selected native action is listed. Cancellation before admission changes no installed package; stopping admitted work never rolls back changes.", rows: rows)
    }
}
