import Foundation
import IOKit

// MARK: - SMC struct layout (must exactly match C driver's SMCKeyData_t)
// SMCKeyDataKeyInfo has trailing padding (_pad) so its Swift size == C sizeof (12 bytes).
// Without the padding, result/status/data8/data32 land at wrong offsets and all reads fail.

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var _pad0: UInt8 = 0   // explicit 3-byte pad to match C sizeof(SMCKeyInfoData) = 12
    var _pad1: UInt8 = 0
    var _pad2: UInt8 = 0
}

struct SMCKeyData {
    var key: UInt32 = 0
    var vers:   (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var _vpad:  UInt16 = 0          // align pLimit to 4-byte boundary (vers ends at 10, need 12)
    var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo = SMCKeyDataKeyInfo()
    var result:  UInt8 = 0
    var status:  UInt8 = 0
    var data8:   UInt8 = 0
    var _dpad:   UInt8 = 0          // align data32 to 4-byte boundary
    var data32:  UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

let kSMCHandleYPCEvent: UInt32 = 2
let kSMCReadKey:    UInt8 = 5
let kSMCWriteKey:   UInt8 = 6
let kSMCGetKeyInfo: UInt8 = 9

/// Result of one `SMCBridge.readKey` attempt: `ioReturn` is the transport-level
/// (Mach/IOKit) call result — it's `kIOReturnSuccess` as long as AppleSMC *accepted the
/// request*, even when the key doesn't exist. `smcResult` is the driver-level per-key
/// result (`output.result`) — 0 means the key actually resolved; non-zero means the SMC
/// firmware rejected/couldn't find it. Both must be checked.
struct SMCKeyResult {
    var value: Double?
    var ioReturn: kern_return_t
    var smcResult: UInt8
    var dataType: UInt32 = 0
    var dataSize: UInt32 = 0
}

/// Low-level AppleSMC user-client primitives, shared by the unprivileged read-only
/// `SMCService` (in the main app) and the privileged `OptimusFanHelper` (writes fan
/// targets). Keeping the 80-byte `SMCKeyData` struct layout and the selector constants
/// defined exactly once here avoids ever reintroducing a layout-drift bug between the
/// two call sites.
enum SMCBridge {
    static func openSMC() -> (conn: io_connect_t, serviceFound: Bool, openError: OSStatus) {
        var conn: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else {
            return (0, false, kIOReturnNotFound)
        }
        defer { IOObjectRelease(service) }
        let openError = IOServiceOpen(service, mach_task_self_, 0, &conn)
        return (conn, true, openError)
    }

    static func closeSMC(_ conn: io_connect_t) {
        guard conn != 0 else { return }
        IOServiceClose(conn)
    }

    /// Discovers a key's byte size/type via `kSMCGetKeyInfo` and reads its raw value via
    /// `kSMCReadKey`, decoding it according to whatever data type the SMC actually reports.
    static func readKey(_ conn: io_connect_t, _ key: String) -> SMCKeyResult {
        var input  = SMCKeyData()
        var output = SMCKeyData()
        input.key   = fcc(key)
        input.data8 = kSMCGetKeyInfo

        var inSz  = MemoryLayout<SMCKeyData>.stride
        var outSz = MemoryLayout<SMCKeyData>.stride

        let kr1 = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, inSz, &output, &outSz)
        guard kr1 == kIOReturnSuccess else { return SMCKeyResult(value: nil, ioReturn: kr1, smcResult: output.result) }
        guard output.result == 0 else { return SMCKeyResult(value: nil, ioReturn: kr1, smcResult: output.result) }

        let dataType = output.keyInfo.dataType
        let dataSize = output.keyInfo.dataSize

        input.keyInfo.dataSize = dataSize
        input.data8 = kSMCReadKey
        inSz  = MemoryLayout<SMCKeyData>.stride
        outSz = MemoryLayout<SMCKeyData>.stride

        let kr2 = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, inSz, &output, &outSz)
        guard kr2 == kIOReturnSuccess else { return SMCKeyResult(value: nil, ioReturn: kr2, smcResult: output.result) }
        guard output.result == 0 else { return SMCKeyResult(value: nil, ioReturn: kr2, smcResult: output.result) }

        let b = [output.bytes.0, output.bytes.1, output.bytes.2, output.bytes.3]
        let value = decode(bytes: b, dataType: dataType)
        return SMCKeyResult(value: value, ioReturn: kr2, smcResult: output.result, dataType: dataType, dataSize: dataSize)
    }

