//
//  O5AidCommands.swift
//  OmnipodKit
//
//  Created for O5 AID setup commands sent between AssignAddress and SetupPod.
//  These use an ASCII key-value protocol different from legacy Omnipod commands.
//
//  Command formats:
//    SET+GET: S[feature].[attr]=[data],G[feature].[attr]
//    GET only: G[feature].[attr]
//    Extended SET: SE[feature].[attr]=[data]
//
//  Response formats:
//    SET+GET response: [feature].[attr]=[data]
//    GET response: [feature].[attr]=[data]
//    Extended SET response: ES[feature].[attr]=[data]
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation

/// Constructs O5 AID command payloads for the pre-SetupPod activation sequence.
///
/// These commands use plain ASCII key-value format (NOT the SLPE length-prefixed encoding
/// used by standard S0.0= commands). The data values can be ASCII text
/// (e.g., "8" for DIA) or raw binary bytes (e.g., 0x0003000E00 for TDI).
///
struct O5AidCommands {

    // MARK: - AID Payload Construction
    //
    // AID commands use plain ASCII key-value format with NO length prefix.
    // This is different from standard Omnipod SLPE (S0.0=...,G0.0) which uses
    // 2-byte big-endian length prefixes via StringLengthPrefixEncoding.formatKeys().
    //
    // Confirmed wire format is: ASCII key + data + ASCII suffix
    // For BINARY commands, data is raw bytes. For ASCII commands, data is text.

    /// Constructs a SET+GET command payload with ASCII text data.
    ///
    /// Wire format: `S[f].[a]=[ASCII data],G[f].[a]`
    static func setGetPayload(feature: String, attribute: String, data: String) -> Data {
        let command = "S\(feature).\(attribute)=\(data),G\(feature).\(attribute)"
        return Data(command.utf8)
    }

    /// Constructs a SET+GET command payload with raw binary data.
    ///
    /// Wire format: `S[f].[a]=` + [raw binary bytes] + `,G[f].[a]`
    static func setGetPayload(feature: String, attribute: String, binaryData: Data) -> Data {
        let prefix = Data("S\(feature).\(attribute)=".utf8)
        let suffix = Data(",G\(feature).\(attribute)".utf8)
        return prefix + binaryData + suffix
    }

    /// Constructs a GET-only command payload.
    ///
    /// Wire format: `G[f].[a]`
    static func getPayload(feature: String, attribute: String) -> Data {
        let command = "G\(feature).\(attribute)"
        return Data(command.utf8)
    }

    /// Constructs an Extended SET command payload with ASCII text data.
    ///
    /// Wire format: `SE[f].[a]=[ASCII data]`
    static func extendedSetPayload(feature: String, attribute: String, data: String) -> Data {
        let command = "SE\(feature).\(attribute)=\(data)"
        return Data(command.utf8)
    }

    /// Constructs an Extended SET command payload with raw binary data.
    ///
    /// Wire format: `SE[f].[a]=` + [raw binary bytes]
    static func extendedSetPayload(feature: String, attribute: String, binaryData: Data) -> Data {
        let prefix = Data("SE\(feature).\(attribute)=".utf8)
        return prefix + binaryData
    }

    /// Returns the expected response prefix for a SET+GET or GET-only command.
    /// Response format: `[feature].[attribute]=`
    static func responsePrefix(feature: String, attribute: String) -> String {
        return "\(feature).\(attribute)="
    }

    /// Returns the expected response prefix for an Extended SET command.
    /// Response format: `ES[feature].[attribute]=`
    static func extendedSetResponsePrefix(feature: String, attribute: String) -> String {
        return "ES\(feature).\(attribute)="
    }

    // MARK: - AID Command Definitions

    /// Command 1: UTC time setting.
    /// Sends: `SE255.2=[unix_timestamp]`
    /// Response: `ES255.2=0`
    struct UtcCommand {
        static let feature = "255"
        static let attribute = "2"

