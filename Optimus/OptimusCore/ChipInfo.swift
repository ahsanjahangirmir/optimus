import Foundation

enum ChipGeneration: String, CaseIterable {
    case intel, m1, m2, m3, m4, m5, unknown
}

enum ChipVariant: String, CaseIterable {
    case base, pro, max, ultra
}

struct ChipSummary {
    let generation: ChipGeneration
    let variant: ChipVariant
    let brandString: String
}

/// Stateless chip detection, shared by anything that needs to know which SMC sensor
/// keys apply on this Mac (temperature key names differ by chip generation and are
/// undocumented by Apple). Parsed from `machdep.cpu.brand_string` — fast, in-process,
/// no shelling out, matching the style of `SystemProbe`/`BatteryProbe`.
enum ChipInfo {
    static let current: ChipSummary = detect()

    private static func detect() -> ChipSummary {
        let brand = sysctlString("machdep.cpu.brand_string") ?? ""
        let lower = brand.lowercased()

        guard lower.contains("apple") else {
            return ChipSummary(generation: lower.contains("intel") ? .intel : .unknown,
                                variant: .base, brandString: brand)
        }

        let generation: ChipGeneration
        if lower.contains("m5") { generation = .m5 }
        else if lower.contains("m4") { generation = .m4 }
        else if lower.contains("m3") { generation = .m3 }
        else if lower.contains("m2") { generation = .m2 }
        else if lower.contains("m1") { generation = .m1 }
        else { generation = .unknown }

        let variant: ChipVariant
        if lower.contains("ultra") { variant = .ultra }
        else if lower.contains("max") { variant = .max }
        else if lower.contains("pro") { variant = .pro }
        else { variant = .base }

        return ChipSummary(generation: generation, variant: variant, brandString: brand)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