    /// Writes `value` to `key`, encoding it according to whatever data type/size the SMC
    /// reports for that key right now (never assume — it varies by key and by machine).
    /// Root-only in practice: the AppleSMC user client rejects writes from unprivileged
    /// callers, which is why this is only ever invoked from `OptimusFanHelper`.
    static func writeKey(_ conn: io_connect_t, _ key: String, value: Double) -> (ioReturn: kern_return_t, smcResult: UInt8) {
        var input  = SMCKeyData()
        var output = SMCKeyData()
        input.key   = fcc(key)
        input.data8 = kSMCGetKeyInfo

        var inSz  = MemoryLayout<SMCKeyData>.stride
        var outSz = MemoryLayout<SMCKeyData>.stride

        let kr1 = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, inSz, &output, &outSz)
        guard kr1 == kIOReturnSuccess, output.result == 0 else { return (kr1, output.result) }

        let dataType = output.keyInfo.dataType
        let dataSize = output.keyInfo.dataSize
        let encoded = encode(value: value, dataType: dataType, size: Int(dataSize))

        input = SMCKeyData()
        input.key = fcc(key)
        input.keyInfo.dataSize = dataSize
        input.data8 = kSMCWriteKey
        input.bytes.0 = encoded.count > 0 ? encoded[0] : 0
        input.bytes.1 = encoded.count > 1 ? encoded[1] : 0
        input.bytes.2 = encoded.count > 2 ? encoded[2] : 0
        input.bytes.3 = encoded.count > 3 ? encoded[3] : 0

        inSz  = MemoryLayout<SMCKeyData>.stride
        outSz = MemoryLayout<SMCKeyData>.stride
        let kr2 = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, &input, inSz, &output, &outSz)
        return (kr2, output.result)
    }

    static func fcc(_ s: String) -> UInt32 {
        let b = Array(s.utf8)
        guard b.count >= 4 else { return 0 }
        return UInt32(b[0])<<24 | UInt32(b[1])<<16 | UInt32(b[2])<<8 | UInt32(b[3])
    }

    private static func decode(bytes b: [UInt8], dataType: UInt32) -> Double? {
        if dataType == fcc("sp78") {
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 256.0
        }
        if dataType == fcc("fpe2") {
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])
            return Double(raw) / 4.0
        }
        if dataType == fcc("flt ") {
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        }
        if dataType == fcc("ui8 ") { return Double(b[0]) }
        if dataType == fcc("ui16") { return Double(UInt16(b[0]) << 8 | UInt16(b[1])) }
        if dataType == fcc("ui32") {
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        }
        return nil
    }

    private static func encode(value: Double, dataType: UInt32, size: Int) -> [UInt8] {
        if dataType == fcc("sp78") {
            let raw = UInt16(bitPattern: Int16(value * 256.0))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
        if dataType == fcc("fpe2") {
            let raw = UInt16(max(0, min(value, 16383)) * 4.0)
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
        if dataType == fcc("flt ") {
            let bits = Float(value).bitPattern
            return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
        }
        if dataType == fcc("ui8 ") { return [UInt8(max(0, min(value, 255)))] }
        if dataType == fcc("ui16") {
            let raw = UInt16(max(0, min(value, 65535)))
            return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
        }
        if dataType == fcc("ui32") {
            let raw = UInt32(max(0, min(value, 4294967295)))
            return [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        }
        return [UInt8(max(0, min(value, 255)))]
    }
}
