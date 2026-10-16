import Foundation
import Network
import XCTest
import SpinnetCore

final class HomebrewTaskProgressTests: XCTestCase {
    func testRealCurlPublishesDownloadProgressThroughTerminalAndTaskLog() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "HomebrewTaskProgressTests.download")
        let listening = expectation(description: "loopback download ready")
        var connections: [NWConnection] = []
        // A paced loopback response produces intermediate percentages. The
        // file protocol can emit only a final bar even with --limit-rate.
        func sendChunk(_ connection: NWConnection, remaining: Int) {
            guard remaining > 0 else { connection.cancel(); return }
            connection.send(content: Data(repeating: 65, count: 32 * 1024), completion: .contentProcessed { error in
                guard error == nil else { return }
                queue.asyncAfter(deadline: .now() + 0.2) { sendChunk(connection, remaining: remaining - 1) }
            })
        }
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            connections.append(connection)
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                let header = "HTTP/1.1 200 OK\r\nContent-Length: 524288\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
                    guard error == nil else { return }
                    sendChunk(connection, remaining: 16)
                })
            }
        }
        listener.start(queue: queue)
        defer { queue.sync { listener.cancel(); connections.forEach { $0.cancel() } } }
        wait(for: [listening], timeout: 3)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let ended = expectation(description: "curl reaped")
        let lock = NSLock(), log = HomebrewTaskLog()
        var liveProgress = false
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["--disable", "--progress-bar", "--noproxy", "*", "--max-time", "8", "--output", "/dev/null", "http://127.0.0.1:\(port)/fixture"],
            environment: HomebrewReadProfile.environment, outputPolicy: .terminal)
        try process.start(output: { data in
            lock.lock(); defer { lock.unlock() }
            log.append(data)
            if log.lines.contains(where: { $0.contains("%") && $0.contains("#") && !$0.contains("100.0%") }),
               HomebrewTaskProcess.startIdentity(process.processIdentifier) != nil { liveProgress = true }
        }, finished: { result in
            XCTAssertEqual(result.outcome, "completed"); ended.fulfill()
        })
        wait(for: [ended], timeout: 12)
        lock.lock(); defer { lock.unlock() }
        XCTAssertTrue(liveProgress, "Download progress must be published before the child finishes")
        log.finish()
        XCTAssertTrue(log.lines.contains { $0.contains("100.0%") })
        XCTAssertTrue(log.lines.allSatisfy { $0.count <= 200 && !$0.contains("\u{1b}") })
    }

    func testTerminalTaskCanBeStoppedAndReapedAfterProgress() throws {
        let outputStarted = expectation(description: "progress received")
        let ended = expectation(description: "stopped child reaped")
        let lock = NSLock()
        var notified = false
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '\\r#### 25.0%%\\r'; while :; do sleep 1; done"],
            environment: HomebrewReadProfile.environment, interruptGrace: 0.05, terminateGrace: 0.05, outputPolicy: .terminal)
        try process.start(output: { data in
            lock.lock(); defer { lock.unlock() }
            if !data.isEmpty && !notified { notified = true; outputStarted.fulfill() }
        }, finished: { result in
            XCTAssertEqual(result.outcome, "stopped"); ended.fulfill()
        })
        wait(for: [outputStarted], timeout: 3)
        process.stop()
        wait(for: [ended], timeout: 3)
        XCTAssertNil(HomebrewTaskProcess.startIdentity(process.processIdentifier))
        XCTAssertTrue(process.ownedProcessIdentities.isEmpty)
    }

    func testDefaultPipePreservesBinaryNativeInputAndOutput() throws {
        let expected = Data([0, 1, 10, 13, 27, 255])
        let ended = expectation(description: "native pipe child reaped")
        let lock = NSLock()
        var output = Data()
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
            environment: HomebrewReadProfile.environment, standardInput: expected)
        try process.start(output: { data in lock.lock(); output.append(data); lock.unlock() }, finished: { result in
            XCTAssertEqual(result.outcome, "completed"); ended.fulfill()
        })
        wait(for: [ended], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(output, expected)
    }

    func testProgressRedactsSplitSecretsAndRetainsUnicodeWithinPublishedBounds() {
        let log = HomebrewTaskLog()
        log.append(Data("API_TOKEN=super".utf8))
        XCTAssertTrue(log.lines.isEmpty)
        log.append(Data("secret\r".utf8))
        XCTAssertEqual(log.lines, ["API_TOKEN=…"])
        log.append(Data("Authorization: Bearer secret\r\n".utf8))
        XCTAssertEqual(log.lines, ["Authorization: …"])
        let frame = Data("\u{1b}[32m▓▒░ ✓ [####] 50.0%\u{1b}[0m\r".utf8)
        for byte in frame { log.append(Data([byte])) }
        XCTAssertEqual(log.lines.last, "▓▒░ ✓ [####] 50.0%")
        log.append(Data((String(repeating: "#", count: 20_000) + "\r100.0%\r\n").utf8))
        XCTAssertEqual(log.lines.last, "100.0%")
        for _ in 0..<30 { log.append(Data("normal line\r\n".utf8)) }
        for _ in 0..<100 { log.append(Data("[####] 50.0%\r".utf8)) }
        XCTAssertEqual(log.lines.count, 20)
        XCTAssertTrue(log.lines.allSatisfy { $0.count <= 200 })
        log.append(Data("[########] 100.0%".utf8)); log.finish(); log.finish()
        XCTAssertEqual(log.lines.last, "[########] 100.0%")
        XCTAssertEqual(log.lines.count, 20)
    }

    func testTerminalOutputEnablesProgressWithoutInteractiveInput() throws {
        let ended = expectation(description: "terminal child reaped")
        let lock = NSLock()
        var output = Data()
        let process = HomebrewTaskProcess(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
            if test -t 1 && test -t 2; then printf 'terminal output\\n'; else printf 'pipe output\\n'; fi
            if test -t 0; then printf 'interactive input\\n'; fi
            if read value; then printf 'unexpected input\\n'; else printf 'input closed\\n'; fi
            """], environment: HomebrewReadProfile.environment, outputPolicy: .terminal)
        try process.start(output: { data in lock.lock(); output.append(data); lock.unlock() }, finished: { result in
            XCTAssertEqual(result.outcome, "completed"); ended.fulfill()
        })
        wait(for: [ended], timeout: 5)
        lock.lock(); let text = String(decoding: output, as: UTF8.self); lock.unlock()
        let log = HomebrewTaskLog(); log.append(Data(text.utf8)); log.finish()
        XCTAssertEqual(log.lines, ["terminal output", "input closed"])
    }

    func testCarriageReturnUpdatesOneVisibleProgressLineBeforeNewline() {
        let log = HomebrewTaskLog()
        log.append(Data("==> Downloading example\n\r#### 25.0%\r".utf8))
        XCTAssertEqual(log.lines, ["==> Downloading example", "#### 25.0%"])
        log.append(Data("######## 50.0%\r".utf8))
        XCTAssertEqual(log.lines, ["==> Downloading example", "######## 50.0%"])
        log.append(Data("################ 100.0%\r\n==> Installing example\n".utf8))
        XCTAssertEqual(log.lines, ["==> Downloading example", "################ 100.0%", "==> Installing example"])
        XCTAssertEqual(log.stage, "installing")
    }
}
