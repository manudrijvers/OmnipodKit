// Copyright © 2026 LoopKit Authors. All rights reserved.

import Foundation

/// Response-only codecs. No radio access or provisioning decisions are made here.
/// Known key widths are corroborated in both official apps. Strict framing/mask
/// checks follow the recovered Android schema, not undocumented iOS tolerance.
enum O5AidResponseError: Error, LocalizedError {
    case malformed(String)
    case rejected(command: String, code: Int)
    case readbackMismatch(String)
    case unconfirmed(command: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .malformed(let reason): return "Invalid O5 response: \(reason)"
        case .rejected(let command, let code): return "\(command) rejected (\(code))"
        case .readbackMismatch(let command): return "\(command) readback differs from the requested value"
        case .unconfirmed(let command, let error):
            return "\(command) outcome unconfirmed; do not assume it was not applied. \(error.localizedDescription)"
        }
    }
}

/// Bounds-checked, unaligned-safe reads; Array also rebases Data slices.
private struct O5AidBytes {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { bytes = Array(data) }
    var remaining: Int { bytes.count - offset }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else {
            throw O5AidResponseError.malformed("truncated field at byte \(offset)")
        }
        defer { offset += count }
        return Data(bytes[offset..<(offset + count)])
    }

    mutating func number(_ count: Int) throws -> UInt32 {
        try take(count).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    mutating func lengthPrefix() throws {
        let length = try number(2)
        guard length <= 32767, Int(length) == remaining else {
            throw O5AidResponseError.malformed("declared body length does not match supported payload")
        }
    }
}

