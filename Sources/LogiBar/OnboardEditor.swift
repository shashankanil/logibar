import AppKit
import SwiftUI

/// Colors for DPI stages 1–5, used in the editor, the ladder and the stage chips.
let stageColors: [Color] = [.pink, .orange, .yellow, .mint, .cyan]

struct OnboardEditor: View {
    @ObservedObject var device: LogiDevice
    @State private var draft: [OnboardProfile] = []
    @State private var selected = 0
    @State private var activeIndex = 0
    @State private var saving = false
    @State private var status: String?
    @State private var statusIsError = false

    var body: some View {
        Group {
            if let memory = device.memory {
                if !memory.descriptor.editable {
                    ContentUnavailableView("Memory format not supported yet", systemImage: "memorychip",
                                           description: Text("This device uses onboard profile format \(memory.descriptor.profileFormat)."))
                } else if draft.indices.contains(selected) {
                    editor(memory)
                } else {
                    ProgressView().onAppear { reset(to: memory) }
                }
            } else {
                ProgressView("Reading onboard memory…")
            }
        }
        .onChange(of: device.memory) { _, memory in
            if let memory, !saving { reset(to: memory) }
        }
    }

    private func originalActiveIndex(_ memory: OnboardMemory) -> Int {
        memory.profiles.firstIndex { $0.sector == memory.activeSector } ?? 0
    }

    private func reset(to memory: OnboardMemory) {
        draft = memory.profiles
        activeIndex = originalActiveIndex(memory)
        selected = min(selected, max(0, draft.count - 1))
    }

    private func isDirty(_ memory: OnboardMemory) -> Bool {
        draft != memory.profiles || activeIndex != originalActiveIndex(memory)
    }

    private func editor(_ memory: OnboardMemory) -> some View {
        let factoryButtons = memory.factoryProfiles.first?.buttons ?? draft[selected].buttons
        let choices = device.state.dpiChoices ?? DPIChoices(values: Array(stride(from: 100, through: 12000, by: 50)), step: 50)
        let rates = (device.state.reportRates.isEmpty ? [125, 250, 500, 1000] : device.state.reportRates).filter { $0 <= 1000 }

        return VStack(spacing: 0) {
            Form {
                if device.state.onboardProfiles == false {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("Onboard profiles are off, so the mouse is using LogiBar's live settings instead of what's saved here.")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Turn On") { device.setOnboardProfiles(true) }
                        }
                    }
                }

                if draft.count > 1 {
                    Section {
                        Picker("Profile", selection: $selected) {
                            ForEach(draft.indices, id: \.self) { i in
                                Text(draft[i].name.isEmpty ? "Profile \(i + 1)" : draft[i].name).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        Toggle("Active profile", isOn: Binding(get: { activeIndex == selected }) { if $0 { activeIndex = selected } })
                        Toggle("Enabled (reachable with the profile button)", isOn: $draft[selected].enabled)
                    }
                }

                Section {
                    StageLadder(stages: draft[selected].stages, defaultStage: draft[selected].defaultStage, choices: choices)
                        .padding(.vertical, 4)
                    StagesEditor(profile: $draft[selected], choices: choices)
                } header: {
                    Text("DPI stages")
                } footer: {
                    Text("The DPI button steps through these. ★ marks the stage the mouse starts on.")
                }

                Section("Performance") {
                    Picker("Polling rate", selection: $draft[selected].reportRateHz) {
                        ForEach(rates, id: \.self) { Text("\($0) Hz").tag($0) }
                    }
                    TextField("Profile name", text: $draft[selected].name, prompt: Text("Optional"))
                }

                Section {
                    ForEach(0..<draft[selected].buttonCount, id: \.self) { i in
                        ButtonActionRow(
                            name: (i < factoryButtons.count ? factoryButtons[i] : .unassigned).physicalName(index: i),
                            action: Binding(get: { draft[selected].buttons[i] }) { action in
                                var buttons = draft[selected].buttons
                                buttons[i] = action
                                draft[selected].buttons = buttons
                            },
                            factory: i < factoryButtons.count ? factoryButtons[i] : .unassigned,
                            profileCount: draft.count
                        )
                    }
                    if draft[selected].buttons.contains(.function(.shiftDPI)) {
                        Picker("DPI Shift uses", selection: $draft[selected].shiftStage) {
                            ForEach(draft[selected].stages.indices, id: \.self) { i in
                                Text("Stage \(i + 1) · \(draft[selected].stages[i]) DPI").tag(i)
                            }
                        }
                    }
                } header: {
                    Text("Buttons")
                } footer: {
                    Text("Assignments are stored in the mouse, so they work on any computer without software.")
                }
            }
            .formStyle(.grouped)
            .disabled(saving || !device.online)

            Divider()
            footer(memory)
        }
    }

