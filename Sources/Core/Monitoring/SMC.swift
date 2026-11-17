//
//  SMC.swift
//  AppleSMC / VirtualSMC user-client reader.
//
//  Layout note: the parameter block below is byte-identical to the one used by
//  beltex/SMCKit (MIT), reconstructed from Apple's PowerManagement PrivateLib.
//  Verified on this machine: stride is 80 and every selector behaves as
//  documented. Do not reorder fields or change their widths.
//
//  Calling convention: IOConnectCallStructMethod always uses method index 2
//  (kSMCHandleYPCEvent). The actual operation is carried in `data8`.
//

import Foundation
import IOKit

// MARK: - Parameter block

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

enum SMCSelector: UInt8 {
    case handleYPCEvent = 2
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

enum SMCErrorCode: UInt8 {
    case success = 0
    case badIndex = 5
    case keyNotFound = 132
}

func smcFourCharCode(_ string: String) -> UInt32 {
    var code: UInt32 = 0
    for byte in string.utf8.prefix(4) { code = (code << 8) | UInt32(byte) }
    return code
}

func smcFourCharString(_ code: UInt32) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                 UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes.filter { $0 != 0 }, encoding: .ascii) ?? ""
}

// MARK: - Decoded value

/// A raw SMC value plus decoders for every encoding Intel Macs and
/// VirtualSMC plug-ins are known to use.
public struct SMCValue {
    public let code: String
    public let type: String
    public let bytes: [UInt8]

    public init(code: String, type: String, bytes: [UInt8]) {
        self.code = code
        self.type = type
        self.bytes = bytes
    }

    /// Unsigned fixed point, 14 integer bits + 2 fraction — Intel fan tachometers.
    public var fanRPM: Double? {
        guard type == "fpe2", bytes.count >= 2 else { return nil }
        return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0
    }

    /// Signed fixed point, 8 + 8 — the classic Intel temperature encoding.
    public var temperature: Double? {
        guard type == "sp78", bytes.count >= 2 else { return nil }
        let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        return Double(raw) / 256.0
    }

    /// 32-bit little-endian float — Apple Silicon and SMCSuperIO channels.
    public var float: Double? {
        guard type == "flt ", bytes.count >= 4 else { return nil }
        let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: raw))
    }

    public var uint: Double? {
        switch type {
        case "ui8 ", "si8 ":
            guard !bytes.isEmpty else { return nil }
            return Double(bytes[0])
        case "ui16", "si16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32", "si32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "ui64":
            guard bytes.count >= 8 else { return nil }
            var value: UInt64 = 0
            for index in 0..<8 { value = (value << 8) | UInt64(bytes[index]) }
            return Double(value)
        default:
            return nil
        }
    }

    /// Numeric reading whatever encoding the firmware chose for this key.
    public var number: Double? {
        if let value = uint { return value }
        if let value = float { return value }
        if let value = temperature { return value }
        if let value = fanRPM { return value }
        return nil
    }

    /// Text keys such as fan labels (`F0ID`).
    public var text: String? {
        guard type == "ch8*" else { return nil }
        let string = String(bytes: bytes.prefix { $0 != 0 && $0 != 0x20 }, encoding: .ascii) ?? ""
        return string.isEmpty ? nil : string
    }
}

// MARK: - Client

/// Long-lived connection to the SMC service.
///
/// Opening the IOKit connection is expensive relative to a read, so it stays
/// open for the process lifetime and serialises access behind a lock.
public final class SMCClient {
    public static let shared = SMCClient()

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var isOpen = false
    private var typeCache: [String: (UInt32, String)] = [:]

    private init() {}

    /// Locates `AppleSMC` (real hardware or VirtualSMC) and opens a connection.
    /// Returns false on Macs whose firmware exposes no SMC at all.
    @discardableResult
    public func open() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isOpen else { return true }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        var handle: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &handle) == kIOReturnSuccess else { return false }

        connection = handle
        isOpen = true
        return true
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return }
        IOServiceClose(connection)
        connection = 0
        isOpen = false
    }

    public var isAvailable: Bool { isOpen }

    /// Key count published by the firmware (`#KEY`).
    public var keyCount: Int {
        lock.lock(); defer { lock.unlock() }
        guard isOpen, let value = readKeyLocked("#KEY")?.number else { return 0 }
        return Int(value)
    }

    /// Key name at `index`, for enumeration.
    public func key(at index: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard isOpen else { return nil }
        var input = SMCParamStruct()
        input.data8 = SMCSelector.getKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        guard let output = callLocked(&input),
              output.result == SMCErrorCode.success.rawValue else { return nil }
        let name = smcFourCharString(output.key)
        return name.isEmpty ? nil : name
    }

    /// Declared size and encoding of a key, cached because it is immutable.
    private func infoLocked(for key: String) -> (UInt32, String)? {
        if let cached = typeCache[key] { return cached }
        guard isOpen else { return nil }
        var input = SMCParamStruct()
        input.key = smcFourCharCode(key)
        input.data8 = SMCSelector.getKeyInfo.rawValue
        guard let output = callLocked(&input),
              output.result == SMCErrorCode.success.rawValue,
              output.keyInfo.dataSize > 0 else { return nil }
        let info = (output.keyInfo.dataSize, smcFourCharString(output.keyInfo.dataType))
        typeCache[key] = info
        return info
    }

    public func info(for key: String) -> (UInt32, String)? {
        lock.lock(); defer { lock.unlock() }
        return infoLocked(for: key)
    }

    /// Read a single key. `nil` when absent or unreadable.
    public func read(_ key: String) -> SMCValue? {
        lock.lock(); defer { lock.unlock() }
        return readKeyLocked(key)
    }

    public func readNumber(_ key: String) -> Double? {
        read(key)?.number
    }

    private func readKeyLocked(_ key: String) -> SMCValue? {
        guard isOpen, let (size, type) = infoLocked(for: key) else { return nil }

        var input = SMCParamStruct()
        input.key = smcFourCharCode(key)
        input.keyInfo.dataSize = size
        input.data8 = SMCSelector.readKey.rawValue

        guard let output = callLocked(&input),
              output.result == SMCErrorCode.success.rawValue else { return nil }

        var raw = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: output.bytes) { buffer in
            for index in 0..<min(32, buffer.count) { raw[index] = buffer[index] }
        }
        return SMCValue(code: key, type: type, bytes: Array(raw.prefix(Int(size))))
    }

    private func callLocked(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        guard isOpen else { return nil }
        var output = SMCParamStruct()
        var size = MemoryLayout<SMCParamStruct>.stride
        let status = IOConnectCallStructMethod(connection,
                                             UInt32(SMCSelector.handleYPCEvent.rawValue),
                                             &input, MemoryLayout<SMCParamStruct>.stride,
                                             &output, &size)
        return status == kIOReturnSuccess ? output : nil
    }
}
