import SpinnetCore
import Foundation
import Darwin

extension HomebrewPrivilegePlan {
    public struct SourceProof: Codable, Equatable {
        public let envelope: URL
        public let envelopeSHA256: String
        public let projectionSHA256: String
        public let configuration: HomebrewSignedCaskCatalog.Configuration
        public init(envelope: URL, envelopeSHA256: String, projectionSHA256: String, configuration: HomebrewSignedCaskCatalog.Configuration) {
            self.envelope = envelope; self.envelopeSHA256 = envelopeSHA256
            self.projectionSHA256 = projectionSHA256; self.configuration = configuration
        }
        public var valid: Bool {
            envelope.isFileURL && envelope.path.hasPrefix("/") && envelope.path.utf8.count <= 2048
                && envelope.lastPathComponent == "homebrew-source.jws.json" && envelope.query == nil && envelope.fragment == nil
                && envelope.path == envelope.standardizedFileURL.path
                && HomebrewPrivilegePlan.validDigest(envelopeSHA256) && HomebrewPrivilegePlan.validDigest(projectionSHA256)
        }
        /// Root obtains signed publisher bytes independently; the path and
        /// local checksum never substitute for the catalog's RSA signature.
        public func verifiedProjection(name: String, prefix: String, owner: uid_t, deadline: Date,
                                       evidence: HomebrewSignedCaskCatalog.Evidence? = nil) throws -> [String: JSONValue] {
            var account = passwd(), result: UnsafeMutablePointer<passwd>?, buffer = [CChar](repeating: 0, count: 16 * 1024)
            let home: String? = buffer.withUnsafeMutableBufferPointer { bytes in
                guard getpwuid_r(owner, &account, bytes.baseAddress!, bytes.count, &result) == 0, result != nil, let path = account.pw_dir else { return nil }
                return String(validatingUTF8: path)
            }
            guard valid, configuration.prefix.path == prefix, configuration.home.path == home else { throw PluginHostServiceError.tool(.planChanged) }
            let held = try evidence ?? HomebrewSignedCaskCatalog.load(envelope, deadline: deadline)
            guard held.catalog.envelopeSHA256 == envelopeSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            let token = String(name.split(separator: "/").last!)
            guard try held.catalog.projectionDigest(token, configuration: configuration) == projectionSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            return try held.catalog.project(token, configuration: configuration)
        }
    }

}