        /// Creates the SLPE-wrapped payload for the UTC command.
        /// - Parameter timestamp: Unix timestamp (defaults to current time)
        /// - Returns: Tuple of (payload, responsePrefix)
        static func payload(timestamp: UInt64? = nil) -> (data: Data, responsePrefix: String) {
            let ts = timestamp ?? UInt64(Date().timeIntervalSince1970)
            let data = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, data: "\(ts)")
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (data, prefix)
        }
    }

    /// Command 2: TDI (Therapy Delivery Information) configuration.
    /// Binary wire format: `S3.2=` + [0x00,0x03,0x00,0x0E,0x00] + `,G3.2` (15 bytes)
    /// Response: `3.2=` + [5 binary bytes echoed back]
    ///
    /// The 5 data bytes: version(00), therapy type(03), delivery mode(00), bolus speed(0E=14U TDI), reserved(00).
    struct TdiCommand {
        static let feature = "3"
        static let attribute = "2"
        static let defaultBinaryData = Data([0x00, 0x03, 0x00, 0x0E, 0x00])

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: defaultBinaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 3: Target BG profile — 48 half-hour BG target values for a 24-hour day.
    /// Binary wire format: `S3.1=` + [0x00,0xC0] + [48 x 4-byte-BE targets] + `,G3.1` (204 bytes)
    /// Response: `3.1=` + [194 binary bytes echoed back]
    ///
    /// The 0x00C0 prefix = 192 = 48 * 4 (byte count of the 48 target entries).
    /// Each target is a 4-byte big-endian value in mg/dL (e.g., 0x0000006E = 110).
    struct TargetBgProfileCommand {
        static let feature = "3"
        static let attribute = "1"
        static let defaultTargetMgdl: UInt32 = 110  // 0x006e

        static func payload(targets: [UInt32]? = nil) -> (data: Data, responsePrefix: String) {
            let targetValues = targets ?? Array(repeating: defaultTargetMgdl, count: 48)
            assert(targetValues.count == 48, "Target BG profile must have exactly 48 half-hour entries")

            var binaryData = Data()
            let totalBytes = UInt16(targetValues.count * 4)  // 192 = 0x00C0
            binaryData.appendBigEndian(totalBytes)
            for target in targetValues {
                binaryData.appendBigEndian(target)
            }
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 4: DIA (Duration of Insulin Action) setting.
    /// Sends: `S3.9=8,G3.9`
    /// Response: `3.9=8`
    ///
    /// Value "8" likely represents 8 half-hours = 4 hours DIA, but could be the raw value.
    struct DiaCommand {
        static let feature = "3"
        static let attribute = "9"
        static let defaultValue = "8"

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 5: EGV (Estimated Glucose Value) configuration.
    /// Sends: `S3.7=3670015,G3.7`
    /// Response: `3.7=3670015`
    ///
    /// The value `3670015` is a bitfield or composite config value for CGM/EGV settings.
    struct EgvCommand {
        static let feature = "3"
        static let attribute = "7"
        static let defaultValue = "3670015"

        static func payload(value: String = defaultValue) -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.setGetPayload(feature: feature, attribute: attribute, data: value)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 6: Algorithm Insulin History — sent 3 times with 24 records each.
    /// Binary wire format: `SE2.1=` + [0x00,0xA8] + [168 raw bytes] (176 bytes)
    /// Response: `ES2.1=0`
    ///
    /// The 0x00A8 prefix = 168 = 24 * 7 (byte count of the 24 history records).
    /// Each record is 7 bytes. For initial setup with no history, all records are zeros.
    struct AlgorithmInsulinHistoryCommand {
        static let feature = "2"
        static let attribute = "1"
        static let recordsPerBatch = 24
        static let bytesPerRecord = 7

        static func payload(records: [Data]? = nil) -> (data: Data, responsePrefix: String) {
            let recordData: [Data]
            if let records = records {
                assert(records.count == recordsPerBatch, "Must have exactly \(recordsPerBatch) records")
                recordData = records
            } else {
                // Default: 24 zero records of 7 bytes each
                recordData = Array(repeating: Data(count: bytesPerRecord), count: recordsPerBatch)
            }

            let totalBytes = UInt16(recordsPerBatch * bytesPerRecord)  // 168 = 0x00A8
            var binaryData = Data()
            binaryData.appendBigEndian(totalBytes)
            for record in recordData {
                assert(record.count == bytesPerRecord, "Each record must be exactly \(bytesPerRecord) bytes")
                binaryData.append(record)
            }
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7 (Gen1): AID Pod Status query.
    /// Sends: `G3.11`
    /// Response: `3.11=[fixed 30-byte payload: 2-byte length + 28-byte body]`
    ///
    /// Used for Gen1 pods (firmware majorVersion < 7).
    struct AidPodStatusCommand {
        static let feature = "3"
        static let attribute = "11"

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Command 7 (non-Gen1): Unified AID Pod Status query.
    /// Sends: `G3.12`
    /// Response: `3.12=[29 bytes of AID status data]`
    ///
    /// Used for non-Gen1 pods (firmware majorVersion >= 7).
    struct UnifiedAidPodStatusCommand {
        static let feature = "3"
        static let attribute = "12"

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    // MARK: - CGM (Dexcom G7 connected directly to the pod)
    //
    // CGM values are binary key/value records: [u16 BE body length] then repeated [key u8][value],
    // with a fixed value size per key and no per-entry length.

    /// CGM interface manager (`4.2`).
    /// Sends: `SE4.2=` + [0x00,0x04, 0x04,0x00, 0x01,0x07] — control (key 4) = enable (0), sensor type (key 1) = G7 (7)
    /// Response: `ES4.2=[result code]`
    ///
    /// The two entries are in the order the Android O5 app most likely emits them (unsorted HashMap).
    struct CgmInterfaceCommand {
        static let feature = "4"
        static let attribute = "2"
        static let enableDexcomG7 = Data([0x00, 0x04, 0x04, 0x00, 0x01, 0x07])

        static func payload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: enableDexcomG7)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func getPayload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Dexcom G7 sensor info (`4.1`).
    /// Sends: `SE4.1=` + [0x00,0x12] + [0x02 + 4-digit pairing code] + [0x03 + 12-digit serial number], both ASCII
    /// Response: `ES4.1=[result code]`
    struct G7SensorInfoCommand {
        static let feature = "4"
        static let attribute = "1"

        static func payload(pairingCode: String, serialNumber: String) -> (data: Data, responsePrefix: String) {
            assert(pairingCode.utf8.count == 4 && serialNumber.utf8.count == 12, "G7 pairing code must be 4 and serial 12 characters")

            let body = Data([0x02]) + Data(pairingCode.utf8) + Data([0x03]) + Data(serialNumber.utf8)
            var binaryData = Data()
            binaryData.appendBigEndian(UInt16(body.count))
            binaryData.append(body)
            let payload = O5AidCommands.extendedSetPayload(feature: feature, attribute: attribute, binaryData: binaryData)
            let prefix = O5AidCommands.extendedSetResponsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }

        static func getPayload() -> (data: Data, responsePrefix: String) {
            let payload = O5AidCommands.getPayload(feature: feature, attribute: attribute)
            let prefix = O5AidCommands.responsePrefix(feature: feature, attribute: attribute)
            return (payload, prefix)
        }
    }

    /// Describes an Extended SET result code response body (e.g. "0" from `ES4.1=0`).
    static func extendedSetResultDescription(_ response: Data) -> String {
        let code = String(data: response, encoding: .ascii) ?? response.hexadecimalString
        switch Int(code) {
        case 0: return "\(code) (success)"
        case -5: return "\(code) (invalid arguments)"
        case -14: return "\(code) (not supported)"
        case -19: return "\(code) (busy)"
        default: return code
        }
    }
}

/// The CGM fields of a Unified AID Pod Status (`3.12`) response body, all big-endian:
///
///     [0] u16 length of the bytes that follow   [2] s16 EGV in mg/dL (0 = none)   [4] u32 EGV time (pod clock seconds)
///     [8] u16 TDI   [10] u8 loop state (1 = manual, 2 = automated)   [11] s32 IOB   [15] u32 pod time (pod clock seconds)
///     [19] u8 status flags   [20] u8 state flags   [21] u8 CGM type (4 = G6, 7 = G7)   [22] u16 CGM data length   [24] CGM data
///
/// Dexcom G7 CGM data (16 bytes): u32 session activation time, s32 session duration, s32 sensor timestamp,
/// u8 algorithm state, u8 transmitter status, s8 trend rate, u8 trend rate valid (1 = valid).
struct O5AidCgmStatus: CustomStringConvertible {
    let egv: Int16
    let egvAge: TimeInterval
    let loopState: UInt8
    let cgmType: UInt8
    let cgmData: Data

    init?(_ response: Data) {
        let data = Data(response) // rebase indices of the response slice
        guard data.count >= 24, Int(data[0...].toBigEndian(UInt16.self)) == data.count - 2 else {
            return nil
        }
        egv = data[2...].toBigEndian(Int16.self)
        egvAge = TimeInterval(data[15...].toBigEndian(UInt32.self)) - TimeInterval(data[4...].toBigEndian(UInt32.self))
        loopState = data[10]
        cgmType = data[21]
        cgmData = data.subdata(in: 24..<data.count)
        guard cgmData.count == Int(data[22...].toBigEndian(UInt16.self)) else {
            return nil
        }
    }

    var description: String {
        var lines = [
            egv == 0 ? "EGV: none" : "EGV: \(egv) mg/dL, \(Int(egvAge)) s old",
            "Loop state: \(loopState)",
            "CGM type: \(cgmType)",
        ]
        if cgmType == 7 && cgmData.count == 16 {
            let sessionStart = cgmData[0...].toBigEndian(UInt32.self)
            let sessionDuration = cgmData[4...].toBigEndian(Int32.self)
            let sensorTimestamp = cgmData[8...].toBigEndian(Int32.self)
            let trendRate = cgmData[15] == 1 ? String(Int8(bitPattern: cgmData[14])) : "not valid"
            lines += [
                "G7 algorithm state: \(cgmData[12])",
                "G7 transmitter status: \(cgmData[13])",
                "G7 trend rate: \(trendRate)",
                "G7 session start: \(sessionStart), duration: \(sessionDuration), sensor timestamp: \(sensorTimestamp)",
            ]
        } else {
            lines.append("CGM data: \(cgmData.hexadecimalString)")
        }
        return lines.joined(separator: "\n")
    }
}
