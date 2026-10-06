import Foundation
import XCTest
@testable import SpinnetCore

/// Plugin API Level 2 (#79): Candidate Contracts `namespaces` r1,
/// `host_operations` r2 and `collections` r3, promoted together. Level 2
/// offers Level 1's members and theirs; every revision of the three is
/// retired with the Level it became, so a Plugin still declaring one is told
/// to install its Level 2 revision; and a Level 1 Plugin is held to Level 1
/// exactly as before.
final class PluginAPILevelTwoTests: XCTestCase {
    private let host = PluginInterfaceContracts.host

    private func manifest(apiLevel: Int, declaring candidates: [CandidateContractRevision] = []) throws -> PluginManifest {
        let declarations = candidates.map { #"{"name": "\#($0.name)", "revision": \#($0.revision)}"# }
        let member = candidates.isEmpty ? "" : #""candidate_contracts": [\#(declarations.joined(separator: ", "))],"#
        return try PluginManifestLoader.decode(Data("""
        {
          "protocol_version": "1.0",
          "api_level": \(apiLevel),
          \(member)
          "id": "com.example.level-two",
          "name": "Level Two",
          "version": "1.0.0",
          "commands": [{"id": "level.run", "title": "Run", "execution": "javascript", "script": "run.js"}]
        }
        """.utf8))
    }

    func testThisHostSupportsLevelTwoAndReportsIt() {
        XCTAssertEqual(PluginAPILevel.highestSupported, 2)
        XCTAssertEqual(host.highestStableLevel, 2)
        XCTAssertEqual(PluginRuntimeEnvironment(hostVersion: "1.0", preferredLanguage: "en").apiLevel, 2,
                       "spinnet.environment.apiLevel is the highest stable Level, for every Plugin")
    }

    /// Level 2 adds exactly the members of the latest revision of each of
    /// the three candidates; Level 1 is unchanged.
    func testLevelTwoIsTheLatestRevisionsOfTheThreeCandidates() throws {
        XCTAssertEqual(host.levels[1], PluginInterfaceContracts.levelOneMembers)
        XCTAssertEqual(host.levels[2], Set(HostServiceCatalogue.candidate.members
                                           + HostOperationsContract.revisionTwo.members
                                           + CollectionsContract.candidate.members))
        XCTAssertEqual(Set(host.levels.keys), [1, 2])
        XCTAssertEqual(host, try PluginInterfaceContracts.candidateHost.promoting(
            PluginInterfaceContracts.levelTwoCandidates, toLevel: 2))
    }

    /// The candidate Host, which promotion starts from, is the Host the
    /// external proofs froze: Level 1 and every revision provided.
    func testTheCandidateHostIsLevelOneWithEveryRevisionProvided() {
        let candidateHost = PluginInterfaceContracts.candidateHost
        XCTAssertEqual(candidateHost.levels, [1: PluginInterfaceContracts.levelOneMembers])
        XCTAssertEqual(candidateHost.candidates.map { "\($0.name) r\($0.revision)" },
                       ["namespaces r1", "host_operations r1", "host_operations r2",
                        "collections r1", "collections r2", "collections r3"])
        XCTAssertTrue(candidateHost.candidates.allSatisfy { $0.status == .supported })
    }

    func testEveryRevisionOfTheThreeIsRetiredIntoLevelTwo() {
        XCTAssertEqual(host.candidates.map { "\($0.name) r\($0.revision)" },
                       PluginInterfaceContracts.candidateHost.candidates.map { "\($0.name) r\($0.revision)" })
        for candidate in host.candidates {
            XCTAssertEqual(candidate.status, .retired(promotedToLevel: 2), "\(candidate.name) r\(candidate.revision)")
        }
    }

    /// The three require each other, so none is promoted alone.
    func testACandidateIsNotPromotedWithoutTheCandidatesItRequires() {
        let candidateHost = PluginInterfaceContracts.candidateHost
        XCTAssertThrowsError(try candidateHost.promoting(["collections"], toLevel: 2)) {
            XCTAssertEqual($0 as? CandidateContractPromotionError,
                           .requiresUnpromoted(candidate: "collections", needs: "host_operations"))
        }
        XCTAssertThrowsError(try candidateHost.promoting(["collections", "host_operations"], toLevel: 2)) {
            XCTAssertEqual($0 as? CandidateContractPromotionError,
                           .requiresUnpromoted(candidate: "collections", needs: "namespaces"))
        }
        XCTAssertNoThrow(try candidateHost.promoting(["namespaces"], toLevel: 2),
                         "namespaces requires nothing, so the tooling could promote it alone")
    }

    // MARK: Who gets what

    func testALevelTwoPluginIsAcceptedEvenWhenBundled() throws {
        let levelTwo = try manifest(apiLevel: 2)
        XCTAssertNoThrow(try host.check(levelTwo, origin: .installed))
        XCTAssertNoThrow(try host.check(levelTwo, origin: .bundled), "Level 2 is stable, so a Bundled Plugin may use it")
    }

    func testALevelThreePluginIsRefusedWithTheUpdateMessage() throws {
        XCTAssertThrowsError(try host.check(manifest(apiLevel: 3), origin: .installed)) {
            XCTAssertEqual($0.localizedDescription, "Level Two needs Plugin API Level 3, but this version of Spinnet "
                + "supports up to Level 2. Update Spinnet to install it.")
        }
    }

    /// A Level 2 Plugin gets the three candidates' members, without
    /// declaring them, and keeps Level 1's view vocabulary for a Level 1
    /// `view` (C9); a Level 1 Plugin gets none of Level 2.
    func testLevelTwoMembersReachOnlyALevelTwoPlugin() throws {
        let levelOne = try manifest(apiLevel: 1), levelTwo = try manifest(apiLevel: 2)
        let levelTwoOnly: [PluginInterfaceMember] = [
            HostServiceCatalogue.catalogueIDsOnly, .hostService("clipboard.write"), .hostCommand("open.url"),
            HostOperationsContract.answerOperation, .request("selection.replace"), HostOperationsContract.operationFinished,
            HostOperationsContract.executionTimeInsertionTarget, HostOperationsContract.outcomeAfterClose,
            CollectionsContract.answerPage, .viewComponent("grid"), .standardAction("clipboard.write"),
            CollectionsContract.repeatedCallsIntoSession, CollectionsContract.collectionWindow,
            CollectionsContract.loadRange, CollectionsContract.toggleItemActions,
            CollectionsContract.performedActionOutcomes
        ]
        for member in levelTwoOnly {
            XCTAssertTrue(host.permits(member, declaredBy: levelTwo), "\(member)")
            XCTAssertFalse(host.permits(member, declaredBy: levelOne), "\(member)")
        }
        for member in PluginInterfaceContracts.levelOneMembers {
            XCTAssertTrue(host.permits(member, declaredBy: levelOne), "\(member)")
            XCTAssertTrue(host.permits(member, declaredBy: levelTwo), "\(member)")
        }
        XCTAssertFalse(host.permits(CollectionsContract.loadMore, declaredBy: levelTwo),
                       "load_more belonged to collections r1 and r2, not to the promoted revision")
    }

    /// Level 2 names every Host Service by its catalogue ID, as `namespaces`
    /// did (N5): a Level 1 name is refused with the ID to use instead, while
    /// a Level 1 Plugin keeps every Level 1 name.
    func testALevelTwoPluginCallsByIDAndALevelOnePluginByLevelOneName() throws {
        func call(_ name: String) -> PluginRuntimeHostServiceCall {
            PluginRuntimeHostServiceCall(invocationID: "i", actionID: ActionID("a"), name: name, input: .string("x"))
        }
        let levelOne = try manifest(apiLevel: 1), levelTwo = try manifest(apiLevel: 2)

        XCTAssertEqual(try host.resolve(call("clipboard.write"), declaredBy: levelTwo).get().service, .writeClipboard)
        switch try host.resolve(call("write_clipboard"), declaredBy: levelTwo) {
        case .success: XCTFail("A Level 1 name is refused at Level 2")
        case .failure(let error):
            XCTAssertEqual(error.localizedDescription, "Host Service is unavailable: write_clipboard is a Plugin API "
                + "Level 1 name; a Plugin API Level 2 Plugin calls clipboard.write")
        }
        XCTAssertEqual(try host.resolve(call("write_clipboard"), declaredBy: levelOne).get().service, .writeClipboard)
        XCTAssertThrowsError(try host.resolve(call("clipboard.write"), declaredBy: levelOne),
                             "A Level 1 Plugin's helper never sends an ID: it is a broken message, as before")
    }

    // MARK: The helper protocol

    /// The invocation names the Plugin's Level only from Level 2, so a Level
    /// 1 Plugin's invocation keeps its members; `environment.api_level` is
    /// the Host's highest Level for every Plugin.
    func testAnInvocationNamesThePluginsLevelOnlyFromLevelTwo() throws {
        func members(apiLevel: Int) throws -> [String: JSONValue] {
            let invocation = PluginRuntimeInvocation(
                invocationID: "i", pluginID: PluginID("com.example.level-two"), actionID: ActionID("a"),
                commandID: CommandID("level.run"), scriptPath: "run.js", scriptSource: "null", input: .null,
                environment: PluginRuntimeEnvironment(hostVersion: "1.0", preferredLanguage: "en"), apiLevel: apiLevel
            )
            guard case .object(let members) = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(invocation))
            else { throw CocoaError(.coderInvalidValue) }
            XCTAssertEqual(try JSONDecoder().decode(PluginRuntimeInvocation.self, from: JSONEncoder().encode(invocation)),
                           invocation)
            return members
        }
        let levelOne = try members(apiLevel: 1), levelTwo = try members(apiLevel: 2)
        XCTAssertEqual(Set(levelOne.keys), ["type", "protocol_version", "invocation_id", "plugin_id", "action_id",
                                            "command_id", "script_path", "script_source", "input", "environment",
                                            "event", "state"])
        XCTAssertEqual(Set(levelTwo.keys), Set(levelOne.keys).union(["api_level"]))
        XCTAssertEqual(levelTwo["api_level"], .number(2))
        XCTAssertEqual(levelOne["environment"], .object(["api_level": .number(2), "host_version": .string("1.0"),
                                                         "preferred_language": .string("en")]))
    }

    // MARK: Retirement

    /// A Plugin declaring any revision of the three, at any Level, is
    /// refused with the Level its candidate became.
    func testEveryRetiredDeclarationIsRefusedNamingLevelTwo() throws {
        for candidate in PluginInterfaceContracts.candidateHost.candidates {
            for level in [1, 2] {
                let declaring = try manifest(apiLevel: level, declaring: [candidate.declaration] + candidate.requires)
                XCTAssertThrowsError(try host.check(declaring, origin: .installed)) {
                    XCTAssertEqual($0 as? CandidateContractRefusal,
                                   .retired(plugin: "Level Two", declared: candidate.declaration, promotedToLevel: 2))
                    XCTAssertEqual($0.localizedDescription,
                                   "Level Two declares revision \(candidate.revision) of the \(candidate.name) Candidate "
                                    + "Contract, which became Plugin API Level 2. Install a revision of the Plugin that "
                                    + "declares Level 2 instead.")
                }
                if level == 1 {
                    XCTAssertFalse(host.permits(HostServiceCatalogue.catalogueIDsOnly, declaredBy: declaring),
                                   "A retired declaration grants nothing")
                }
            }
        }
    }
}
