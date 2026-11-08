import SwiftUI

struct BatteryView: View {
    @State private var service = BatteryService()
    @State private var powerMode = PowerModeService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                energyModeSection
                healthSection
                liveSection
                powerSection
                BatteryChartsView()
            }
            .padding(24)
        }
        .navigationTitle("Battery")
        .onAppear { service.start() }
        .onDisappear { service.stop() }
        .task { await powerMode.refresh() }
    }

    private var headerSection: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: chargeIcon)
                    .font(.system(size: 32))
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%.0f%%", service.info.chargePercent))
                    .font(.system(size: 48, weight: .thin, design: .rounded))
                Text(statusLabel)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            Spacer()
        }
    }

    private var energyModeSection: some View {
        InfoCard(title: "Energy Mode",
                 tooltip: "Controls how macOS balances performance, heat, and battery life. Automatic is the default balance; Low Power trims background activity to stretch battery life; High Power (where available) lets the fans run harder for sustained heavy workloads.") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Energy Mode", selection: Binding(
                    get: { powerMode.currentMode },
                    set: { powerMode.setMode($0) }
                )) {
                    ForEach(visibleEnergyModes) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(powerMode.isApplying)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if powerMode.isApplying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Applying — you may be asked to authenticate…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }

                if let error = powerMode.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 10)
        }
    }

    private var visibleEnergyModes: [EnergyMode] {
        powerMode.supportsHighPower
            ? EnergyMode.allCases
            : EnergyMode.allCases.filter { $0 != .highPower }
    }

    private var healthSection: some View {
        InfoCard(title: "Battery Health") {
            InfoRow("Condition",        value: service.info.condition.isEmpty ? "Unknown" : service.info.condition,
                    accent: conditionColor,
                    tooltip: "Apple's overall verdict on your battery's wear. \"Normal\" means it's aging as expected for its age and cycle count; other values suggest a service visit may help.")
            InfoRow("Health",           value: String(format: "%.0f%%", service.info.healthPercent),
                    tooltip: "How much charge the battery can hold today compared to when it was brand new. 96% health means it now holds 96% of its original capacity.")
            InfoRow("Cycle Count",      value: "\(service.info.cycleCount)",
                    tooltip: "One full cycle = using 100% of the battery's capacity — whether that's one full charge, or several smaller top-ups that add up to 100%. Every battery is rated for a certain number of cycles before it noticeably degrades.")
            InfoRow("Max Capacity",     value: "\(service.info.maxCapacity) mAh",
                    tooltip: "How much charge the battery can currently hold, in milliamp-hours (mAh). This shrinks slowly as the battery ages — it's the raw number behind the Health percentage above.")
            InfoRow("Design Capacity",  value: "\(service.info.designCapacity) mAh",
                    tooltip: "How much charge this battery could hold on day one, brand new. Max Capacity is measured against this baseline to calculate Health %.")
        }
    }

    private var liveSection: some View {
        InfoCard(title: "Live Readings") {
            InfoRow("Temperature", value: String(format: "%.1f °C", service.info.temperature),
                    tooltip: "The battery's internal temperature. Running hot for long periods — especially while charging — is one of the biggest contributors to long-term battery wear.")
            InfoRow("Voltage",     value: String(format: "%.3f V",  service.info.voltage),
                    tooltip: "The electrical \"pressure\" pushing current through the battery. It rises as the battery charges and falls as it discharges, but it isn't the same measurement as charge percentage.")
            InfoRow("Amperage",    value: "\(service.info.amperage) mA",
                    tooltip: "The rate current is flowing, in milliamps. Positive usually means the battery is charging (current flowing in); negative means it's discharging (powering the Mac).")
            InfoRow("Capacity",    value: "\(service.info.currentCapacity) mAh",
                    tooltip: "How much charge is stored right now, in milliamp-hours — the raw number behind the charge percentage shown at the top.")
        }
    }

    private var powerSection: some View {
        InfoCard(title: "Power") {
            InfoRow("Source",   value: service.info.isPluggedIn ? "AC Power" : "Battery",
                    tooltip: "Whether the Mac is currently drawing power from the wall (AC) or running off the battery.")
            InfoRow("Charging", value: service.info.isCharging ? "Yes" : "No",
                    tooltip: "Whether the battery is actively gaining charge right now. You can be plugged in without charging — for example, once the battery reaches 100%.")
            if service.info.isCharging && service.info.timeToFull > 0 {
                InfoRow("Time to Full",      value: formatTime(service.info.timeToFull),
                        tooltip: "macOS's estimate based on the current charging speed. It becomes less accurate near a full charge, when charging naturally slows down.")
            }
            if !service.info.isCharging && !service.info.isPluggedIn && service.info.timeToEmpty > 0 {
                InfoRow("Time Remaining",    value: formatTime(service.info.timeToEmpty),
                        tooltip: "macOS's estimate based on your current power draw. It shifts as your workload changes — light tasks extend it, heavy ones shorten it.")
            }
        }
    }

    private var chargeIcon: String {
        if service.info.isCharging { return "battery.100.bolt" }
        let p = service.info.chargePercent
        if p > 75 { return "battery.100" }
        if p > 50 { return "battery.75" }
        if p > 25 { return "battery.50" }
        if p > 10 { return "battery.25" }
        return "battery.0"
    }

    private var statusLabel: String {
        var base: String
        if service.info.isCharging { base = "Charging" }
        else if service.info.isPluggedIn { base = "Plugged in, not charging" }
        else { base = "On Battery" }

        if powerMode.currentMode != .automatic {
            base += " · \(powerMode.currentMode.rawValue)"
        }
        return base
    }

    /// Plugged-in state still wins visually when on Automatic (green vs blue, as before).
    /// Low Power / High Power take over the tint whenever they're active, plugged in or not,
    /// since they're an explicit user choice that overrides the default coloring.
    private var iconColor: Color {
        switch powerMode.currentMode {
        case .lowPower: return .yellow
        case .highPower: return .red
        case .automatic: return service.info.isPluggedIn ? .green : .blue
        }
    }

    private var conditionColor: Color {
        switch service.info.condition.lowercased() {
        case "good", "normal": return .green
        case "replace soon": return .orange
        case "replace now", "service battery": return .red
        default: return .primary
        }
    }

    private func formatTime(_ minutes: Int) -> String {
        guard minutes > 0 else { return "Calculating…" }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

// MARK: - Shared UI helpers (used across modules)

/// A small "i" icon that shows its text as a native tooltip on hover *and*
/// as a popover on click. A bare `Image` with just `.help()` isn't a real
/// interactive control, so hover tracking on it is unreliable and clicking
/// it does nothing — wrapping it in a `Button` fixes both.
struct InfoTooltip: View {
    let text: String
    var font: Font = .subheadline
    var color: AnyShapeStyle = AnyShapeStyle(.secondary)

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(font)
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct InfoCard<Content: View>: View {
    let title: String
    var tooltip: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.headline)
                if let tooltip {
                    InfoTooltip(text: tooltip, font: .subheadline, color: AnyShapeStyle(.secondary))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
            content()
                .padding(.bottom, 6)
        }
        .cardSurface()
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    var accent: Color = .primary
    var tooltip: String? = nil

    init(_ label: String, value: String, accent: Color = .primary, tooltip: String? = nil) {
        self.label = label; self.value = value; self.accent = accent; self.tooltip = tooltip
    }

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                Text(label).foregroundStyle(.secondary)
                if let tooltip {
                    InfoTooltip(text: tooltip, font: .caption, color: AnyShapeStyle(.tertiary))
                }
            }
            Spacer()
            Text(value).foregroundStyle(accent).fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

#Preview {
    BatteryView().frame(width: 700)
}
