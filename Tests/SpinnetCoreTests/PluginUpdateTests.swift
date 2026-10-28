import Foundation
import SpinnetTestSupport
import XCTest
@testable import SpinnetCore

/// A Plugin Update is checked and applied through the one Core
/// install-and-update seam, against recorded GitHub answers.
final class PluginUpdateTests: XCTestCase {
    private var directory: URL!
    private var registry: PluginRegistry!
    private var grants: PluginCapabilityGrantStore!
    private var storage: PluginStorage!
    private var store: PluginInstallationStore!
    private var transport: RecordedGitHubTransport!
    private var updater: PluginUpdater!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        grants = PluginCapabilityGrantStore()
        registry = PluginRegistry(grantStore: grants)
        storage = PluginStorage(directory: directory.appendingPathComponent("Storage"))
        store = PluginInstallationStore(directory: directory.appendingPathComponent("Installed"), registry: registry,
                                        grants: grants, persistGrants: {}, storage: storage)
        transport = RecordedGitHubTransport()
        updater = makeUpdater()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var downloads: URL { directory.appendingPathComponent("Downloads") }

    private func makeUpdater() -> PluginUpdater {
        PluginUpdater(store: store, registry: registry, transport: transport, downloads: downloads)
    }

    @discardableResult
    private func install(version: String, capabilities: [String] = ["write_clipboard"]) throws -> PluginManifest {
        try store.install(from: PluginReleaseFixture.package(
            PluginReleaseFixture.manifest(version: version, capabilities: capabilities), in: directory))
    }

    private func publish(_ releases: [PluginReleaseFixture.Release]) throws {
        try PluginReleaseFixture.publish(releases, on: transport)
    }

    private func publishAsset(tag: String, _ manifest: [String: Any]) throws {
        transport.answer(PluginReleaseFixture.assetURL(tag: tag), body: try PluginReleaseFixture.zipped(manifest, in: directory))
    }

    private func tag(_ version: String) -> String { "com.example.updatable/v\(version)" }

    private var installedVersion: String? { registry.package(for: PluginReleaseFixture.pluginID)?.manifest.version }

    /// Refusal reasons by the version each names.
    private func reasons(_ check: PluginUpdateCheck) -> [String: String] {
        Dictionary(uniqueKeysWithValues: check.refusals.map { ($0.version, $0.reason) })
    }

