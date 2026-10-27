import XCTest
@testable import SpinnetCore
@testable import SpinnetReviewedTools

final class HomebrewReadBootstrapNativeTests: XCTestCase {
    private func requireNativeProbe() throws {
        guard ProcessInfo.processInfo.environment["SPINNET_HOMEBREW_NATIVE_PROBE"] == "1" else { throw XCTSkip("Opt-in read-only installed Homebrew probe") }
    }
    func testNativeReadOutputDoesNotContainSandboxBootstrapErrors() throws {
        try requireNativeProbe()
        for command in ["version", "list", "outdated", "search", "info", "tap"] {
            var input: [String: JSONValue] = ["tool": .string("homebrew"), "operation": .string("commandOutput"), "command": .string(command)]
            if ["search", "info"].contains(command) { input["package"] = .string("wget") }
            let result = try HomebrewReadProfile().read(.object(input), owner: .init("bootstrap-native"), timeout: 15)
            guard case .string(let output)? = result.value(atPointer: "/output") else { return XCTFail("Missing native output") }
            XCTAssertFalse(output.contains("cannot create temp file for here document"), command + " contains denied bootstrap writes")
            XCTAssertEqual(result.value(atPointer: "/exit_status"), .number(0), command)
        }
    }
    func testNativeAvailableUpgradeMetadataAfterReviewedSourceUpdate() throws {
        try requireNativeProbe()
        let result = try HomebrewReadProfile().read(.object(["tool":.string("homebrew"),"operation":.string("outdated")]),owner:.init("upgrades-after-update-native"),timeout:15)
        XCTAssertEqual(result.value(atPointer:"/operation"),.string("outdated"))
        guard case .array? = result.value(atPointer:"/packages") else { return XCTFail("Available Upgrades requires a package list after update") }
    }
    func testNativePublicManagementReads() throws {
        try requireNativeProbe()
        for operation in ["version", "taps", "doctor"] {
            let result = try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string(operation)]), owner: .init("public-management-native"), timeout: 15)
            XCTAssertEqual(result.value(atPointer: "/operation"), .string(operation))
            if operation == "doctor" {
                XCTAssertEqual(result.value(atPointer: "/available"), .bool(true))
                XCTAssertNotNil(result.value(atPointer: "/findings"))
            }
        }
    }
    func testNativeSelectedOutdatedCasksCanReachUpgradePreflight() throws {
        try requireNativeProbe()
        let brew = try HomebrewReadProfile.discover()
        let profile = HomebrewReadProfile(executable: { brew }, execute: { executable, arguments, environment, deadline in
            let output = try HomebrewReadProfile.executeReadCancellable(executable, arguments, environment, deadline, .init())
            if output.status != 0 && !(arguments.first == "outdated" && output.status == 1) {
                let log = HomebrewTaskLog(); log.append(output.stderr); log.finish()
                XCTFail("Selected-cask read \(arguments) exited \(output.status): \(log.output.prefix(1600))")
            }
            return output
        })
        let outdated = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("outdated"), "kind": .string("cask")]), owner: .init("selected-casks-native"), timeout: 15)
        guard case .array(let packages)? = outdated.value(atPointer: "/packages") else { return XCTFail("Missing cask list") }
        let names = Array(packages.compactMap { $0.value(atPointer: "/name") }.prefix(50))
        guard !names.isEmpty else { throw XCTSkip("No outdated casks available") }
        let metadata = try profile.read(.object(["tool": .string("homebrew"), "operation": .string("info"), "kind": .string("cask"), "names": .array(names)]), owner: .init("selected-casks-native"), timeout: 15)
        guard case .array(let records)? = metadata.value(atPointer: "/packages") else { return XCTFail("Missing batch metadata") }
        XCTAssertEqual(records.count, names.count)
        let eligible = records.filter { $0.value(atPointer: "/outdated") == .bool(true) && $0.value(atPointer: "/pinned") != .bool(true) }.compactMap { $0.value(atPointer: "/name") }
        guard !eligible.isEmpty else { throw XCTSkip("All current casks are pinned or already current") }
        let input = try HomebrewTaskInput(.object(["tool": .string("homebrew"), "operation": .string("upgradeSelected"), "kind": .string("cask"), "names": .array(eligible)]))
        let preflight = try HostReviewedToolTasks.preflight(input, executable: brew)
        guard case .array(let planned)? = preflight.value(atPointer: "/packages") else { return XCTFail("Missing upgrade plan") }
        XCTAssertEqual(planned.count, eligible.count)
    }
    func testNativeSearchMatchesAndMissesCompleteWithoutReviewedReadFailure() throws {
        try requireNativeProbe()
        let installed = try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string("installed")]), owner: .init("search-bootstrap-native"), timeout: 15)
        XCTAssertNotNil(installed.value(atPointer: "/packages"), "Search first loads installed state")
        for query in ["wget", "firefox", "google-chrome", "git", "zz-spinnet-no-such-package", "node@", "c++", "foo.bar", "@scope", "++"] {
            XCTAssertNoThrow(try HomebrewReadProfile().read(.object(["tool": .string("homebrew"), "operation": .string("search"), "query": .string(query)]), owner: .init("search-bootstrap-native"), timeout: 15), query)
        }
    }
    func testNativeSearchWhileTypingCommonPackagePrefixes() throws {
        try requireNativeProbe()
        let queries = ["fi","fir","fire","firef","ch","chr","chro","chrome","co","cod","code","codex","cl","cla","claude","go","goog","google","vi","vim","py","pyt","python","no","nod","node","sp","spo","spot","spotify","ze","zed","po","post","postgres","do","dock","docker","fo","font","ja","java","ru","rust","ne","neo","neovim"]
        for query in queries {
            var diagnostics = ""
            let profile = HomebrewReadProfile(executable: HomebrewReadProfile.discover, execute: { executable, arguments, environment, deadline in
                let output = try HomebrewReadProfile.executeReadCancellable(executable, arguments, environment, deadline, .init())
                if output.status != 0 {
                    let sanitized = HomebrewTaskLog(); sanitized.append(output.stderr); sanitized.finish()
                    diagnostics += "\(arguments.prefix(2)) status=\(output.status): \(sanitized.output.prefix(1600))\n"
                }
                return output
            })
            do {
                _ = try profile.read(.object(["tool":.string("homebrew"),"operation":.string("search"),"query":.string(query)]),owner:.init("search-prefix-native"),timeout:15)
            } catch { XCTFail("query=\(query) \(error)\n\(diagnostics)") }
        }
    }

    func testNativeRapidSearchSourcesDiscardCancelledReads() throws {
        try requireNativeProbe()
        let owner = PluginID("search-sources-native")
        let command = CommandDeclaration(id:.init("search"),title:"Search",execution:.javascript,script:"search.js")
        let action = try ActionConfiguration(id:.init("search"),pluginID:owner,command:command,input:.null)
        let profile = HomebrewReadProfile()
        let adapter = HostSourceAdapter(deadline:15,authorize:{ _, _ in },sample:{ _, source, cancellation in
            try profile.read(source.input,owner:owner,timeout:15,cancellation:cancellation)
        })
        let engine = HostRunSources(adapters:["tools.read":adapter],schedule:{ delay, work in DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work) },executor:{ work in DispatchQueue.main.async(execute:work) })
        defer { engine.end(pluginID:owner) }
        func page(_ index: Int, _ query: String) throws -> PluginPage {
            try PluginPage(parsing:.object(["id":.string("search"),"title":.string("Search"),"content":.array([.object(["id":.string("status"),"kind":.string("text"),"text":.string("Searching")])]),
                "sources":.array([.object(["id":.string("query-\(index)"),"perform":.string("tools.read"),"input":.object(["tool":.string("homebrew"),"operation":.string("search"),"query":.string(query)]),"deliver":.object([:])])])]),permits:{ _ in true })
        }
        let queries = ["fi","fir","fire","firef","firefox","ch","chr","chro","chrome"]
        let completed = expectation(description:"Only the newest query completes")
        var delivered = 0
        engine.onDelivery = { _, event, current in
            guard current() else { return }
            guard case .sourceDelivered(_,let source,_,let result,let failure) = event else { return }
            delivered += 1
            XCTAssertEqual(source,"query-\(queries.count-1)")
            XCTAssertNil(failure); XCTAssertNotNil(result)
            completed.fulfill()
        }
        try engine.present(page(0,queries[0]),for:action); engine.setVisible(true,pluginID:owner)
        for index in 1..<queries.count {
            let next = try page(index,queries[index])
            DispatchQueue.main.asyncAfter(deadline:.now()+Double(index)*0.06) {
                do { try engine.present(next,for:action) } catch { XCTFail("\(error)") }
            }
        }
        wait(for:[completed],timeout:20)
        XCTAssertEqual(delivered,1)
    }

}