    private func footer(_ memory: OnboardMemory) -> some View {
        HStack(spacing: 10) {
            Menu {
                Button("Restore Factory Defaults") {
                    for i in draft.indices where i < memory.factoryProfiles.count {
                        var p = memory.factoryProfiles[i]
                        p.sector = draft[i].sector
                        p.enabled = draft[i].enabled
                        draft[i] = p
                    }
                    setStatus("Factory settings loaded. Save to write them to the mouse.")
                }
                Divider()
                Button("Export Backup…") { exportBackup(memory) }
                Button("Restore from Backup…") { importBackup() }
                Button("Show Automatic Backups") { NSWorkspace.shared.open(OnboardBackups.directory) }
                Divider()
                Button("Reload from Mouse") { device.reloadMemory() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Revert") { reset(to: memory) }
                .disabled(!isDirty(memory) || saving)
            Button {
                save()
            } label: {
                if saving { ProgressView().controlSize(.small).frame(width: 90) } else { Text("Save to Mouse").frame(width: 90) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty(memory) || saving || !device.online)
        }
        .padding(12)
    }

    private func setStatus(_ text: String, error: Bool = false) {
        status = text
        statusIsError = error
    }

    private func save() {
        saving = true
        setStatus("Writing to the mouse…")
        device.saveOnboard(draft, activeIndex: activeIndex) { error in
            saving = false
            if let error {
                setStatus("Couldn't save: \(error)", error: true)
            } else {
                setStatus("Saved to the mouse. A backup of the previous settings was kept.")
                if let memory = device.memory { reset(to: memory) }
            }
        }
    }

    private func exportBackup(_ memory: OnboardMemory) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(device.state.name) onboard memory.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try OnboardBackups.encode(memory, device: device.state.name).write(to: url)
            setStatus("Backup exported.")
        } catch {
            setStatus("Export failed: \(error.localizedDescription)", error: true)
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = OnboardBackups.directory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saving = true
        setStatus("Restoring backup…")
        device.restoreBackup(url) { error in
            saving = false
            setStatus(error.map { "Restore failed: \($0)" } ?? "Backup restored to the mouse.", error: error != nil)
        }
    }
}

// MARK: DPI stages

/// Maps DPI to slider position on a log scale, so low values aren't crammed together.
private struct LogScale {
    let min: Double, max: Double
    func position(_ dpi: Int) -> Double { log(Double(dpi) / min) / log(max / min) }
    func dpi(_ position: Double) -> Double { min * pow(max / min, position) }
}

struct StagesEditor: View {
    @Binding var profile: OnboardProfile
    let choices: DPIChoices

    var body: some View {
        let stages = profile.stages
        ForEach(stages.indices, id: \.self) { i in
            StageRow(
                index: i,
                value: Binding(get: { profile.stages.indices.contains(i) ? profile.stages[i] : 0 }) { v in
                    var s = profile.stages
                    guard s.indices.contains(i) else { return }
                    s[i] = snap(v)
                    profile.stages = s
                },
                isDefault: profile.defaultStage == i,
                choices: choices,
                makeDefault: { profile.defaultStage = i },
                remove: stages.count > 1 ? { remove(i) } : nil
            )
        }
        if stages.count < OnboardProfile.stageCount {
            Button {
                profile.stages = stages + [snap(min(choices.max, (stages.last ?? 400) * 2))]
            } label: {
                Label("Add Stage", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    private func remove(_ i: Int) {
        var s = profile.stages
        s.remove(at: i)
        let d = profile.defaultStage
        profile.stages = s
        profile.defaultStage = d == i ? 0 : (d > i ? d - 1 : d)
    }

    private func snap(_ v: Int) -> Int {
        if let step = choices.step {
            return Swift.min(choices.max, Swift.max(choices.min, Int((Double(v) / Double(step)).rounded()) * step))
        }
        return choices.values.min { abs($0 - v) < abs($1 - v) } ?? v
    }
}

private struct StageRow: View {
    let index: Int
    @Binding var value: Int
    let isDefault: Bool
    let choices: DPIChoices
    let makeDefault: () -> Void
    let remove: (() -> Void)?

    var body: some View {
        let scale = LogScale(min: Double(choices.min), max: Double(choices.max))
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.bold())
                .foregroundStyle(.black.opacity(0.75))
                .frame(width: 20, height: 20)
                .background(Circle().fill(stageColors[index % stageColors.count]))
            Slider(value: Binding(get: { scale.position(value) }) { value = Int(scale.dpi($0)) }, in: 0...1) {
                Text("Stage \(index + 1)")
            }
            .labelsHidden()
            .tint(stageColors[index % stageColors.count])
            .frame(maxWidth: .infinity)
            TextField("DPI", value: $value, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
            Text("DPI").foregroundStyle(.secondary).font(.caption)
            Button(action: makeDefault) {
                Image(systemName: isDefault ? "star.fill" : "star").foregroundStyle(isDefault ? .yellow : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Start on this stage")
            Button { remove?() } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .disabled(remove == nil)
                .help("Remove stage")
        }
    }
}

/// The stages laid out on the device's DPI range. Labels that would collide flip below the track.
struct StageLadder: View {
    let stages: [Int]
    let defaultStage: Int
    let choices: DPIChoices

    var body: some View {
        let scale = LogScale(min: Double(choices.min), max: Double(choices.max))
        VStack(spacing: 4) {
            GeometryReader { geo in
                let width = geo.size.width - 24
                let xs = stages.map { 12 + width * CGFloat(scale.position($0)) }
                let below = labelsBelow(xs)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(LinearGradient(colors: [.indigo.opacity(0.4), .cyan.opacity(0.4)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width, height: 6)
                        .offset(x: 12, y: 29)
                    ForEach(stages.indices, id: \.self) { i in
                        let size: CGFloat = i == defaultStage ? 16 : 12
                        Circle()
                            .fill(stageColors[i % stageColors.count])
                            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: i == defaultStage ? 2 : 0))
                            .frame(width: size, height: size)
                            .offset(x: xs[i] - size / 2, y: 32 - size / 2)
                        Text("\(stages[i])")
                            .font(.caption2.monospacedDigit().weight(i == defaultStage ? .bold : .regular))
                            .fixedSize()
                            .frame(width: 60)
                            .offset(x: xs[i] - 30, y: below[i] ? 44 : 6)
                    }
                }
            }
            .frame(height: 62)
            HStack {
                Text("\(choices.min)")
                Spacer()
                Text("\(choices.max) DPI")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func labelsBelow(_ xs: [CGFloat]) -> [Bool] {
        var below = [Bool](repeating: false, count: xs.count)
        var lastAbove: CGFloat = -.infinity
        var lastBelow: CGFloat = -.infinity
        for (i, x) in xs.enumerated().sorted(by: { $0.element < $1.element }) {
            if x - lastAbove >= 40 {
                lastAbove = x
            } else if x - lastBelow >= 40 {
                below[i] = true
                lastBelow = x
            }
        }
        return below
    }
}

// MARK: Buttons

struct ButtonActionRow: View {
    let name: String
    @Binding var action: ButtonAction
    let factory: ButtonAction
    let profileCount: Int
    @State private var recording = false

    var body: some View {
        LabeledContent(name) {
            Menu(action == .unassigned ? "Default (\(factory.title))" : action.title) {
                Section("Mouse") {
                    ForEach(ButtonAction.mouseButtons, id: \.0) { mask, title in
                        Button(title) { action = .mouse(mask) }
                    }
                }
                Section("DPI") {
                    ForEach([ButtonFunction.cycleDPI, .nextDPI, .previousDPI, .defaultDPI, .shiftDPI], id: \.self) { f in
                        Button(f.title) { action = .function(f) }
                    }
                }
                if profileCount > 1 {
                    Section("Profiles") {
                        ForEach([ButtonFunction.cycleProfile, .nextProfile, .previousProfile], id: \.self) { f in
                            Button(f.title) { action = .function(f) }
                        }
                    }
                }
                Section("Media") {
                    ForEach(ButtonAction.mediaKeys, id: \.0) { code, title in
                        Button(title) { action = .consumer(code) }
                    }
                }
                Section("Scrolling") {
                    ForEach([ButtonFunction.scrollUp, .scrollDown, .tiltLeft, .tiltRight], id: \.self) { f in
                        Button(f.title) { action = .function(f) }
                    }
                }
                Section {
                    Button("Keyboard Shortcut…") { recording = true }
                    Button("Disable Button") { action = .disabled }
                    Button("Factory Default (\(factory.title))") { action = factory }
                }
            }
            .frame(width: 230)
        }
        .sheet(isPresented: $recording) {
            ShortcutRecorder { action = $0 }
        }
    }
}

struct ShortcutRecorder: View {
    let onDone: (ButtonAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var captured: ButtonAction?
    @State private var monitor: Any?

    var body: some View {
        VStack(spacing: 16) {
            Text("Press a key combination").font(.headline)
            Text(captured?.title ?? "Waiting…")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(captured == nil ? .secondary : .primary)
                .frame(minWidth: 220, minHeight: 56)
                .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
            Text("The mouse sends this shortcut itself, so it works on any computer.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Button("Use Shortcut") {
                    if let captured { onDone(captured) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(captured == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if let usage = KeyCodes.usage(forMacKeyCode: event.keyCode) {
                    captured = .key(modifiers: KeyCodes.modifiers(from: event.modifierFlags), usage: usage)
                }
                return nil
            }
        }
        .onDisappear {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