extension HomebrewPrivilegePlan.Cask {
    public var requiresSystemAuthorization: Bool {
        !(launchServiceRemovals ?? []).isEmpty || kernelExtensionRemoval != nil || removalCode != nil || !packages.isEmpty || !(pathRemovals ?? []).isEmpty || !(nativeScripts ?? []).isEmpty || !(launchDaemons ?? []).isEmpty || !(receipts ?? []).isEmpty
    }
    public var validDownloadSnapshot: Bool {
        guard let frozen = downloadSnapshot, let proof = sourceProof else { return false }
        return frozen.fileURL.isFileURL && frozen.fileURL.path == frozen.fileURL.standardizedFileURL.path && frozen.fileURL.path.utf8.count <= 2048
            && frozen.fileURL.lastPathComponent.hasPrefix("no-check-") && frozen.fileURL.pathExtension == "archive"
            && frozen.sourceURL.absoluteString == downloadURL && frozen.sha256 == sha256 && HomebrewPrivilegePlan.validDigest(frozen.sha256)
            && frozen.sourceSHA256 == proof.envelopeSHA256 && frozen.projectionSHA256 == proof.projectionSHA256
            && HomebrewPrivilegePlan.validDigest(frozen.configurationSHA256) && (1...HomebrewNoCheckSnapshot.maximumBytes).contains(frozen.byteCount)
    }
    public func nativeContainerKind(fallback: URL) -> String {
        let suffix = downloadURL.flatMap(URL.init(string:))?.pathExtension.lowercased() ?? fallback.pathExtension.lowercased()
        return ["pkg", "mpkg"].contains(suffix) ? "pkg" : suffix == "dmg" ? "dmg" : "archive"
    }
    public var confirmationDetails: String {
        var parts: [String] = []
        if let removalCode { parts.append(removalCode.confirmationDetails) }
        if let kernelExtensionRemoval { parts.append(kernelExtensionRemoval.confirmationDetails) }
        parts += (launchServiceRemovals ?? []).map(\.confirmationDetails)
        if !(receipts ?? []).isEmpty {
            parts.append("Inspect all installed receipt IDs and their bounded ownership/path metadata to prove selected-package exclusivity; unselected ownership data remains Host-private.")
            for receipt in receipts ?? [] {
                parts.append("Receipt \(receipt.identifier): \(receipt.fileCount) frozen existing entries. " + (receipt.fileCount == 0 ? "No payload file remains; only this exact receipt metadata is forgotten after complete live ownership proof." : "Remove only its confirmed exclusive entries, then forget this exact receipt; nonempty directories remain."))
            }
        }
        if let proof = sourceProof {
            parts.append("Official publisher signature verified for \(name); effective language/configuration and source \(proof.envelopeSHA256.prefix(12)) are frozen.")
        }
        if let snapshot = downloadSnapshot { parts.append("No publisher checksum: Host downloaded and froze \(snapshot.byteCount) bytes from \(snapshot.sourceURL.absoluteString), SHA-256 \(snapshot.sha256). This exact snapshot is used; no latest-download retry.") }
        for package in packageInstallers ?? [] {
            parts.append("Install \(package.path)" + (package.allowUntrusted ? " with allowUntrusted explicitly enabled." : "."))
            if let choices = package.choices, !choices.isEmpty { parts.append("Choices: " + choices.map { "\($0.identifier).\($0.effectiveAttribute.rawValue)=\($0.customLocation ?? String($0.selected ? 1 : 0))" }.joined(separator: ", ") + ".") }
        }
        for action in pathRemovals ?? [] {
            let grant = action.grant
            parts.append("\(action.phase.rawValue): " + grant.directives.flatMap(\.patterns).joined(separator: ", ") + ". Frozen \(grant.concreteCount) entries, \(grant.regularFileBytes) bytes; \(grant.retainedCount) nonempty directories retained, \(grant.unmatchedCount) unmatched expressions. Related or shared settings may be deleted; data paths do not imply exclusive receipt ownership.")
        }
        if !(generatedResources ?? []).isEmpty { parts.append("Stage immutable generated files: " + (generatedResources ?? []).map(\.path).joined(separator: ", ") + ".") }
        for script in nativeScripts ?? [] {
            let arguments = script.arguments.map { String($0.prefix(200)).replacingOccurrences(of: "\n", with: "\\n") }.joined(separator: " ")
            parts.append("Run immutable \(script.generatedContent == nil ? "vendor" : "generated") code as administrator: \(script.executable) \(arguments). Input: \(script.input?.utf8.count ?? 0) bytes. \(script.mustSucceed ? "Failure stops this Task." : "Its verified metadata allows optional failure.")")
        }
        if HomebrewNativeCompletionPolicy.hasManualOutcome(self), (manualInstallers ?? []).isEmpty {
            parts.append("This reviewed installer checks prerequisites. If they require manual action, the Task reports installation incomplete instead of success.")
        }
        for path in manualInstallers ?? [] { parts.append("Manual installer \(path) requires your actions. The Task will report that installation remains incomplete; launching it is not completion.") }
        return parts.joined(separator: " ")
    }
    @discardableResult
    public func validatePublisherSource(prefix: String, owner: uid_t, deadline: Date,
                                        evidence: HomebrewSignedCaskCatalog.Evidence? = nil) throws -> [String: JSONValue] {
        guard let sourceProof else { throw PluginHostServiceError.unavailable("Independent publisher source evidence is missing for native code") }
        let metadata = try sourceProof.verifiedProjection(name: name, prefix: prefix, owner: owner, deadline: deadline, evidence: evidence)
        guard metadata["version"] == .string(version), metadata["url"] == downloadURL.map(JSONValue.string),
              metadata["sha256"] == .string(downloadSnapshot == nil ? sha256 : "no_check"), downloadSnapshot == nil || validDownloadSnapshot else { throw PluginHostServiceError.tool(.planChanged) }
        let selected = try HomebrewNativeArtifacts.select(metadata, prefix: prefix, token: String(name.split(separator: "/").last!), version: version)
        guard selected.packages.map(\.path) == packages, selected.packages == packageInstallers ?? [],
              selected.scripts == (nativeScripts ?? []).filter({ $0.phase == .install }),
              selected.generatedResources == (generatedResources ?? []),
              selected.manualInstallers == manualInstallers ?? [] else { throw PluginHostServiceError.tool(.planChanged) }
        return metadata
    }
}

