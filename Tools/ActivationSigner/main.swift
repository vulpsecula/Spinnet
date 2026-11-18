import CryptoKit
import Foundation
import SpinnetCore

// Makes Spinnet's signing key and signs Activation Codes with it. The private
// key never enters the repository: it is read from the file `--key` names, or
// from SPINNET_ACTIVATION_KEY. Only its public key is committed, in
// ActivationCodeVerifier.officialPublicKeys.

let usage = """
usage: spinnet-activation-signer generate-key --out FILE
       spinnet-activation-signer public-key [--key FILE]
       spinnet-activation-signer sign [--key FILE] [--count N] [--serial HEX] [--issued YYYY-MM-DD]
       spinnet-activation-signer verify CODE

generate-key writes a new private key to FILE (mode 600, never overwritten) and
prints its public key. sign prints one Activation Code per line, each after its
serial and a tab; serials are random unless --serial is given. verify checks a
code against the public keys Official Builds trust.
"""

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func option(_ name: String, in arguments: [String]) throws -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard arguments.indices.contains(index + 1) else { throw Failure("\(name) needs a value") }
    return arguments[index + 1]
}

func loadPrivateKey(_ arguments: [String]) throws -> Curve25519.Signing.PrivateKey {
    let path = try option("--key", in: arguments) ?? ProcessInfo.processInfo.environment["SPINNET_ACTIVATION_KEY"]
    guard let path else { throw Failure("pass --key FILE or set SPINNET_ACTIVATION_KEY") }
    let text = try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
    do { return try ActivationSigningKey.privateKey(from: text) }
    catch { throw Failure("\(path) does not hold a Spinnet activation private key") }
}

func run(_ arguments: [String]) throws {
    switch arguments.first {
    case "generate-key":
        guard let path = try option("--out", in: arguments) else { throw Failure("generate-key needs --out FILE") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("\(url.path) already exists; a key is never overwritten")
        }
        let key = Curve25519.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data((ActivationSigningKey.text(for: key) + "\n").utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw Failure("could not write \(url.path)")
        }
        print(ActivationSigningKey.text(for: key.publicKey))
    case "public-key":
        print(ActivationSigningKey.text(for: try loadPrivateKey(arguments).publicKey))
    case "sign":
        let key = try loadPrivateKey(arguments)
        let signer = ActivationCodeSigner(privateKey: key)
        let check = ActivationCodeVerifier(trustedKeys: [key.publicKey])
        let count = try option("--count", in: arguments).map {
            guard let count = Int($0), count > 0 else { throw Failure("--count must be a positive number") }
            return count
        } ?? 1
        let fixedSerial = try option("--serial", in: arguments).map {
            guard let serial = UInt64($0.replacingOccurrences(of: "-", with: ""), radix: 16) else {
                throw Failure("--serial must be hexadecimal")
            }
            return serial
        }
        if fixedSerial != nil, count != 1 { throw Failure("--serial signs one code") }
        let issued = try option("--issued", in: arguments).map {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            guard let date = formatter.date(from: $0) else { throw Failure("--issued must be YYYY-MM-DD") }
            return date
        } ?? Date()
        for _ in 0..<count {
            let serial = fixedSerial ?? UInt64.random(in: 1...UInt64.max)
            let text = try signer.sign(serial: serial, issued: issued, edition: .lifetime)
            let code = try check.verify(text)
            print("\(code.displaySerial)\t\(text)")
        }
    case "verify":
        guard arguments.count >= 2 else { throw Failure("verify needs a CODE") }
        let code = try ActivationCodeVerifier.official.verify(arguments.dropFirst().joined(separator: " "))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        print("valid \(code.edition) code, serial \(code.displaySerial), issued \(formatter.string(from: code.issued))")
    case "-h", "--help":
        print(usage)
    default:
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        exit(2)
    }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
