import Foundation
import Observation
import IOKit

// MARK: - Sensor categorization

enum SensorCategory: String, CaseIterable {
    case cpu, gpu, ssd, memoryController, battery, ambient, fan

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ssd: return "SSD"
        case .memoryController: return "Memory Controller"
        case .battery: return "Battery"
        case .ambient: return "Ambient"
        case .fan: return "Fans"
        }
    }
}

/// One SMC key this app knows how to read, gated to the chip generation(s)/variant(s)
/// it's actually known to exist on. SMC key names are undocumented by Apple and differ
/// by chip — Apple Silicon key names below are sourced from the open-source, MIT-licensed
/// exelban/Stats sensor table, cross-referenced there against acidanthera/VirtualSMC's
/// reverse-engineered key docs.
struct SensorKeyDef {
    let key: String
    let label: String
    let category: SensorCategory
    let generations: Set<ChipGeneration>
    let variants: Set<ChipVariant>?   // nil = applies to all variants of a matching generation

    func applies(to chip: ChipSummary) -> Bool {
        guard generations.contains(chip.generation) else { return false }
        guard let variants else { return true }
        return variants.contains(chip.variant)
    }
}

private let kAllGenerations = Set(ChipGeneration.allCases)
private let kAppleSiliconGenerations: Set<ChipGeneration> = [.m1, .m2, .m3, .m4, .m5]

