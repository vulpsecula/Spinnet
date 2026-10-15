import Foundation
import Carbon
import SpinnetCore

/// Fixed dictionary events, addressed to an already-running process. All sends
/// share one monotonic deadline; no script, launch, polling or transport retry.
struct SpotifyControlAppleEvents {
    typealias Send = (NSAppleEventDescriptor, TimeInterval) throws -> NSAppleEventDescriptor
    private let target: NSAppleEventDescriptor
    private let send: Send
    private let now: () -> TimeInterval
    private enum ObservationUnavailable: Error { case deadline, malformed }

    init(target: NSAppleEventDescriptor,
         send: @escaping Send = { event, timeout in
             try event.sendEvent(options: [.waitForReply, .neverInteract, .init(rawValue: UInt(kAEDontReconnect))], timeout: timeout)
         }, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.target = target; self.send = send; self.now = now
    }

    func perform(_ request: AppleEventRequest) throws -> JSONValue {
        guard request.bundleID == SpotifyPlayback.bundleID, request.argument.isEmpty,
              SpotifyControls.operationNames.contains(request.handler) else {
            throw PluginHostServiceError.externalAppOperationUnsupported("Unsupported Spotify control")
        }
        let key = request.handler == "set_volume" ? "volume" : "delta"
        _ = try SpotifyControls.integerArgument(operation: request.handler,
            arguments: request.integerArgument.map { [key: .number(Double($0))] } ?? [:])
        let deadline = now() + 3
        do {
            switch request.handler {
            case "play_pause":
                _ = try event(eventClass: 0x73706679, eventID: 0x506c5073, deadline: deadline)
                return .null
            case "next_checked": return try nextChecked(deadline: deadline)
            case "set_volume", "adjust_volume":
                let target: Int
                if request.handler == "adjust_volume" {
                    target = min(100, max(0, try volume(deadline: deadline) + request.integerArgument!))
                } else { target = request.integerArgument! }
                _ = try event(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAESetData),
                    property: Self.property(0x70566f6c), value: NSAppleEventDescriptor(int32: Int32(target)), deadline: deadline)
                return .object(["volume": .number(Double(try volume(deadline: deadline)))])
            default: return .object(["volume": .number(Double(try volume(deadline: deadline)))])
            }
        } catch is ObservationUnavailable {
            throw PluginHostServiceError.failed("Spotify did not return a valid answer within the 3-second control deadline")
        }
    }

    private func volume(deadline: TimeInterval) throws -> Int {
        let answer = try event(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            property: Self.property(0x70566f6c), deadline: deadline)
        guard [DescType(typeSInt16), DescType(typeSInt32), DescType(typeSInt64)].contains(answer.descriptorType),
              let text = answer.stringValue, let value = Int(text), (0...100).contains(value) else {
            throw ObservationUnavailable.malformed
        }
        return value
    }

    private func nextChecked(deadline: TimeInterval) throws -> JSONValue {
        func result(_ value: String) -> JSONValue { .object(["outcome": .string(value)]) }
        let state = try event(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
            property: Self.property(0x70506c53), deadline: deadline)
        guard state.descriptorType == DescType(typeEnumerated) else { throw ObservationUnavailable.malformed }
        if state.enumCodeValue == 0x6b505353 { return result("stopped") }
        guard [OSType(0x6b505350), OSType(0x6b505370)].contains(state.enumCodeValue) else { throw ObservationUnavailable.malformed }
        guard let before = try trackID(deadline: deadline) else { return result("no_current_track") }
        do {
            _ = try event(eventClass: 0x73706679, eventID: 0x4e657874, deadline: deadline)
        } catch is ObservationUnavailable { return result("unconfirmed") }
        catch let error as NSError where error.code == -1712 { return result("unconfirmed") }
        // Spotify can publish its new track after acknowledging Next. Observe
        // once after a short fixed grace period, only inside the same budget.
        guard deadline - now() > 0.15 else { return result("unconfirmed") }
        Thread.sleep(forTimeInterval: 0.15)
        do {
            guard let after = try trackID(deadline: deadline) else { return result("unconfirmed") }
            return result(before == after ? "unconfirmed" : "changed")
        } catch is ObservationUnavailable { return result("unconfirmed") }
        catch let error as NSError where error.code == -1712 { return result("unconfirmed") }
    }

    private func trackID(deadline: TimeInterval) throws -> String? {
        let answer: NSAppleEventDescriptor
        do {
            answer = try event(eventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                property: Self.property(0x49442020, container: Self.property(0x7054726b)), deadline: deadline)
        } catch let error as NSError where error.code == -1728 { return nil }
        if answer.descriptorType == DescType(typeNull) || (answer.descriptorType == DescType(typeType) && answer.typeCodeValue == 0x6d736e67) { return nil }
        guard [DescType(typeUnicodeText), DescType(typeUTF8Text), DescType(typeChar)].contains(answer.descriptorType),
              let id = answer.stringValue, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 2048 else { throw ObservationUnavailable.malformed }
        return id
    }

    private func event(eventClass: AEEventClass, eventID: AEEventID, property: NSAppleEventDescriptor? = nil,
                       value: NSAppleEventDescriptor? = nil, deadline: TimeInterval) throws -> NSAppleEventDescriptor {
        let remaining = deadline - now()
        guard remaining > 0 else { throw ObservationUnavailable.deadline }
        let request = NSAppleEventDescriptor(eventClass: eventClass, eventID: eventID, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let property { request.setParam(property, forKeyword: AEKeyword(keyDirectObject)) }
        if let value { request.setParam(value, forKeyword: AEKeyword(keyAEData)) }
        let reply = try send(request, remaining)
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value))
        }
        guard now() <= deadline else { throw ObservationUnavailable.deadline }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) ?? reply
    }

    private static func property(_ code: OSType, container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor.record()
        descriptor.setDescriptor(NSAppleEventDescriptor(typeCode: OSType(cProperty)), forKeyword: AEKeyword(keyAEDesiredClass))
        descriptor.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
        descriptor.setDescriptor(NSAppleEventDescriptor(typeCode: code), forKeyword: AEKeyword(keyAEKeyData))
        descriptor.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return descriptor.coerce(toDescriptorType: DescType(typeObjectSpecifier))!
    }
}
