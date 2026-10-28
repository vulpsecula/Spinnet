#if DEBUG
import Foundation
import SpinnetCore

/// Installs local Plugin packages into a development Host's saved data, for
/// the launcher's `--install-plugins`. Each package goes through the same
/// install-and-update path the Library takes, so an official Plugin from a
/// SpinnetPlugins checkout is installed exactly as a user would install it:
/// an update keeps Plugin Storage and Capability decisions, a new Plugin
/// starts empty, and nothing is granted. The launcher installs only after it
/// has quit any running Host, since a running Host would not see the change.
/// The report of installed Plugins also runs beside a running Host: it reads
/// the Plugins as saved on disk, not what that Host has registered.
struct DevelopmentPluginInstall {
    struct Report: Equatable {
        var lines: [String] = []
        var failed = false
    }

    let dataDirectory: URL
    let defaults: UserDefaults

    /// Installs or updates every `.spinnetplugin` package in `directory`, or
    /// in its `Plugins` folder when it is a checkout of Plugins. A package
    /// that cannot be installed is reported and the rest still install.
    func installPackages(in directory: URL) throws -> Report {
        let packages = try Self.packages(in: directory)
        let (registry, store) = try restore()
        var report = Report()
        for package in packages {
            do {
                let review = try store.review(package)
                let previous = registry.package(for: review.manifest.id)?.manifest.version
                let manifest = try store.install(from: package)
                var line: String
                switch previous {
                case nil: line = "installed \(manifest.id.rawValue) \(manifest.version)"
                case manifest.version?: line = "reinstalled \(manifest.id.rawValue) \(manifest.version)"
                case let previous?: line = "updated \(manifest.id.rawValue) \(previous) -> \(manifest.version)"
                }
                if !review.requestedAccess.isEmpty {
                    line += ", asks for " + review.requestedAccess.map(\.rawValue).sorted().joined(separator: ", ")
                }
                report.lines.append(line)
            } catch {
                report.failed = true
                report.lines.append("refused \(package.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return report
    }

    /// The Plugins a launch would register from the saved data, with their
    /// versions, and any it would refuse.
    func installedPlugins() throws -> Report {
        let (registry, _) = try restore()
        var report = Report()
        report.lines = registry.manifests().sorted { $0.id.rawValue < $1.id.rawValue }
            .map { "\($0.id.rawValue) \($0.version) \($0.name)" }
        for refused in registry.refusedPlugins().sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            report.failed = true
            report.lines.append("refused \(refused.id.rawValue): \(refused.reason)")
        }
        return report
    }

    private func restore() throws -> (PluginRegistry, PluginInstallationStore) {
        let files = HostPluginFiles(dataDirectory: dataDirectory)
        let grants = PluginCapabilityGrantStore()
        try files.restoreCapabilityGrants(into: grants)
        let registry = PluginRegistry(grantStore: grants)
        let pins = PluginViewPins(defaults: defaults)
        let store = files.installationStore(registry: registry, grants: grants,
                                            forgetHostPreferences: { pins.forget($0) })
        try store.restore()
        return (registry, store)
    }

    private static func packages(in directory: URL) throws -> [URL] {
        func list(_ directory: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "spinnetplugin" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let direct = list(directory)
        let packages = direct.isEmpty ? list(directory.appendingPathComponent("Plugins", isDirectory: true)) : direct
        guard !packages.isEmpty else {
            throw HostCommandError.failed("No Plugin packages found in \(directory.path)")
        }
        return packages
    }

    /// Runs the launcher's development commands when the arguments ask for
    /// one, and returns the exit status; nil when they ask for none.
    static func runIfRequested(arguments: [String], dataDirectory: URL, defaults: UserDefaults = .standard) -> Int32? {
        let install = DevelopmentPluginInstall(dataDirectory: dataDirectory, defaults: defaults)
        do {
            let report: Report
            if let index = arguments.firstIndex(of: "--install-plugins") {
                guard index + 1 < arguments.count else {
                    FileHandle.standardError.write(Data("--install-plugins needs a directory\n".utf8))
                    return 64
                }
                report = try install.installPackages(in: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            } else if arguments.contains("--report-installed-plugins") {
                report = try install.installedPlugins()
            } else {
                return nil
            }
            print(report.lines.joined(separator: "\n"))
            return report.failed ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
}
#endif