/// Projects only concrete native code classes after the independent source
/// verifier has selected the effective language/configuration.
public enum HomebrewNativeArtifacts {
    public struct Selection {
        public let packages: [HomebrewPrivilegePlan.PackageInstaller]
        public let scripts: [HomebrewPrivilegePlan.NativeScript]
        public let manualInstallers: [String]
        public let generatedResources: [HomebrewNativeGeneratedResources.Resource]
    }
    public static func select(_ metadata: [String: JSONValue], prefix: String, token: String, version: String) throws -> Selection {
        guard case .array(let artifacts)? = metadata["artifacts"], artifacts.count <= 128 else { throw PluginHostServiceError.tool(.planChanged) }
        var generated: [String: String] = [:]
        for item in artifacts {
            guard case .array(let args)? = item.value(atPointer: "/generated_script") else { continue }
            guard args.count == 2, case .string(let path) = args[0], case .object(let options) = args[1],
                  Set(options.keys) == ["content"], case .string(let body)? = options["content"], generated[path] == nil, HomebrewNativeGeneratedResources.Resource(path: path, content: body).valid else { throw PluginHostServiceError.tool(.planChanged) }
            generated[path] = body
        }
        var packages: [HomebrewPrivilegePlan.PackageInstaller] = [], scripts: [HomebrewPrivilegePlan.NativeScript] = [], manual: [String] = []
        for item in artifacts {
            if case .array(let args)? = item.value(atPointer: "/pkg") {
                guard (1...2).contains(args.count), case .string(let path) = args[0] else { throw PluginHostServiceError.tool(.planChanged) }
                let options: [String: JSONValue]
                if args.count == 2 { guard case .object(let value) = args[1] else { throw PluginHostServiceError.tool(.planChanged) }; options = value } else { options = [:] }
                guard Set(options.keys).isSubset(of: ["choices", "allow_untrusted"]), options["allow_untrusted"] == nil || options["allow_untrusted"] == .bool(true) || options["allow_untrusted"] == .bool(false) else { throw PluginHostServiceError.unavailable("This native package option requires review") }
                let choices: [HomebrewPrivilegePlan.PackageInstaller.Choice]?
                let toggles: [String]?
                if let raw = options["choices"] {
                    guard case .array(let values) = raw, values.count <= 128 else { throw PluginHostServiceError.unavailable("This native package choice format requires review") }
                    if !values.isEmpty && values.allSatisfy({ if case .string = $0 { return true }; return false }) {
                        choices = nil; toggles = values.compactMap { if case .string(let text) = $0 { return text }; return nil }
                    } else {
                        toggles = nil
                        choices = try values.map { value in
                            guard case .object(let choice) = value, Set(choice.keys) == ["choiceIdentifier", "choiceAttribute", "attributeSetting"],
                                  case .string(let identifier)? = choice["choiceIdentifier"], case .string(let rawAttribute)? = choice["choiceAttribute"],
                                  let attribute = HomebrewPrivilegePlan.PackageInstaller.Choice.Attribute(rawValue: rawAttribute) else { throw PluginHostServiceError.unavailable("This native package choice format requires review") }
                            if attribute == .customLocation {
                                guard case .string(let location)? = choice["attributeSetting"] else { throw PluginHostServiceError.tool(.planChanged) }
                                return .init(identifier: identifier, customLocation: location)
                            }
                            guard [.number(0), .number(1), .bool(false), .bool(true)].contains(choice["attributeSetting"] ?? .null) else { throw PluginHostServiceError.tool(.planChanged) }
                            return .init(identifier: identifier, attribute: attribute, selected: choice["attributeSetting"] == .number(1) || choice["attributeSetting"] == .bool(true))
                        }
                    }
                } else { choices = nil; toggles = nil }
                let package = HomebrewPrivilegePlan.PackageInstaller(path: path, choices: choices, choiceToggles: toggles, allowUntrusted: options["allow_untrusted"] == .bool(true))
                guard package.valid else { throw PluginHostServiceError.tool(.planChanged) }; packages.append(package)
            }
            if case .array(let args)? = item.value(atPointer: "/installer") {
                guard args.count == 1, case .object(let options) = args[0], options.count == 1 else { throw PluginHostServiceError.tool(.planChanged) }
                if case .string(let path)? = options["manual"] {
                    guard relative(path) else { throw PluginHostServiceError.tool(.planChanged) }; manual.append(path); continue
                }
                guard let value = options["script"] else { throw PluginHostServiceError.tool(.planChanged) }
                let values: [String: JSONValue]
                if case .string(let executable) = value { values = ["executable": .string(executable)] }
                else if case .object(let object) = value { values = object }
                else { throw PluginHostServiceError.tool(.planChanged) }
                guard Set(values.keys).isSubset(of: ["executable", "args", "input", "must_succeed", "sudo", "print_stdout", "print_stderr"]),
                      case .string(var executable)? = values["executable"] else { throw PluginHostServiceError.tool(.planChanged) }
                // Ordinary user-only vendor code never enters a Root grant.
                // Validate the sudo predicate before resolving a native path.
                if let sudo = values["sudo"], sudo != .bool(true) && sudo != .bool(false) { throw PluginHostServiceError.tool(.planChanged) }
                if values["sudo"] != .bool(true) { continue }
                let staged = prefix + "/Caskroom/" + token + "/" + version + "/"
                if executable.hasPrefix(staged) { executable = String(executable.dropFirst(staged.count)) }
                guard relative(executable) else { throw PluginHostServiceError.unavailable("This vendor executable requires a fixed native system operation") }
                let arguments: [String]
                if let raw = values["args"] { guard case .array(let array) = raw else { throw PluginHostServiceError.tool(.planChanged) }; arguments = try array.map(argument) } else { arguments = [] }
                let input: String?
                if let raw = values["input"] {
                    if case .string(let text) = raw { input = text }
                    else if case .array(let chunks) = raw { input = try chunks.map { value in guard case .string(let text) = value else { throw PluginHostServiceError.tool(.planChanged) }; return text }.joined() }
                    else { throw PluginHostServiceError.tool(.planChanged) }
                } else { input = nil }
                for flag in ["must_succeed", "sudo", "print_stdout", "print_stderr"] { if let value = values[flag], value != .bool(true) && value != .bool(false) { throw PluginHostServiceError.tool(.planChanged) } }
                // User-only vendor installers remain ordinary Homebrew code.
                if values["sudo"] != .bool(true) { continue }
                let script = HomebrewPrivilegePlan.NativeScript(phase: .install, executable: executable, arguments: arguments,
                    input: input, mustSucceed: values["must_succeed"] != .bool(false), generatedContent: generated[executable])
                guard script.valid else { throw PluginHostServiceError.tool(.planChanged) }; scripts.append(script)
            }
        }
        return Selection(packages: packages, scripts: scripts, manualInstallers: manual,
                         generatedResources: generated.keys.sorted().map { .init(path: $0, content: generated[$0]!) })
    }
    private static func relative(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048 && !value.hasPrefix("/") && !value.split(separator: "/", omittingEmptySubsequences: false).contains { ["", ".", ".."].contains(String($0)) }
    }
    private static func argument(_ value: JSONValue) throws -> String {
        if case .string(let text) = value { return text }
        if case .number(let number) = value, number.isFinite, abs(number) <= 9_007_199_254_740_991 {
            return number.rounded() == number ? String(Int64(number)) : String(number)
        }
        throw PluginHostServiceError.tool(.planChanged)
    }
}