private let kSMCTemperatureKeys: [SensorKeyDef] = [
    // MARK: Intel
    SensorKeyDef(key: "TC0P", label: "CPU Proximity",     category: .cpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TC0D", label: "CPU Die",            category: .cpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TC0E", label: "CPU Core 0",         category: .cpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TC1C", label: "CPU Core 1",         category: .cpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TC2C", label: "CPU Core 2",         category: .cpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TC3C", label: "CPU Core 3",         category: .cpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TCGC", label: "GPU Proximity",      category: .gpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TG0D", label: "GPU Die",            category: .gpu,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TH0a", label: "SSD 0",              category: .ssd,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "TH1a", label: "SSD 1",              category: .ssd,             generations: [.intel], variants: nil),
    SensorKeyDef(key: "Tm0P", label: "Memory Controller",  category: .memoryController, generations: [.intel], variants: nil),
    SensorKeyDef(key: "TB0T", label: "Battery",            category: .battery,         generations: [.intel], variants: nil),

    // MARK: Apple Silicon — CPU efficiency cores
    SensorKeyDef(key: "Te05", label: "CPU Efficiency Core 1", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Te0S", label: "CPU Efficiency Core 2", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Te09", label: "CPU Efficiency Core 3", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Te0H", label: "CPU Efficiency Core 4", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),

    // MARK: Apple Silicon — CPU performance cores
    SensorKeyDef(key: "Tp01", label: "CPU Performance Core 1", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp05", label: "CPU Performance Core 2", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp09", label: "CPU Performance Core 3", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp0D", label: "CPU Performance Core 4", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp0V", label: "CPU Performance Core 5", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp0Y", label: "CPU Performance Core 6", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp0b", label: "CPU Performance Core 7", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tp0e", label: "CPU Performance Core 8", category: .cpu, generations: kAppleSiliconGenerations, variants: nil),

    // MARK: Apple Silicon — GPU (base-die keys differ from Pro/Max/Ultra)
    SensorKeyDef(key: "Tg0G", label: "GPU 1", category: .gpu, generations: [.m1, .m2, .m3, .m4, .m5], variants: [.base]),
    SensorKeyDef(key: "Tg0H", label: "GPU 2", category: .gpu, generations: [.m1, .m2, .m3, .m4, .m5], variants: [.base]),
    SensorKeyDef(key: "Tg1U", label: "GPU 1", category: .gpu, generations: [.m1, .m2, .m3, .m4, .m5], variants: [.pro, .max, .ultra]),
    SensorKeyDef(key: "Tg1k", label: "GPU 2", category: .gpu, generations: [.m1, .m2, .m3, .m4, .m5], variants: [.pro, .max, .ultra]),
    SensorKeyDef(key: "Tg0K", label: "GPU 3", category: .gpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tg0L", label: "GPU 4", category: .gpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tg0d", label: "GPU 5", category: .gpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tg0e", label: "GPU 6", category: .gpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tg0j", label: "GPU 7", category: .gpu, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tg0k", label: "GPU 8", category: .gpu, generations: kAppleSiliconGenerations, variants: nil),

    // MARK: Apple Silicon — memory controller
    SensorKeyDef(key: "Tm0p", label: "Memory Proximity 1", category: .memoryController, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tm1p", label: "Memory Proximity 2", category: .memoryController, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "Tm2p", label: "Memory Proximity 3", category: .memoryController, generations: kAppleSiliconGenerations, variants: nil),

    // MARK: Apple Silicon — SSD / battery (generation-independent key names)
    SensorKeyDef(key: "TH0x", label: "NAND",     category: .ssd,     generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "TB1T", label: "Battery 1", category: .battery, generations: kAppleSiliconGenerations, variants: nil),
    SensorKeyDef(key: "TB2T", label: "Battery 2", category: .battery, generations: kAppleSiliconGenerations, variants: nil),

    // MARK: Ambient — least consistently-documented category across models; try all known names
    SensorKeyDef(key: "TaLP", label: "Ambient Left",  category: .ambient, generations: kAllGenerations, variants: nil),
    SensorKeyDef(key: "TaRP", label: "Ambient Right", category: .ambient, generations: kAllGenerations, variants: nil),
    SensorKeyDef(key: "TaRF", label: "Ambient (alt)", category: .ambient, generations: kAllGenerations, variants: nil),
]

struct SMCReading: Identifiable {
    let id = UUID()
    var key: String
    var label: String
    var value: Double
    var unit: String
    var category: SensorCategory
}

/// One SMC key that failed to resolve on this Mac, with the real driver-level result
/// byte (not just the always-successful IOKit transport code) so the diagnostic panel
/// tells the truth about why.
struct SMCKeyDiagnostic: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let ioReturn: kern_return_t
    let smcResult: UInt8

    var hint: String {
        if ioReturn != kIOReturnSuccess { return "IOKit call failed (transport error)" }
        if smcResult != 0 { return "not present on this Mac (SMC result \(smcResult))" }
        return "unrecognized data type"
    }
}

@Observable
@MainActor
final class SMCService {
    var readings: [SMCReading] = []
    var keyDiagnostics: [SMCKeyDiagnostic] = []

    // Exposed diagnostics — shown in the UI instead of a generic "unavailable" message
    var serviceFound: Bool = false
    var openError:    OSStatus = 0
    var structSize:   Int = MemoryLayout<SMCKeyData>.stride

    private var conn:   io_connect_t = 0
    private var isOpen: Bool = false
    private var timer:  Timer?

    @ObservationIgnored
    private lazy var applicableTempKeys: [SensorKeyDef] = {
        let chip = ChipInfo.current
        // Unknown chip generation: probe every known key defensively rather than
        // guessing wrong and reporting nothing — now-correct per-key diagnostics make
        // this cheap (failures are clean, not silent).
        guard chip.generation != .unknown else { return kSMCTemperatureKeys }
        return kSMCTemperatureKeys.filter { $0.applies(to: chip) }
    }()

    func start() {
        openSMC()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closeSMC()
    }

    private func openSMC() {
        let opened = SMCBridge.openSMC()
        conn = opened.conn
        serviceFound = opened.serviceFound
        openError = opened.openError
        isOpen = (openError == kIOReturnSuccess)
    }

    private func closeSMC() {
        guard isOpen else { return }
        SMCBridge.closeSMC(conn)
        isOpen = false
    }

    func refresh() {
        guard isOpen else { readings = []; keyDiagnostics = []; return }

        var result: [SMCReading] = []
        var diagnostics: [SMCKeyDiagnostic] = []

        for def in applicableTempKeys {
            let r = SMCBridge.readKey(conn, def.key)
            if let value = r.value {
                result.append(SMCReading(key: def.key, label: def.label, value: value, unit: "°C", category: def.category))
            } else {
                diagnostics.append(SMCKeyDiagnostic(key: def.key, label: def.label, ioReturn: r.ioReturn, smcResult: r.smcResult))
            }
        }

        // Fan count is discovered at runtime via FNum rather than hardcoded — some
        // Apple Silicon models have 1 fan, others (e.g. Mac Studio) have 2.
        let fanCount = Int(SMCBridge.readKey(conn, "FNum").value ?? 0)
        for i in 0..<max(fanCount, 0) {
            let acKey = "F\(i)Ac", mnKey = "F\(i)Mn", mxKey = "F\(i)Mx"
            let ac = SMCBridge.readKey(conn, acKey)
            if let value = ac.value {
                result.append(SMCReading(key: acKey, label: "Fan \(i) Speed", value: value, unit: "RPM", category: .fan))
            } else {
                diagnostics.append(SMCKeyDiagnostic(key: acKey, label: "Fan \(i) Speed", ioReturn: ac.ioReturn, smcResult: ac.smcResult))
            }
            if let value = SMCBridge.readKey(conn, mnKey).value {
                result.append(SMCReading(key: mnKey, label: "Fan \(i) Min", value: value, unit: "RPM", category: .fan))
            }
            if let value = SMCBridge.readKey(conn, mxKey).value {
                result.append(SMCReading(key: mxKey, label: "Fan \(i) Max", value: value, unit: "RPM", category: .fan))
            }
        }

        readings = result
        keyDiagnostics = diagnostics
    }
}
