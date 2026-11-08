import SwiftUI

struct FanControlView: View {
    @State private var smc = SMCService()
    @State private var helper = FanHelperService()

    @State private var isManual: [Int: Bool] = [:]
    @State private var manualTargets: [Int: Double] = [:]
    @State private var writeInFlight: Set<Int> = []
    @State private var writeError: String?

    var temps: [SMCReading] { smc.readings.filter { $0.unit == "°C" } }
    var fans:  [SMCReading] { smc.readings.filter { $0.category == .fan && $0.key.hasSuffix("Ac") } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                disclaimer
                if !fans.isEmpty  { fanSection }
                if !temps.isEmpty { tempSection }
                if smc.readings.isEmpty { unavailableNotice }
            }
            .padding(24)
        }
        .navigationTitle("Fan Control & Sensors")
        .onAppear  { smc.start(); helper.refreshStatus() }
        .onDisappear { smc.stop() }
    }

    private func fanIndex(for reading: SMCReading) -> Int? {
        Int(reading.key.dropFirst().dropLast(2)) // "F0Ac" -> 0
    }

    private func setManual(id: Int, enabled: Bool, currentRPM: Double) {
        isManual[id] = enabled
        Task {
            helper.install()
            writeInFlight.insert(id)
            let result: Result<Void, Error>
            if enabled {
                let target = manualTargets[id] ?? currentRPM
                manualTargets[id] = target
                result = await helper.setFanTarget(id: id, rpm: target)
            } else {
                result = await helper.setFanAuto(id: id)
            }
            writeInFlight.remove(id)
            if case .failure(let error) = result {
                writeError = error.localizedDescription
                isManual[id] = false
            }
        }
    }

    private func commitTarget(id: Int) {
        guard isManual[id] == true, let rpm = manualTargets[id] else { return }
        Task {
            writeInFlight.insert(id)
            let result = await helper.setFanTarget(id: id, rpm: rpm)
            writeInFlight.remove(id)
            if case .failure(let error) = result {
                writeError = error.localizedDescription
            }
        }
    }

    private var disclaimer: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Silicon Fan Control Notice").font(.headline)
                Text("On Apple Silicon Macs, manual fan override only takes effect once macOS itself has decided cooling is needed (typically ~60–70°C). Below that threshold fan speeds are ignored — this is a hardware/firmware restriction, not a bug. Fan control can only raise speed above Apple's own curve, never lower it below Apple's floor.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var fanSection: some View {
        InfoCard(title: "Fans") {
            ForEach(fans) { fan in
                if let id = fanIndex(for: fan) {
                    let minValue = smc.readings.first { $0.key == "F\(id)Mn" }?.value ?? 0
                    let maxValue = smc.readings.first { $0.key == "F\(id)Mx" }?.value ?? max(minValue, fan.value)
                    let manual = isManual[id] == true
                    let busy = writeInFlight.contains(id)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "wind").foregroundStyle(.blue).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fan.label)
                                Text(fan.key).font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(String(format: "%.0f RPM", fan.value))
                                    .fontWeight(.semibold)
                                    .foregroundStyle(fan.value > 4000 ? .orange : .primary)
                                Text(String(format: "min %.0f / max %.0f", minValue, maxValue))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            Toggle("Manual", isOn: Binding(
                                get: { manual },
                                set: { setManual(id: id, enabled: $0, currentRPM: fan.value) }
                            ))
                            .toggleStyle(.switch)
                            .disabled(busy)
                            .labelsHidden()
                        }
                        if manual {
                            Slider(
                                value: Binding(
                                    get: { manualTargets[id] ?? fan.value },
                                    set: { manualTargets[id] = $0 }
                                ),
                                in: minValue...max(maxValue, minValue + 1),
                                onEditingChanged: { editing in
                                    if !editing { commitTarget(id: id) }
                                }
                            )
                            .disabled(busy)
                            Text(String(format: "Target: %.0f RPM", manualTargets[id] ?? fan.value))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            Divider()
            helperStatusRow
            if let writeError {
                Text(writeError).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
    }

    private var helperStatusRow: some View {
        HStack {
            Image(systemName: helper.status == .enabled ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                .foregroundStyle(helper.status == .enabled ? .green : .secondary)
                .frame(width: 20)
            Text(helperStatusText)
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if helper.status == .requiresApproval {
                Button("Open System Settings") { helper.openSystemSettings() }
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var helperStatusText: String {
        switch helper.status {
        case .off: return "Fan write helper not installed yet — toggle Manual on a fan to install it."
        case .enabled: return "Fan write helper active — manual overrides write to the SMC."
        case .requiresApproval: return "Fan write helper needs approval in System Settings > Login Items."
        case .notFound: return "Fan write helper not found in this build."
        }
    }

    private var tempSection: some View {
        InfoCard(title: "Temperatures") {
            ForEach(SensorCategory.allCases.filter { $0 != .fan }, id: \.self) { category in
                let rows = temps.filter { $0.category == category }
                if !rows.isEmpty {
                    sectionLabel(category.displayName)
                    ForEach(rows) { tempRow($0) }
                }
            }
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 2)
    }

    private func tempRow(_ r: SMCReading) -> some View {
        HStack {
            Circle().fill(tempColor(r.value)).frame(width: 8, height: 8)
            Text(r.label)
            Spacer()
            Text(String(format: "%.1f °C", r.value)).fontWeight(.medium).foregroundStyle(tempColor(r.value))
            Text("(\(r.key))").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    private func tempColor(_ t: Double) -> Color {
        t > 90 ? .red : t > 70 ? .orange : t > 50 ? .yellow : .green
    }

    private var unavailableNotice: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.title2)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SMC data unavailable").font(.headline)
                    Text("No sensor readings from the AppleSMC driver. Diagnostic info below.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                diagRow("AppleSMC service found", value: smc.serviceFound ? "Yes" : "No",
                        accent: smc.serviceFound ? .primary : .red)
                diagRow("IOServiceOpen error",    value: hexStatus(smc.openError),
                        accent: smc.openError == 0 ? .primary : .orange)
                diagRow("SMCKeyData struct size",  value: "\(smc.structSize) bytes")
            }
            .padding(.bottom, 8)
            if !smc.keyDiagnostics.isEmpty {
                Divider()
                sectionLabel("Per-key failures (\(smc.keyDiagnostics.count))")
                ForEach(smc.keyDiagnostics) { d in
                    HStack {
                        Text("\(d.label) (\(d.key))").foregroundStyle(.secondary)
                        Spacer()
                        Text(d.hint).fontWeight(.medium).foregroundStyle(.orange).fontDesign(.monospaced)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 5)
                }
                .padding(.bottom, 8)
            }
        }
        .cardSurface()
    }

    private func diagRow(_ label: String, value: String, accent: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium).foregroundStyle(accent).fontDesign(.monospaced)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func hexStatus(_ s: OSStatus) -> String {
        s == 0 ? "noErr (0x00000000)" : String(format: "0x%08X (%d)", UInt32(bitPattern: s), s)
    }
}

#Preview {
    FanControlView().frame(width: 700)
}
