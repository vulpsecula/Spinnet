import XCTest
@testable import SpinnetCore

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
                let output = try HomebrewReadProfile.execute(executable, arguments, environment, deadline)
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