private func o5Number(_ data: Data?) -> UInt32? {
    data.map { $0.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
}

private func o5Fields(_ data: Data, widths: [UInt8: Int]) throws -> [UInt8: Data] {
    var reader = O5AidBytes(data)
    try reader.lengthPrefix()
    var fields: [UInt8: Data] = [:]
    var actualMask: UInt32 = 0
    while reader.remaining > 0 {
        let key = UInt8(try reader.number(1))
        guard let width = widths[key] else {
            // There is no entry length; unknown keys cannot safely be skipped.
            throw O5AidResponseError.malformed("unknown key \(key)")
        }
        guard fields[key] == nil else {
            throw O5AidResponseError.malformed("duplicate key \(key)")
        }
        fields[key] = try reader.take(width)
        actualMask |= UInt32(1) << key
    }
    guard let mask = o5Number(fields[0]), mask == UInt32.max || mask == actualMask else {
        throw O5AidResponseError.malformed("missing or inconsistent attribute mask")
    }
    return fields
}

struct O5CgmInterfaceStatus: CustomStringConvertible {
    let attributeMask: UInt32
    // Raw enum bytes preserve unknown values and distinguish absent from zero.
    let desiredSensorType: UInt8?
    let allowedSensorType: UInt8?
    let managerVersion: UInt8?
    let control: UInt8?

    init(_ data: Data) throws {
        let fields = try o5Fields(data, widths: [0: 4, 1: 1, 2: 1, 3: 1, 4: 1])
        attributeMask = o5Number(fields[0])!
        desiredSensorType = fields[1]?.first
        allowedSensorType = fields[2]?.first
        managerVersion = fields[3]?.first
        control = fields[4]?.first
    }

    var description: String {
        func display(_ value: UInt8?) -> String { value.map { String($0) } ?? "absent" }
        return "Desired sensor: \(display(desiredSensorType)); allowed sensor: \(display(allowedSensorType)); interface version: \(display(managerVersion)); control: \(display(control))"
    }
}

enum O5IdentityComparison: Equatable {
    case same, different, indeterminate
}

/// Specifically the G7 schema; G6 has different widths for some keys.
struct O5G7SensorInfo: CustomStringConvertible {
    let isEmpty: Bool
    let attributeMask: UInt32?
    let sensorType: UInt8?
    let pairingCodeBytes: Data?
    let serialNumberBytes: Data?
    let operatingInterval: UInt16?
    let bluetoothAddressBytes: Data?
    let advertisingReferenceTime: UInt32?
    let lifetime: UInt32?
    let driverVersion: UInt8?
    let addressType: UInt8?

    init(_ data: Data) throws {
        // Observed in issue #1. Preserve this as an explicit empty response,
        // not a valid Android keyed reply or permission to send a SET.
        isEmpty = data == Data([0, 0])
        let fields: [UInt8: Data] = isEmpty ? [:] : try o5Fields(data,
            widths: [0: 4, 1: 1, 2: 4, 3: 12, 4: 2, 5: 6, 6: 4, 7: 4, 8: 1, 9: 1])
        if let type = fields[1]?.first, type != 7 {
            throw O5AidResponseError.malformed("4.1 sensor type is not G7")
        }
        attributeMask = o5Number(fields[0])
        sensorType = fields[1]?.first
        pairingCodeBytes = fields[2]
        serialNumberBytes = fields[3]
        operatingInterval = o5Number(fields[4]).map { UInt16($0) }
        bluetoothAddressBytes = fields[5]
        advertisingReferenceTime = o5Number(fields[6])
        lifetime = o5Number(fields[7])
        driverVersion = fields[8]?.first
        addressType = fields[9]?.first
    }

    var bluetoothAddress: String? {
        bluetoothAddressBytes.map { $0.reversed().map { String(format: "%02X", $0) }.joined(separator: ":") }
    }

    func compare(pairingCode: String, serialNumber: String) -> O5IdentityComparison {
        func digits(_ data: Data, count: Int) -> Bool {
            data.count == count && data.allSatisfy { (48...57).contains($0) }
        }
        let code = Data(pairingCode.utf8), serial = Data(serialNumber.utf8)
        guard !isEmpty, let readCode = pairingCodeBytes, let readSerial = serialNumberBytes,
              digits(code, count: 4), digits(serial, count: 12),
              digits(readCode, count: 4), digits(readSerial, count: 12) else { return .indeterminate }
        return readCode == code && readSerial == serial ? .same : .different
    }

    var description: String {
        if isEmpty { return "Empty sensor-info reply; configured identity is unknown" }
        // Avoid adding sensor identifiers to diagnostic summaries.
        return "G7 info: pairing code \(pairingCodeBytes == nil ? "absent" : "present"), serial \(serialNumberBytes == nil ? "absent" : "present")"
    }
}

/// All common G3.12 fields, plus typed Dexcom payloads. Unknown sensor schemas
/// remain opaque; they cannot be interpreted as a connected Dexcom sensor.
struct O5UnifiedAidStatus: CustomStringConvertible {
    struct G7 {
        let sessionActivationTime: UInt32
        let sessionDuration: Int32
        let sensorTimestamp: Int32
        let algorithmState: UInt8
        let transmitterStatus: UInt8
        let trendRateRaw: Int8
        let trendRateValidity: UInt8
        var trendRate: Int8? { trendRateValidity == 1 ? trendRateRaw : nil }
    }
    struct G6 {
        let activationTime: UInt32
        let trendRate: Int8
        let algorithmState: UInt8
        let transmitterStatus: UInt8
        let lifetime: Int16
    }
    let egvRaw: Int16
    let referenceTime: UInt32
    let totalDailyInsulin: UInt16
    let loopState: UInt8
    let iobRaw: Int32
    let podTime: UInt32
    let statusFlags: UInt8
    let stateFlags: UInt8
    let cgmType: UInt8
    let cgmData: Data
    let g7: G7?
    let g6: G6?

    var egv: Int16? { egvRaw == 0 ? nil : egvRaw }
    var iobMicroUnits: Int32? { iobRaw == Int32.min ? nil : iobRaw }
    var egvAge: TimeInterval? {
        guard egv != nil, referenceTime > 0, podTime >= referenceTime else { return nil }
        return TimeInterval(podTime - referenceTime)
    }
    var algorithmReady: Bool { stateFlags & 1 != 0 }
    var podActive: Bool { stateFlags & 2 != 0 }
    var activityMode: Bool { stateFlags & 4 != 0 }
    var limitedMode: Bool { stateFlags & 8 != 0 }
    var isManual: Bool { loopState == 1 }
    var historyWrittenOnAlarm: Bool { statusFlags & 1 != 0 }
    var lastHistoryRecordRequested: Bool { statusFlags & 2 != 0 }
    // Status bits 2/3 depend on parsing scheme. Keep raw bits, without assuming
    // the incident's firmware uses the ADR-alert interpretation.
    var unknownStatusBits: UInt8 { statusFlags & 0xf0 }

    init(_ data: Data) throws {
        var r = O5AidBytes(data)
        try r.lengthPrefix()
        egvRaw = Int16(bitPattern: UInt16(try r.number(2)))
        referenceTime = try r.number(4)
        totalDailyInsulin = UInt16(try r.number(2))
        loopState = UInt8(try r.number(1))
        iobRaw = Int32(bitPattern: try r.number(4))
        podTime = try r.number(4)
        statusFlags = UInt8(try r.number(1))
        stateFlags = UInt8(try r.number(1))
        guard stateFlags & 0xf0 == 0 else { throw O5AidResponseError.malformed("reserved AID state flags") }
        cgmType = UInt8(try r.number(1))
        let length = Int(try r.number(2))
        guard length == r.remaining else { throw O5AidResponseError.malformed("CGM data length mismatch") }
        cgmData = try r.take(length)
        let knownLengths: [UInt8: Int] = [0: 0, 4: 9, 7: 16, 2: 7, 3: 7, 5: 7,
                                          8: 31, 9: 31, 10: 31, 11: 31, 12: 31]
        if let expected = knownLengths[cgmType], expected != length {
            throw O5AidResponseError.malformed("CGM payload size disagrees with sensor type")
        }
        var c = O5AidBytes(cgmData)
        if cgmType == 7 {
            g7 = try G7(sessionActivationTime: c.number(4), sessionDuration: Int32(bitPattern: c.number(4)),
                sensorTimestamp: Int32(bitPattern: c.number(4)), algorithmState: UInt8(c.number(1)),
                transmitterStatus: UInt8(c.number(1)), trendRateRaw: Int8(bitPattern: UInt8(c.number(1))),
                trendRateValidity: UInt8(c.number(1)))
        } else { g7 = nil }
        if cgmType == 4 {
            g6 = try G6(activationTime: c.number(4), trendRate: Int8(bitPattern: UInt8(c.number(1))),
                algorithmState: UInt8(c.number(1)), transmitterStatus: UInt8(c.number(1)),
                lifetime: Int16(bitPattern: UInt16(c.number(2))))
        } else { g6 = nil }
    }

    /// A narrow diagnostic observation, not a declaration of successful pairing,
    /// safe initialization, or continued operation. Threshold chosen by caller.
    func hasRecentG7Reading(maxAge: TimeInterval) -> Bool {
        guard maxAge >= 0, maxAge.isFinite, g7 != nil, let age = egvAge else { return false }
        return (39...401).contains(egvRaw) && age <= maxAge
    }

    var description: String {
        let age = egvAge.map { "\(Int($0)) s" } ?? "unavailable"
        let iob = iobMicroUnits.map { "\($0) micro-units" } ?? "not provided"
        var lines = ["EGV: \(egvRaw), age: \(age)", "TDI: \(totalDailyInsulin); IOB: \(iob)",
                     "Loop state: \(loopState); ready: \(algorithmReady); active: \(podActive)",
                     "Activity: \(activityMode); Limited: \(limitedMode)",
                     "Status flags: \(statusFlags); state flags: \(stateFlags); CGM type: \(cgmType)"]
        if let sensor = g7 {
            lines.append("G7 algorithm state: \(sensor.algorithmState); transmitter status: \(sensor.transmitterStatus)")
            lines.append("G7 trend rate: \(sensor.trendRate.map { String($0) } ?? "not valid")")
            lines.append("G7 session start: \(sensor.sessionActivationTime); duration: \(sensor.sessionDuration); sensor timestamp: \(sensor.sensorTimestamp)")
        }
        return lines.joined(separator: "\n")
    }
}

enum O5AidResponseValidation {
    static func extendedSet(command: (data: Data, responsePrefix: String),
                            send: (Data, String) throws -> Data) throws -> Data {
        try exchange(command: command.responsePrefix,
                     send: { try send(command.data, command.responsePrefix) },
                     validate: { try extendedSet($0, command: command.responsePrefix) })
    }

    static func setGet(command: (data: Data, responsePrefix: String),
                       send: (Data, String) throws -> Data) throws -> Data {
        try exchange(command: command.responsePrefix,
                     send: { try send(command.data, command.responsePrefix) },
                     validate: { try setGet($0, request: command.data, responsePrefix: command.responsePrefix) })
    }

    static func extendedSet(_ response: Data, command: String) throws {
        let bytes = Array(response)
        let digits = bytes.first == 45 ? Array(bytes.dropFirst()) : bytes
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
              let string = String(data: response, encoding: .ascii), let code = Int(string),
              String(code) == string else { throw O5AidResponseError.malformed("\(command) result code") }
        guard code == 0 else { throw O5AidResponseError.rejected(command: command, code: code) }
    }

    /// Exact value comparison for the existing SET+GET format. The expected
    /// value is taken from the actual request, including binary values.
    static func setGet(_ response: Data, request: Data, responsePrefix: String) throws {
        let start = Data(("S" + responsePrefix).utf8)
        let end = Data((",G" + responsePrefix.dropLast()).utf8)
        guard responsePrefix.last == "=", request.count >= start.count + end.count,
              request.starts(with: start), request.suffix(end.count) == end else {
            throw O5AidResponseError.malformed("invalid SET+GET validation request")
        }
        let expected = request.dropFirst(start.count).dropLast(end.count)
        guard response == expected else { throw O5AidResponseError.readbackMismatch(responsePrefix) }
    }

    /// No retry here. A transport exception may follow an applied write. Keep
    /// that distinct from an explicit negative result or mismatched readback.
    static func exchange(command: String, send: () throws -> Data,
                         validate: (Data) throws -> Void) throws -> Data {
        let response: Data
        do { response = try send() }
        catch { throw O5AidResponseError.unconfirmed(command: command, underlying: error) }
        try validate(response)
        return response
    }
}