    /// What is left in the Plugin's download workspace.
    private func leftoverDownloads() -> [String] {
        let workspace = downloads.appendingPathComponent(PluginReleaseFixture.pluginID.rawValue)
        return (try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []
    }

    func testTheHighestAcceptedVersionIsOfferedAndApplyingRegistersIt() throws {
        try install(version: "1.0.0")
        try publish([
            .init(tag: "com.example.other/v9.0.0"),
            .init(tag: tag("1.2.0")),
            .init(tag: tag("1.1.0")),
            .init(tag: tag("0.9.0"))
        ])
        try publishAsset(tag: tag("1.2.0"), PluginReleaseFixture.manifest(version: "1.2.0"))
        try publishAsset(tag: tag("1.1.0"), PluginReleaseFixture.manifest(version: "1.1.0"))

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertEqual(check.installedVersion, "1.0.0")
        XCTAssertEqual(check.update?.manifest.version, "1.2.0")
        XCTAssertEqual(check.refusals, [])
        XCTAssertEqual(installedVersion, "1.0.0", "Checking installs nothing")
        XCTAssertEqual(transport.requestedURLs, [
            PluginReleaseFixture.tagsURL, PluginReleaseFixture.releaseURL(tag: tag("1.2.0")),
            PluginReleaseFixture.assetURL(tag: tag("1.2.0"))
        ], "A lower version is neither looked up nor fetched once a higher one is accepted")

        let applied = try updater.apply(XCTUnwrap(check.update))

        XCTAssertEqual(applied.version, "1.2.0")
        XCTAssertEqual(installedVersion, "1.2.0")
        XCTAssertEqual(leftoverDownloads(), [], "Applying removes the downloaded package")
    }

    func testApplyingKeepsPluginStorageSettingsMenuItemsAndDecisionsAndLeavesNewCapabilitiesUndecided() throws {
        let installed = try install(version: "1.0.0")
        try storage.setValue(.string("kept"), forKey: "counter", of: installed.id)
        grants.setDecision(.granted, for: installed.id, pluginVersion: "1.0.0", capability: .writeClipboard)
        let settingsURL = directory.appendingPathComponent("plugin-settings.json")
        try PluginSettingsStore(fileURL: settingsURL).setValues(["target": .string("FR")], for: installed.id)
        let editor = HostConfigurationEditor(registry: registry, configuration: try HostConfiguration(
            actions: [], menu: MenuConfiguration(slots: [.empty])))
        try editor.placeCommand(pluginID: installed.id, commandID: CommandID("updatable.run"), input: .null, inSlotAt: 0)
        let configuration = editor.configuration
        try publish([.init(tag: tag("2.0.0"))])
        try publishAsset(tag: tag("2.0.0"), PluginReleaseFixture.manifest(
            version: "2.0.0", capabilities: ["write_clipboard", "read_selected_text"]))

        let update = try XCTUnwrap(try updater.check(installed.id).update)

        XCTAssertEqual(update.review.requestedAccess, [.readSelectedText],
                       "Only the newly requested Capability is reviewed before replacement")
        XCTAssertEqual(installedVersion, "1.0.0")

        try updater.apply(update)

        XCTAssertEqual(installedVersion, "2.0.0")
        XCTAssertEqual(try storage.value(forKey: "counter", of: installed.id), .string("kept"))
        XCTAssertEqual(try PluginSettingsStore(fileURL: settingsURL).values(for: installed.id), ["target": .string("FR")])
        XCTAssertEqual(editor.configuration, configuration, "The Menu Item placed for the Plugin stays")
        XCTAssertEqual(editor.configuration.actions.map(\.pluginID), [installed.id])
        XCTAssertNotNil(registry.menuItemPreset(for: installed.id))
        XCTAssertEqual(grants.decision(for: installed.id, pluginVersion: "2.0.0", capability: .writeClipboard), .granted)
        XCTAssertEqual(grants.decision(for: installed.id, pluginVersion: "2.0.0", capability: .readSelectedText),
                       .notDetermined)
    }

    func testAReleaseThatIsNotTheDeclaredRepositorysAssetIsRefusedWithoutDownloading() throws {
        try install(version: "1.0.0")
        let name = PluginReleaseFixture.assetName
        let foreign = PluginReleaseFixture.assetURL(tag: tag("2.5.0"), repository: "someone-else/plugins")
        let plain = "http://github.com/example-org/plugins/releases/download/\(tag("2.4.0"))/\(name)"
        let otherTag = PluginReleaseFixture.assetURL(tag: tag("2.0.0"))
        try publish([
            .init(tag: tag("2.6.0"), assets: []),
            .init(tag: tag("2.5.0"), assets: [(name, foreign)]),
            .init(tag: tag("2.4.0"), assets: [(name, plain)]),
            .init(tag: tag("2.3.0"), assets: [(name, otherTag)]),
            .init(tag: tag("2.2.0"), draft: true),
            .init(tag: tag("2.1.0"), prerelease: true),
            .init(tag: tag("2.0.0")),
            .init(tag: "com.example.updatable/vnext")
        ])
        try publishAsset(tag: tag("2.0.0"), PluginReleaseFixture.manifest(version: "2.0.0"))

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertEqual(check.update?.manifest.version, "2.0.0", "\(check.refusals)")
        XCTAssertEqual(reasons(check), [
            "2.6.0": "The release has no asset named com.example.updatable.spinnetplugin.zip.",
            "2.5.0": "The package is not a release asset of example-org/plugins on github.com over HTTPS.",
            "2.4.0": "The package is not a release asset of example-org/plugins on github.com over HTTPS.",
            "2.3.0": "The package is not a release asset of example-org/plugins on github.com over HTTPS.",
            "next": "The release tag does not name a SemVer version."
        ], "A draft, a tag without a release and a prerelease are not offered and not refused")
        XCTAssertEqual(check.refusals.first { $0.version == "next" }?.tag, "com.example.updatable/vnext")
        XCTAssertFalse(transport.requestedURLs.contains(foreign), "A foreign repository's asset is never fetched")
        XCTAssertFalse(transport.requestedURLs.contains(plain), "Nothing is fetched without HTTPS")
        XCTAssertEqual(transport.requestedURLs.filter { $0 == otherTag }.count, 1,
                       "Another release's asset is fetched only for its own release")
    }

    func testADownloadedPackageIsRefusedWithItsReasonAndTheNextLowerAcceptedVersionWins() throws {
        try install(version: "1.0.0")
        try publish(["2.3.0", "2.2.0", "2.1.0", "2.0.0", "1.5.0"].map { .init(tag: tag($0)) })
        try publishAsset(tag: tag("2.3.0"), PluginReleaseFixture.manifest(id: "com.example.impostor", version: "2.3.0"))
        try publishAsset(tag: tag("2.2.0"), PluginReleaseFixture.manifest(version: "2.2.0", updateSource: "someone-else/plugins"))
        try publishAsset(tag: tag("2.1.0"), PluginReleaseFixture.manifest(version: "2.1.0", updateSource: nil))
        let nextMajor = HostVersion.current.major + 1
        try publishAsset(tag: tag("2.0.0"), PluginReleaseFixture.manifest(version: "2.0.0", engines: "^\(nextMajor).0.0"))
        let storageURL = "https://release-assets.githubusercontent.com/github-production-release-asset/1"
        transport.answer(PluginReleaseFixture.assetURL(tag: tag("1.5.0")), status: 302, headers: ["Location": storageURL])
        transport.answer(storageURL, body: try PluginReleaseFixture.zipped(PluginReleaseFixture.manifest(version: "1.5.0"), in: directory))

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertEqual(check.update?.manifest.version, "1.5.0", "\(check.refusals)")
        XCTAssertEqual(check.refusals.map(\.version), ["2.3.0", "2.2.0", "2.1.0", "2.0.0"], "Highest first")
        let reasons = reasons(check)
        XCTAssertEqual(reasons["2.3.0"], "The package is a different Plugin, com.example.impostor.")
        XCTAssertEqual(reasons["2.2.0"], "The package declares the Update Source someone-else/plugins, not example-org/plugins.")
        XCTAssertEqual(reasons["2.1.0"], "The package declares no Update Source, not example-org/plugins.")
        XCTAssertEqual(reasons["2.0.0"]?.contains("requires Spinnet ^\(nextMajor).0.0"), true, reasons["2.0.0"] ?? "")
        XCTAssertEqual(leftoverDownloads().count, 1, "Only the accepted package stays unpacked")
        XCTAssertEqual(installedVersion, "1.0.0")
    }

    func testAPackageWhoseVersionIsNotItsTagsIsRefused() throws {
        try install(version: "1.0.0")
        try publish([.init(tag: tag("2.0.0"))])
        try publishAsset(tag: tag("2.0.0"), PluginReleaseFixture.manifest(version: "1.0.0"))

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertNil(check.update)
        XCTAssertEqual(reasons(check), ["2.0.0": "The package is version 1.0.0, not the 2.0.0 its release tag names."])
        XCTAssertEqual(leftoverDownloads(), [], "A refused package does not stay unpacked")
    }

    func testACheckDownloadsAtMostItsPublishedNumberOfPackages() throws {
        try install(version: "1.0.0")
        let versions = (1...7).reversed().map { "1.\($0).0" }
        try publish(versions.map { .init(tag: tag($0)) })
        for version in versions {
            transport.answer(PluginReleaseFixture.assetURL(tag: tag(version)), body: Data("not a zip".utf8))
        }

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertNil(check.update)
        XCTAssertEqual(check.refusals.map(\.version), versions)
        let reasons = reasons(check)
        for version in versions.prefix(5) {
            XCTAssertEqual(reasons[version], "The package archive is not a readable ZIP file.")
        }
        for version in versions.dropFirst(5) {
            XCTAssertEqual(reasons[version], "Not downloaded: a check downloads at most 5 packages.")
            XCTAssertFalse(transport.requestedURLs.contains(PluginReleaseFixture.assetURL(tag: tag(version))))
        }
        XCTAssertEqual(leftoverDownloads(), [], "Refused packages do not stay unpacked")
    }

    func testACheckLooksUpAtMostItsPublishedNumberOfReleases() throws {
        try install(version: "1.0.0")
        let versions = (1...12).reversed().map { "1.\($0).0" }
        try publish(versions.map { .init(tag: tag($0), draft: true) })

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertNil(check.update)
        XCTAssertEqual(transport.requestedURLs.dropFirst(), ArraySlice(versions.prefix(10).map {
            PluginReleaseFixture.releaseURL(tag: tag($0))
        }))
        XCTAssertEqual(reasons(check), [
            "1.2.0": "Not looked up: a check looks up at most 10 releases.",
            "1.1.0": "Not looked up: a check looks up at most 10 releases."
        ])
    }

    func testAVersionIsFoundByItsTagHoweverManyReleasesTheRepositoryHas() throws {
        try install(version: "1.0.0")
        // GitHub matches the tags by prefix, so other Plugins' releases in the
        // repository never crowd this Plugin's out.
        transport.answer(PluginReleaseFixture.tagsURL, body: try PluginReleaseFixture.tagList([tag("1.0.1")]))
        try publish([.init(tag: tag("1.0.1"))])
        try publishAsset(tag: tag("1.0.1"), PluginReleaseFixture.manifest(version: "1.0.1"))

        XCTAssertEqual(try updater.check(PluginReleaseFixture.pluginID).update?.manifest.version, "1.0.1")
    }

    func testARedirectGoesOnlyToGitHubsDownloadStorageAndOnlyThreeTimes() throws {
        try install(version: "1.0.0")
        try publish(["1.4.0", "1.3.0", "1.2.0", "1.1.0"].map { .init(tag: tag($0)) })
        transport.answer(PluginReleaseFixture.assetURL(tag: tag("1.4.0")), status: 302,
                         headers: ["Location": "https://downloads.example.com/package.zip"])
        transport.answer(PluginReleaseFixture.assetURL(tag: tag("1.3.0")), status: 302,
                         headers: ["Location": PluginReleaseFixture.assetURL(tag: tag("1.3.0"), repository: "someone-else/plugins")])
        let hops = (1...4).map { "https://objects.githubusercontent.com/github-production-release-asset/\($0)" }
        transport.answer(PluginReleaseFixture.assetURL(tag: tag("1.2.0")), status: 302, headers: ["Location": hops[0]])
        for (hop, next) in zip(hops, hops.dropFirst()) {
            transport.answer(hop, status: 302, headers: ["Location": next])
        }
        transport.answer(hops[3], body: try PluginReleaseFixture.zipped(PluginReleaseFixture.manifest(version: "1.2.0"), in: directory))
        transport.answer(PluginReleaseFixture.assetURL(tag: tag("1.1.0")), body: Data(count: PluginUpdateBudgets.maximumPackageBytes + 1))

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertNil(check.update)
        XCTAssertEqual(reasons(check), [
            "1.4.0": "The release asset redirects away from GitHub's download storage.",
            "1.3.0": "The release asset redirects away from GitHub's download storage.",
            "1.2.0": "The release asset redirects more than 3 times.",
            "1.1.0": "GitHub's answer is larger than Spinnet reads."
        ])
        XCTAssertFalse(transport.requestedURLs.contains("https://downloads.example.com/package.zip"))
        XCTAssertFalse(transport.requestedURLs.contains(hops[3]))
    }

    func testOnlyStrictlyNewerPublishedReleasesAreConsidered() throws {
        try install(version: "1.2.0")
        try publish([
            .init(tag: tag("1.3.0"), draft: true),
            .init(tag: tag("1.3.0-beta.1"), prerelease: true),
            .init(tag: tag("1.2.0")),
            .init(tag: tag("1.2.0-rc.1")),
            .init(tag: tag("1.1.9"))
        ])

        let check = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertNil(check.update)
        XCTAssertEqual(check.refusals, [])
        XCTAssertEqual(transport.requestedURLs, [
            PluginReleaseFixture.tagsURL, PluginReleaseFixture.releaseURL(tag: tag("1.3.0")),
            PluginReleaseFixture.releaseURL(tag: tag("1.3.0-beta.1"))
        ], "No package is downloaded")
    }

    func testAPrereleaseVersionComparesBySemVerPrecedence() throws {
        try install(version: "2.0.0-beta.2")
        try publish([.init(tag: tag("2.0.0-beta.10")), .init(tag: tag("2.0.0-beta.1"))])
        try publishAsset(tag: tag("2.0.0-beta.10"), PluginReleaseFixture.manifest(version: "2.0.0-beta.10"))

        XCTAssertEqual(try updater.check(PluginReleaseFixture.pluginID).update?.manifest.version, "2.0.0-beta.10")
    }

    func testNumericPrereleaseIdentifiersCompareExactlyAtAnySize() throws {
        let huge = "2.0.0-beta.18446744073709551616"
        let larger = "2.0.0-beta.18446744073709551617"
        XCTAssertLessThan(try PluginVersion(huge), try PluginVersion(larger))
        XCTAssertLessThan(try PluginVersion("2.0.0-beta.99"), try PluginVersion(huge))
        XCTAssertLessThan(try PluginVersion("2.0.0-beta.99999999999999999999"),
                          try PluginVersion("2.0.0-beta.100000000000000000000"), "Longer digits are the larger number")
        XCTAssertLessThan(try PluginVersion("2.0.0-beta.99999999999999999999"), try PluginVersion("2.0.0-beta.1-a"),
                          "A numeric identifier sorts below an alphanumeric one however large it is")
    }

    private func failedCheck() -> PluginUpdateError? {
        do {
            _ = try updater.check(PluginReleaseFixture.pluginID)
            XCTFail("The check succeeded")
            return nil
        } catch {
            return error as? PluginUpdateError
        }
    }

    func testAFailedCheckSaysWhyAndTheInstalledVersionKeepsWorking() throws {
        try install(version: "1.0.0")

        XCTAssertEqual(failedCheck(), .offline)
        XCTAssertEqual(failedCheck()?.localizedDescription,
                       "Spinnet could not reach GitHub. Check your connection and try again.")

        transport.answer(PluginReleaseFixture.tagsURL, status: 403,
                         headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1700000000"])
        XCTAssertEqual(failedCheck(), .rateLimited(resetsAt: Date(timeIntervalSince1970: 1_700_000_000)))
        XCTAssertEqual(failedCheck()?.localizedDescription.hasPrefix(
            "GitHub's limit on update checks is reached. Try again after "), true)

        transport.answer(PluginReleaseFixture.tagsURL, status: 404)
        XCTAssertEqual(failedCheck(), .repositoryNotFound(try PluginUpdateSource(github: PluginReleaseFixture.repository)))

        transport.answer(PluginReleaseFixture.tagsURL, status: 500)
        XCTAssertEqual(failedCheck(), .unexpectedStatus(500))

        transport.answer(PluginReleaseFixture.tagsURL, body: Data(#"{"message": "Moved"}"#.utf8))
        XCTAssertEqual(failedCheck(), .unreadableAnswer("it is not a list of tags."))

        transport.answer(PluginReleaseFixture.tagsURL, body: Data(count: PluginUpdateBudgets.maximumAnswerBytes + 1))
        XCTAssertEqual(failedCheck(), .unreadableAnswer("GitHub's answer is larger than Spinnet reads."))

        try publish([.init(tag: tag("1.1.0"))])
        transport.answer(PluginReleaseFixture.releaseURL(tag: tag("1.1.0")), status: 429)
        XCTAssertEqual(failedCheck(), .rateLimited(resetsAt: nil), "A limit reached while looking up a release fails the check")

        XCTAssertEqual(installedVersion, "1.0.0")
        XCTAssertTrue(registry.menuItemPreset(for: PluginReleaseFixture.pluginID)?.isAvailable == true)
    }

    func testAPluginWithoutAnUpdateSourceIsNeverChecked() throws {
        try store.install(from: PluginReleaseFixture.package(
            PluginReleaseFixture.manifest(version: "1.0.0", updateSource: nil), in: directory))

        XCTAssertEqual(failedCheck(), .noUpdateSource("Updatable"))
        XCTAssertEqual(transport.requests, [])
    }

    func testTheTagsAndReleaseAreAskedOfGitHubsAPIForTheDeclaredRepositoryWithoutCredentials() throws {
        try install(version: "1.0.0")
        try publish([.init(tag: tag("1.1.0"), draft: true)])

        _ = try updater.check(PluginReleaseFixture.pluginID)

        XCTAssertEqual(transport.requestedURLs, [
            "https://api.github.com/repos/example-org/plugins/git/matching-refs/tags/com.example.updatable/v",
            "https://api.github.com/repos/example-org/plugins/releases/tags/com.example.updatable/v1.1.0"
        ])
        for request in transport.requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.headers["Accept"], "application/vnd.github+json")
            XCTAssertNil(request.headers["Authorization"])
            XCTAssertEqual(request.maximumResponseBytes, PluginUpdateBudgets.maximumAnswerBytes)
        }
    }

    func testAnUpdateThatNoLongerAppliesIsRefusedWhenApplied() throws {
        try install(version: "1.0.0")
        try publish([.init(tag: tag("1.1.0"))])
        try publishAsset(tag: tag("1.1.0"), PluginReleaseFixture.manifest(version: "1.1.0"))
        let update = try XCTUnwrap(try updater.check(PluginReleaseFixture.pluginID).update)
        try install(version: "1.2.0")

        XCTAssertThrowsError(try updater.apply(update)) { error in
            guard case .changedSinceCheck? = error as? PluginUpdateError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(installedVersion, "1.2.0")
    }

    func testANewUpdaterStartsWithNoDownloadsLeftOver() throws {
        try install(version: "1.0.0")
        try publish([.init(tag: tag("1.1.0"))])
        try publishAsset(tag: tag("1.1.0"), PluginReleaseFixture.manifest(version: "1.1.0"))
        let update = try XCTUnwrap(try updater.check(PluginReleaseFixture.pluginID).update)
        XCTAssertTrue(FileManager.default.fileExists(atPath: update.packageURL.path))

        _ = makeUpdater()

        XCTAssertFalse(FileManager.default.fileExists(atPath: downloads.path))
    }

    /// The published version-selection fixtures are what the Host offers.
    func testThePublishedVersionSelectionFixturesAreWhatACheckOffers() throws {
        struct Case: Decodable { let name: String; let installed: String; let tags: [String]; let offered: String? }
        struct Index: Decodable { let plugin_id: String; let cases: [Case] }
        let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: TestRepository.root
            .appendingPathComponent("PluginAPI/fixtures/update-source/index.json")))
        XCTAssertEqual(index.plugin_id, PluginReleaseFixture.pluginID.rawValue)
        XCTAssertFalse(index.cases.isEmpty)
        for fixture in index.cases {
            try setUpWithError()
            try install(version: fixture.installed)
            try publish(fixture.tags.map { .init(tag: $0) })
            for tag in fixture.tags {
                let version = String(tag.split(separator: "/").last!.dropFirst())
                let id = String(tag.split(separator: "/").first!)
                try publishAsset(tag: tag, PluginReleaseFixture.manifest(id: id, version: version))
            }

            let check = try updater.check(PluginReleaseFixture.pluginID)

            XCTAssertEqual(check.update?.manifest.version, fixture.offered, fixture.name)
            XCTAssertEqual(check.refusals, [], fixture.name)
            try tearDownWithError()
        }
    }

    func testTheReleaseFormatAndBoundsAreThePublishedOnes() throws {
        let page = "reference/update-source.md"
        XCTAssertPublished("| Release tag | `<id>/v<version>` | `com.example.plugin/v1.2.0` |", in: page)
        XCTAssertEqual(PluginUpdateSource.releaseTag(for: PluginID("com.example.plugin"), version: "1.2.0"),
                       "com.example.plugin/v1.2.0")
        XCTAssertPublished("| Release asset name | `<id>.spinnetplugin.zip` | `com.example.plugin.spinnetplugin.zip` |", in: page)
        XCTAssertEqual(PluginUpdateSource.assetName(for: PluginID("com.example.plugin")), "com.example.plugin.spinnetplugin.zip")
        XCTAssertPublished("| Releases looked up per check | 10 |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumReleaseLookups, 10)
        XCTAssertPublished("| Packages downloaded per check | 5 |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumDownloads, 5)
        XCTAssertPublished("| Tag list or release answer size | 4 MiB |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumAnswerBytes, 4 * 1024 * 1024)
        XCTAssertPublished("| Package asset size | 16 MiB |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumPackageBytes, 16 * 1024 * 1024)
        XCTAssertPublished("| Unpacked package size | 64 MiB |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumUnpackedBytes, 64 * 1024 * 1024)
        XCTAssertPublished("| Archive entries | 2048 |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumArchiveEntries, 2048)
        XCTAssertPublished("| Download redirects | 3 |", in: page)
        XCTAssertEqual(PluginUpdateBudgets.maximumRedirects, 3)

        // The redirect targets the reference lists are exactly the ones followed.
        let reference = try String(contentsOf: TestRepository.root.appendingPathComponent("PluginAPI/" + page), encoding: .utf8)
        let sentence = try XCTUnwrap(reference.range(of: #"redirected only to GitHub's download\s+storage\s+\(([^)]*)\)"#,
                                                     options: .regularExpression).map { String(reference[$0]) })
        let listed = sentence.split(separator: "`").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        XCTAssertEqual(Set(listed), PluginUpdateBudgets.downloadHosts)
        XCTAssertEqual(listed.count, PluginUpdateBudgets.downloadHosts.count)
    }
}

/// Writes stored (uncompressed) ZIP archives entry by entry, so a test can
/// publish an archive no well-behaved tool would make.
enum HandmadeZip {
    struct Entry {
        var name: String
        var contents: Data = Data()
        /// The Unix file type and permissions recorded for the entry.
        var mode: UInt32 = 0o100644
        /// The host system recorded in "version made by": 3 is Unix, 19 is OS X.
        var madeBy: Int = 3
    }

    private static func le16(_ value: Int, into data: inout Data) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    private static func le32(_ value: UInt32, into data: inout Data) {
        for shift in 0..<4 { data.append(UInt8(value >> (8 * UInt32(shift)) & 0xFF)) }
    }

    static func make(_ entries: [Entry]) -> Data {
        var local = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = PluginPackageArchive.crc32([UInt8](entry.contents))
            let size = UInt32(entry.contents.count)
            let offset = UInt32(local.count)
            le32(0x0403_4B50, into: &local)
            for field in [20, 0x800, 0, 0, 0] { le16(field, into: &local) }
            le32(crc, into: &local); le32(size, into: &local); le32(size, into: &local)
            le16(name.count, into: &local); le16(0, into: &local)
            local.append(name); local.append(entry.contents)

            le32(0x0201_4B50, into: &central)
            for field in [entry.madeBy << 8 | 20, 20, 0x800, 0, 0, 0] { le16(field, into: &central) }
            le32(crc, into: &central); le32(size, into: &central); le32(size, into: &central)
            for field in [name.count, 0, 0, 0, 0] { le16(field, into: &central) }
            le32(entry.mode << 16, into: &central); le32(offset, into: &central)
            central.append(name)
        }
        var end = Data()
        le32(0x0605_4B50, into: &end)
        for field in [0, 0, entries.count, entries.count] { le16(field, into: &end) }
        le32(UInt32(central.count), into: &end); le32(UInt32(local.count), into: &end); le16(0, into: &end)
        return local + central + end
    }
}

/// A downloaded package archive unpacks only into its own directory, and
/// only as plain files and folders.
final class PluginPackageArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let manifest = Data(#"{"id": "com.example.archive"}"#.utf8)

    private func refusal(_ entries: [HandmadeZip.Entry]) -> String? {
        let out = directory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try PluginPackageArchive.unpack(HandmadeZip.make(entries), into: out)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func testAFolderZippedByDittoUnpacksToThePackage() throws {
        let zipped = try PluginReleaseFixture.zipped(PluginReleaseFixture.manifest(version: "1.0.0"), in: directory)

        let package = try PluginPackageArchive.unpack(zipped, into: directory.appendingPathComponent("out"))

        XCTAssertEqual(package.lastPathComponent, "Updatable.spinnetplugin")
        XCTAssertEqual(try PluginManifestLoader.load(packageAt: package).manifest.version, "1.0.0")
        XCTAssertEqual(try String(contentsOf: package.appendingPathComponent("run.js"), encoding: .utf8),
                       "spinnet.answer(null)")
    }

    func testAStoredArchiveWithFinderSidecarsUnpacks() throws {
        let package = try PluginPackageArchive.unpack(HandmadeZip.make([
            .init(name: "A.spinnetplugin/", mode: 0o040755),
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest),
            .init(name: "__MACOSX/A.spinnetplugin/._manifest.json", contents: Data([0]))
        ]), into: directory.appendingPathComponent("out"))

        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("manifest.json")), manifest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("out/__MACOSX").path))
    }

    func testLinksEscapingPathsAndStrayContentsAreRefused() {
        XCTAssertEqual(refusal([
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest),
            .init(name: "A.spinnetplugin/run.js", contents: Data("/etc/passwd".utf8), mode: 0o120777)
        ]), "The package archive contains a link or special file: A.spinnetplugin/run.js")
        XCTAssertEqual(refusal([.init(name: "A.spinnetplugin/../../escape.js")]),
                       "The package archive contains an unsafe path: A.spinnetplugin/../../escape.js")
        XCTAssertEqual(refusal([.init(name: "/tmp/escape.js")]),
                       "The package archive contains an unsafe path: /tmp/escape.js")
        XCTAssertEqual(refusal([
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest),
            .init(name: "B.spinnetplugin/manifest.json", contents: manifest)
        ]), "The package archive must hold exactly one .spinnetplugin folder at its top level")
        XCTAssertEqual(refusal([.init(name: "manifest.json", contents: manifest)]),
                       "The package archive must hold exactly one .spinnetplugin folder at its top level")
        XCTAssertEqual(refusal([
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest),
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest)
        ]), "The package archive lists A.spinnetplugin/manifest.json twice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape.js").path))
    }

    func testALinkRecordedByOSXIsRefusedToo() {
        XCTAssertEqual(refusal([
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest, madeBy: 19),
            .init(name: "A.spinnetplugin/run.js", contents: Data("/etc/passwd".utf8), mode: 0o120777, madeBy: 19)
        ]), "The package archive contains a link or special file: A.spinnetplugin/run.js")
    }

    func testPathsThatNameOneFileOnACaseInsensitiveDiskAreListedTwice() {
        XCTAssertEqual(refusal([
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest),
            .init(name: "A.spinnetplugin/Manifest.JSON", contents: manifest)
        ]), "The package archive lists A.spinnetplugin/Manifest.JSON twice")
        XCTAssertEqual(refusal([
            .init(name: "A.spinnetplugin/manifest.json", contents: manifest),
            .init(name: "A.spinnetplugin/caf\u{E9}.js"),
            .init(name: "A.spinnetplugin/cafe\u{301}.js")
        ]), "The package archive lists A.spinnetplugin/cafe\u{301}.js twice")
    }

    func testADamagedEntryIsRefused() throws {
        var archive = HandmadeZip.make([.init(name: "A.spinnetplugin/manifest.json", contents: manifest)])
        let index = try XCTUnwrap(archive.firstRange(of: manifest)).lowerBound
        archive[index] ^= 0xFF

        XCTAssertThrowsError(try PluginPackageArchive.unpack(archive, into: directory.appendingPathComponent("out"))) {
            XCTAssertEqual($0.localizedDescription,
                           "The package archive is damaged: A.spinnetplugin/manifest.json fails its checksum")
        }
    }
}
