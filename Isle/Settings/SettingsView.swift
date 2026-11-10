//
//  SettingsView.swift
//
//  The Settings window. A native sidebar separates General, Appearance and
//  Shortcuts, the optional feature pages, and Updates; feature entries follow
//  the active mode, so a music-only user never sees Claude options and vice
//  versa. Changes restart only the affected subsystems live — no relaunch.
//
//  Layout rules, so the pages read alike: every row is a native grouped-Form
//  control whose caption, when it earns one, is the label's second line; a
//  setting that only matters while another is on appears under it only then;
//  and the long explanations live behind a disclosure, not in every row.
//

import SwiftUI
import EventKit

private enum SettingsPage: String, Identifiable {
    case general
    case appearance
    case shortcuts
    case music
    case claude
    case agenda
    case pomodoro
    case updates

    var id: String { rawValue }

    /// The sidebar's name — short enough for its fixed column.
    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .shortcuts: return "Shortcuts"
        case .music: return "Music"
        case .claude: return "Claude Code"
        case .agenda: return "Calendar"
        case .pomodoro: return "Pomodoro"
        case .updates: return "Updates"
        }
    }

    /// The window title, where there's room for the full name.
    var windowTitle: String {
        self == .agenda ? "Calendar & Reminders" : title
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .shortcuts: return "keyboard"
        case .music: return "music.note"
        case .claude: return "sparkles"
        case .agenda: return "calendar"
        case .pomodoro: return "timer"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The capture behind the waveform, so the Music page can say why it
    /// isn't running. Nil in previews and before the island exists.
    var audio: SystemAudioLevels?

    @ObservedObject private var updater = Updater.shared

    @State private var hookInstalled = HookInstaller.isInstalled
    @State private var hookMessage: String?
    /// The guarded-commands field's draft.
    @State private var newGuardedCommand = ""
    @State private var selectedPage: SettingsPage? = .general

    /// Bumped when Isle comes back to the front, which is what happens after
    /// the Calendar or Reminders prompt is answered — so the access rows
    /// re-read EventKit instead of showing the state from before the prompt.
    @State private var accessRefresh = 0

    var body: some View {
        // The sidebar is this window's permanent navigation, so it's pinned
        // open: column visibility is a constant, and the system's collapse
        // button is removed from the sidebar column's toolbar (it has to be
        // removed *there* — on the outer split view the modifier is ignored).
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $selectedPage) {
                Section {
                    sidebarRow(.general)
                    sidebarRow(.appearance)
                    sidebarRow(.shortcuts)
                }

                Section("Features") {
                    if settings.effectiveMode.showsClaude {
                        sidebarRow(.claude)
                    }
                    if settings.effectiveMode.showsMusic {
                        sidebarRow(.music)
                    }
                    sidebarRow(.agenda)
                    sidebarRow(.pomodoro)
                }

                Section {
                    sidebarRow(.updates)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Isle")
            // A single width, not a range: with min == max the column has no
            // slack, so the divider can't be dragged and the sidebar stays put.
            .navigationSplitViewColumnWidth(185)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            selectedContent
                .navigationTitle((selectedPage ?? .general).windowTitle)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 720, height: 500)
        .onChange(of: settings.effectiveMode) { _, _ in
            guard let selectedPage, !availablePages.contains(selectedPage) else { return }
            self.selectedPage = .general
        }
    }

    private var availablePages: [SettingsPage] {
        var pages: [SettingsPage] = [.general, .appearance, .shortcuts]
        if settings.effectiveMode.showsClaude { pages.append(.claude) }
        if settings.effectiveMode.showsMusic { pages.append(.music) }
        pages += [.agenda, .pomodoro, .updates]
        return pages
    }

    private func sidebarRow(_ page: SettingsPage) -> some View {
        Label(page.title, systemImage: page.symbol)
            .tag(page)
    }

    @ViewBuilder
    private var selectedContent: some View {
        Form {
            switch selectedPage ?? .general {
            case .general:
                islandSection
                batterySection
            case .appearance:
                appearanceSection
                if settings.panelBackground == .fade {
                    statusLightSection
                }
                if settings.effectiveMode.showsClaude {
                    accentSection
                }
            case .shortcuts:
                ShortcutsSettingsSection(settings: settings)
            case .music:
                musicSection
            case .claude:
                claudeHookSection
                claudeNotchSection
                claudeSoundSection
                guardedCommandsSection
            case .agenda:
                calendarSection
                remindersSection
                agendaSoundSection
            case .pomodoro:
                pomodoroSection
            case .updates:
                updatesSection
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessRefresh += 1
        }
    }

    // MARK: - Row building blocks

    /// A row's label: its title, and — when it earns one — a one-line
    /// caption, which a grouped Form sets as the title's subtitle.
    @ViewBuilder
    private func rowLabel(_ title: String, _ caption: String? = nil) -> some View {
        Text(title)
        if let caption {
            Text(caption)
        }
    }

    private func toggleRow(_ title: String, _ caption: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { rowLabel(title, caption) }
    }

    /// A sound: one row, its switch and — only while on — a menu of the
    /// bundled sounds beside it. Switching on plays the current pick and
    /// choosing another plays that, so the choice is made by ear rather than
    /// by name.
    private func soundRow(
        _ title: String, _ caption: String? = nil,
        enabled: Binding<Bool>, sound: Binding<NotificationSound>
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                if enabled.wrappedValue {
                    Picker(title, selection: sound) {
                        ForEach(NotificationSound.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: sound.wrappedValue) { _, picked in
                        picked.play()
                    }
                }
                Toggle(title, isOn: enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: enabled.wrappedValue) { _, on in
                        if on { sound.wrappedValue.play() }
                    }
            }
        } label: {
            rowLabel(title, caption)
        }
    }

    /// A number with its unit and a stepper, for the lengths and counts.
    private func stepperRow(
        _ title: String, _ caption: String? = nil,
        value: Binding<Int>, range: ClosedRange<Int>, unit: String
    ) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(title, value: value, in: range, step: 1)
                    .labelsHidden()
            }
        } label: {
            rowLabel(title, caption)
        }
    }

    /// A macOS permission the row above needs, with a way to its Privacy
    /// pane. Orange only when the system says it was declined.
    private func permissionRow(_ text: String, declined: Bool = false, pane: PrivacyPane) -> some View {
        LabeledContent {
            Button("Open Privacy Settings…") { pane.open() }
                .controlSize(.small)
        } label: {
            Text(text)
                .font(.caption)
                .foregroundStyle(declined ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - General

    private var islandSection: some View {
        Section("Island") {
            Picker("Isle shows", selection: modeBinding) {
                ForEach(IsleMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker(selection: $settings.displayScope) {
                ForEach(DisplayScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            } label: {
                rowLabel("Show on", settings.displayScope.subtitle)
            }

            toggleRow("Haptic feedback",
                      "A trackpad tap as the notch opens or closes.",
                      isOn: $settings.haptics)
        }
    }

    /// The mode picker reads `effectiveMode` (never nil) and writes through to
    /// the stored optional, which flips onboarding's "has chosen" too.
    private var modeBinding: Binding<IsleMode> {
        Binding(
            get: { settings.effectiveMode },
            set: { settings.mode = $0 }
        )
    }

    /// Unconditional, unlike Music and Claude: power isn't a mode, it's
    /// ambient. A charger going in matters whichever source the island is
    /// running.
    ///
    /// Two independent switches, neither nested under the other. They are
    /// different questions about different hardware — this Mac's battery, and
    /// the batteries of things attached to it — and someone who only wants to
    /// hear about their headphones should be able to say so. Switching one off
    /// stops Isle watching for it; macOS's own alerts are untouched either way.
    private var batterySection: some View {
        Section("Battery") {
            toggleRow("This Mac",
                      "Charging, full, low battery and Low Power Mode, briefly in the island.",
                      isOn: $settings.showBatteryEvents)

            toggleRow("Bluetooth devices",
                      "A device’s battery level when it connects.",
                      isOn: $settings.showDeviceBattery)

            if settings.showDeviceBattery {
                // Bluetooth won't say whether it was declined, so this is a
                // pointer, not a status.
                permissionRow("Needs Bluetooth access. If it was declined, no device will show.",
                              pane: .bluetooth)
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Island") {
            Picker(selection: $settings.panelBackground) {
                ForEach(PanelBackground.allCases) { background in
                    Text(background.title).tag(background)
                }
            } label: {
                rowLabel("Background", panelBackgroundCaption)
            }
            .pickerStyle(.segmented)

            // Only Glass and Smoked have anything to glow into; Fade is
            // already black around the camera.
            if settings.panelBackground.growsNotchGlow {
                toggleRow("Glow from the notch", notchGlowCaption, isOn: $settings.panelNotchGlow)
            }
        }
    }

    /// Fade's status light, and the closed island it lights. Shown with Fade,
    /// the background the light is drawn on.
    private var statusLightSection: some View {
        Section("Status light") {
            toggleRow("Status light", statusLightCaption, isOn: $settings.statusLight)
            if settings.statusLight {
                Picker(selection: $settings.closedIslandShows) {
                    ForEach(ClosedIslandShows.allCases) { Text($0.title).tag($0) }
                } label: {
                    rowLabel("Closed island shows", "Beside the cover while music plays, lit by the status light.")
                }
                .pickerStyle(.segmented)
                Picker(selection: $settings.closedIsland) {
                    ForEach(ClosedIslandStyle.allCases) { Text($0.title).tag($0) }
                } label: {
                    rowLabel("Closed island", closedIslandCaption)
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var statusLightCaption: String {
        if reduceTransparency {
            return "Reduce Transparency is on in System Settings, so the island stays black and unlit."
        }
        return "The island's light takes Claude's colour, and wraps the island when Claude needs you, is done or is stopped."
    }

    private var closedIslandCaption: String {
        switch settings.closedIsland {
        case .black: return "Solid black, like the notch."
        case .glass: return "Glass either side of the camera; the camera stays black."
        }
    }

    /// The background's subtitle, or why it isn't showing when Reduce
    /// Transparency is holding the panel black.
    private var panelBackgroundCaption: String {
        guard settings.panelBackground.isGlass, reduceTransparency else {
            return settings.panelBackground.subtitle
        }
        return "Reduce Transparency is on in System Settings, so the island stays black."
    }

    /// What the glow does, and why it can't when no screen has a notch.
    private var notchGlowCaption: String {
        if !NSScreen.screens.contains(where: { $0.safeAreaInsets.top > 0 }) {
            return "Black fades from the camera into the open panel. No display attached has a notch."
        }
        return "Black fades from the camera into the open panel, on displays with a notch."
    }

    /// A swatch row plus a custom well, rather than a bare colour picker.
    ///
    /// macOS's own accent setting has this shape, and two things here make it
    /// the right one beyond consistency. The accent has to yield *three* stops
    /// — `DotColors.paletteRamp` walks primary → accent → secondary — so a
    /// swatch can ship its ramp pre-derived and correct, where an arbitrary hue
    /// has to derive one and degrades at the extremes. And two regions of the
    /// space are actively wrong: near-black vanishes against the camera
    /// housing, and near-red or near-green impersonates `failed` and `done`,
    /// which is exactly what holding the semantic markers fixed is meant to
    /// prevent. The swatches are measured against those; a custom colour is
    /// floored by `ClaudeAccent.derive` but carries no such guarantee.
    private var accentSection: some View {
        Section("Claude Code") {
            LabeledContent {
                HStack(spacing: 6) {
                    ForEach(ClaudeAccent.swatches) { swatch in
                        swatchChip(swatch)
                    }
                    CustomAccentWell(
                        hex: $settings.claudeAccentHex,
                        isSelected: settings.claudeAccent == .custom,
                        size: Self.chipSize
                    ) {
                        settings.claudeAccent = .custom
                    }
                }
            } label: {
                rowLabel("Accent")
            }

            Text(accentCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One size for every chip in the accent row, the custom well included —
    /// it is the reason that well is hand-drawn rather than a `ColorPicker`.
    private static let chipSize: CGFloat = 24

    private func swatchChip(_ swatch: ClaudeAccent) -> some View {
        let selected = settings.claudeAccent == swatch
        return Button {
            settings.claudeAccent = swatch
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(swatch.chipColor(customHex: settings.claudeAccentHex))
                .frame(width: Self.chipSize, height: Self.chipSize)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .help(swatch.title)
        .accessibilityLabel(swatch.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// The family's own explanation, plus a qualifier in `.both` — where the
    /// accent is real but intermittent: `NotchViewModel.palette` prefers album
    /// art whenever there is any, and only falls through to the accent when
    /// nothing is playing. Saying so is better than hiding the control, which
    /// would leave a Both-mode user watching a colour they can't change.
    private var accentCaption: String {
        guard settings.effectiveMode == .both else { return familyCaption }
        return familyCaption + " While music plays, the album art sets the colour instead."
    }

    private var familyCaption: String {
        switch settings.claudeAccent.family {
        case .chromatic:
            return "The island’s colour when it shows Claude. \(settings.claudeAccent.title); questions, errors and Done keep their own colours."
        case .muted:
            return "\(settings.claudeAccent.title): muted rather than grey, since grey already means disconnected or paused."
        case .snapped:
            let name = ClaudeAccent.nearestSwatch(to: .controlAccentColor).title
            return "Follows your system accent, as the nearest colour Isle can use: \(name)."
        case .derived:
            if let clash = ClaudeAccent.collision(forCustom: settings.claudeAccentHex) {
                return "Close to the colour Isle uses for \(clash), so the island may read as one. Still applied."
            }
            return "A custom colour, clear of the colours Isle uses for questions, errors and success."
        }
    }

    // MARK: - Music

    /// The waveform picker is the one control here that costs a permission:
    /// only Live builds the audio tap, and building the tap is what makes
    /// macOS ask. Animated and Off never do — see `WaveformSource`.
    @ViewBuilder
    private var musicSection: some View {
        Section {
            Picker(selection: $settings.waveformSource) {
                ForEach(WaveformSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            } label: {
                rowLabel("Waveform", settings.waveformSource.subtitle)
            }
            .pickerStyle(.segmented)

            if settings.waveformSource.capturesAudio, let audio {
                AudioCaptureStatus(audio: audio)
            }
        }

        Section("Controls") {
            toggleRow("Scrubber", isOn: $settings.showScrubber)
            toggleRow("Shuffle and repeat", isOn: $settings.showShuffleRepeat)
        }
    }

    // MARK: - Claude

    @ViewBuilder
    private var claudeHookSection: some View {
        Section {
            LabeledContent {
                if hookInstalled {
                    Button("Remove", role: .destructive) { removeHook() }
                } else {
                    Button("Install") { installHook() }
                        .buttonStyle(.borderedProminent)
                }
            } label: {
                Label {
                    Text(hookInstalled ? "Hook installed" : "Hook not installed")
                } icon: {
                    Image(systemName: hookInstalled ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(hookInstalled ? .green : .orange)
                }
                Text(hookMessage ?? (hookInstalled
                     ? "Claude Code reports to Isle through it."
                     : "Isle sees no sessions until it’s installed."))
            }

            toggleRow("Keep Mac awake while Claude works",
                      "No idle sleep while a session works; the display can still sleep.",
                      isOn: $settings.keepAwakeWhileWorking)
        }
    }

    @ViewBuilder
    private var claudeNotchSection: some View {
        Section("In the notch") {
            toggleRow("Answer from the notch",
                      settings.answerFromNotch
                        ? "Approve, deny or answer there; the terminal prompt stays as a fallback."
                        : "Questions and approvals show there; you answer in the terminal.",
                      isOn: $settings.answerFromNotch)

            // Options only appear in the notch when it's answering.
            if settings.answerFromNotch {
                Picker(selection: $settings.optionDescriptions) {
                    ForEach(OptionDescriptions.allCases) { option in
                        Text(option.title).tag(option)
                    }
                } label: {
                    rowLabel("Option descriptions", optionDescriptionsCaption)
                }
                .pickerStyle(.segmented)
            }

            toggleRow("Open for alerts",
                      settings.expandOnAlert
                        ? "Questions and errors open the notch."
                        : "Alerts wait in the closed island; hover to open it.",
                      isOn: $settings.expandOnAlert)

            if settings.expandOnAlert {
                toggleRow("Close on hover-out or click",
                          settings.dismissAlertPanel
                            ? "The alert stays in the island until it’s resolved."
                            : "The panel stays open until the alert is resolved.",
                          isOn: $settings.dismissAlertPanel)
            }

            toggleRow("Show “Waiting” in the island",
                      settings.showWaitingStatus
                        ? "When Claude hands the turn back to you."
                        : "Waiting shows only in the open panel.",
                      isOn: $settings.showWaitingStatus)

            LabeledContent {
                HStack(spacing: 8) {
                    Text("\(Int(settings.doneToastSeconds)) s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Show “Done” for", value: $settings.doneToastSeconds, in: 1...15, step: 1)
                        .labelsHidden()
                }
            } label: {
                rowLabel("Show “Done” for")
            }
        }
    }

    private var optionDescriptionsCaption: String {
        switch settings.optionDescriptions {
        case .full: return "Up to three lines each, shortened if they don’t all fit."
        case .oneLine: return "Beside each label, cut off at the row’s end."
        case .hidden: return "Labels only."
        }
    }

    private var claudeSoundSection: some View {
        Section("Sounds") {
            soundRow("Alerts", "Approvals, questions and errors.",
                     enabled: $settings.claudeAlertSoundEnabled, sound: $settings.claudeAlertSound)
            soundRow("Turn finished",
                     enabled: $settings.claudeDoneSoundEnabled, sound: $settings.claudeDoneSound)
        }
    }

    // MARK: - Guarded commands

    /// The guarded-commands list (Milestone 17). Every claim in the copy was
    /// checked against Claude Code 2.1.319 with the real hook (ROADMAP,
    /// Milestone 17): its ask forced a prompt in all six permission modes and
    /// past a matching allow rule, the terminal asked with Isle gone, and in
    /// `claude -p`, where nothing can ask, it refused the call.
    @ViewBuilder
    private var guardedCommandsSection: some View {
        Section {
            toggleRow("Always ask before guarded commands",
                      "Every time, in every permission mode. A speed bump, not a sandbox.",
                      isOn: $settings.guardCommands)

            if settings.guardCommands {
                if !hookInstalled {
                    // The guard is the hook: without it the list is only a list.
                    Label("Install the hook above for the guard to hold.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ForEach(settings.guardedCommands, id: \.self) { pattern in
                    HStack {
                        Image(systemName: "shield.lefthalf.filled")
                            .foregroundStyle(.orange)
                        Text(pattern)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            settings.guardedCommands.removeAll { $0 == pattern }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop guarding \(pattern)")
                        .accessibilityLabel("Stop guarding \(pattern)")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        // Unlabelled: in a Form a field's title becomes a label
                        // column, which squeezed the field to half the row.
                        TextField("Add a command", text: $newGuardedCommand, prompt: Text("Add a command, like git push"))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addGuardedCommand(newGuardedCommand) }
                        Button("Add") { addGuardedCommand(newGuardedCommand) }
                            .disabled(GuardedCommands.normalized(newGuardedCommand) == nil)
                    }

                    let unused = GuardedCommands.suggestions.filter { !settings.guardedCommands.contains($0) }
                    if !unused.isEmpty {
                        // Wraps, so five suggestions never cut the last one off.
                        SuggestionFlow(spacing: 6) {
                            ForEach(unused, id: \.self) { suggestion in
                                Button {
                                    addGuardedCommand(suggestion)
                                } label: {
                                    Label(suggestion, systemImage: "plus")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Guard \(suggestion)")
                            }
                        }
                    }
                }

                DisclosureGroup("How guarding works") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A guarded command asks even in auto and bypass modes and past any allow rule, and the notch never offers Always… for it. With Isle closed, the terminal asks; in claude -p, where nothing can ask, it’s refused.")
                        Text("Write the program, then its subcommand words; flags can sit anywhere. Isle reads the command as a shell splits it, so cd x && git push and git \"push\" are caught, but an alias, a variable or a script can still hide one. A command over 16 KB that mentions every word of a pattern asks without being read.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
            }
        } header: {
            Text("Guarded commands")
        }
    }

    private func addGuardedCommand(_ text: String) {
        guard let pattern = GuardedCommands.normalized(text) else { return }
        if !settings.guardedCommands.contains(pattern) {
            settings.guardedCommands.append(pattern)
        }
        if text == newGuardedCommand { newGuardedCommand = "" }
    }

    // MARK: - Hook actions

    private func installHook() {
        do {
            try HookInstaller.install()
            hookInstalled = true
            hookMessage = "Installed to ~/.isle/bin and added to ~/.claude/settings.json."
        } catch {
            hookMessage = error.localizedDescription
        }
    }

    private func removeHook() {
        do {
            try HookInstaller.uninstall()
            hookInstalled = false
            hookMessage = "Removed. Your other Claude Code hooks were left alone."
        } catch {
            hookMessage = error.localizedDescription
        }
    }

    // MARK: - Calendar & Reminders

    /// Ambient like Battery, and split the same way: calendar events and
    /// reminders are separate data behind separate macOS permissions, so each
    /// gets its own switch and its own pointer at the Privacy pane.
    ///
    /// Unlike audio capture, EventKit *does* say when it was declined, so
    /// that is stated outright rather than hedged — see `AgendaMonitor.Access`
    /// — and once access is granted there's nothing to say at all.
    @ViewBuilder
    private var calendarSection: some View {
        Section("Calendar") {
            toggleRow("Upcoming events",
                      "Today’s events on the Agenda face, each shown in the island before it starts.",
                      isOn: $settings.showCalendarEvents)

            if settings.showCalendarEvents {
                accessRow(for: .event, name: "Calendar", pane: .calendars)
                Picker("Show in the island", selection: leadBinding) {
                    ForEach(EventLead.allCases) { lead in
                        Text(lead.title).tag(lead)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var remindersSection: some View {
        Section("Reminders") {
            toggleRow("Reminders due today",
                      "On the Agenda face, and in the island as each comes due. Ones with no time are listed but not announced.",
                      isOn: $settings.showReminders)

            if settings.showReminders {
                accessRow(for: .reminder, name: "Reminders", pane: .reminders)
            }
        }
    }

    @ViewBuilder
    private var agendaSoundSection: some View {
        Section {
            if settings.showCalendarEvents || settings.showReminders {
                soundRow("Sound", "When an event or reminder appears in the island.",
                         enabled: $settings.agendaSoundEnabled, sound: $settings.agendaSound)
            }
        } footer: {
            Text("The Agenda face can add an event or reminder from a line like \u{201C}Lunch with Sam tomorrow 1pm\u{201D}; nothing is saved until you click Add. Calendar and Reminders keep their own alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Nothing once access is granted; otherwise what's needed, or — when
    /// EventKit says so — that it was declined.
    @ViewBuilder
    private func accessRow(for type: EKEntityType, name: String, pane: PrivacyPane) -> some View {
        let access = AgendaMonitor.Access.to(type)
        if access != .granted {
            Group {
                if access == .declined {
                    permissionRow("\(name) access was declined, so nothing will show until it’s allowed.",
                                  declined: true, pane: pane)
                } else {
                    permissionRow("Needs \(name) access, which macOS asks for when this is switched on.",
                                  pane: pane)
                }
            }
            .id(accessRefresh)
        }
    }

    /// The picker works in `EventLead`; the setting stores plain minutes so a
    /// value from a future ladder still round-trips through defaults.
    private var leadBinding: Binding<EventLead> {
        Binding(
            get: { EventLead(rawValue: settings.eventLeadMinutes) ?? .default },
            set: { settings.eventLeadMinutes = $0.rawValue }
        )
    }

    // MARK: - Pomodoro

    /// Opt-in, and only from here: the timer adds a tab to the expanded panel
    /// and a seat in the collapsed island, so it stays out of the way until
    /// somebody asks for it. The interval controls only appear once it's on.
    @ViewBuilder
    private var pomodoroSection: some View {
        Section {
            toggleRow("Pomodoro timer",
                      "A focus timer in the open panel; while it runs, the time left sits in the island.",
                      isOn: $settings.pomodoroEnabled)
        }

        if settings.pomodoroEnabled {
            Section {
                stepperRow("Focus", value: $settings.pomodoroFocusMinutes, range: 1...90, unit: "min")
                stepperRow("Short break", value: $settings.pomodoroShortBreakMinutes, range: 1...30, unit: "min")
                stepperRow("Long break", value: $settings.pomodoroLongBreakMinutes, range: 1...60, unit: "min")
                stepperRow("Focus sessions before a long break",
                           value: $settings.pomodoroSessionsPerCycle, range: 1...8, unit: "")
                soundRow("Sound when an interval ends",
                         enabled: $settings.pomodoroSoundEnabled, sound: $settings.pomodoroSound)
            } header: {
                Text("Intervals")
            } footer: {
                Text("New lengths apply from the next interval.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Updates

    /// Mirrors Retermina's Version tab: the app version, a "Check for Updates"
    /// button whose errors surface here (unlike the silent launch check), and
    /// the live download/ready states off the shared `Updater` phase.
    @ViewBuilder
    private var updatesSection: some View {
        Section {
            LabeledContent {
                switch updater.phase {
                case .downloading, .ready:
                    EmptyView()
                default:
                    HStack(spacing: 8) {
                        if case let .available(version, _) = updater.phase {
                            Button("Install \(version)") {
                                Task { await updater.install() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button(isChecking ? "Checking…" : "Check for Updates") {
                            Task { await updater.check() }
                        }
                        .disabled(updaterIsBusy)
                    }
                }
            } label: {
                rowLabel("Isle \(appVersion)", updateStatus)
            }

            if case .downloading(let pct) = updater.phase {
                ProgressView(value: Double(pct), total: 100)
            }

            if case let .available(_, notes) = updater.phase, let notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the last check came to, as the version row's caption.
    private var updateStatus: String? {
        switch updater.phase {
        case .idle: return nil
        case .checking: return "Checking for updates…"
        case .upToDate: return "You’re on the latest version."
        case let .available(version, _): return "Version \(version) is available."
        case .downloading: return "Downloading update…"
        case .ready: return "Update installed — relaunching…"
        case let .error(message): return message
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var isChecking: Bool {
        if case .checking = updater.phase { return true }
        return false
    }

    private var updaterIsBusy: Bool {
        switch updater.phase {
        case .checking, .downloading: return true
        default: return false
        }
    }
}


// MARK: - Audio capture status

/// What the live waveform can honestly say about its capture.
///
/// A real failure (`failureReason`) is reported as such. A *declined* Audio
/// Recording permission is not one: the tap builds, the device starts, and
/// the IOProc simply never fires, so there is no error to report and Isle
/// can't tell a declined permission from silence. What it can do is point at
/// the setting — a conditional pointer, not a claim.
private struct AudioCaptureStatus: View {
    @ObservedObject var audio: SystemAudioLevels

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reason = audio.failureReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
                Button("Open Privacy Settings…") {
                    PrivacyPane.audioCapture.open()
                }
                .controlSize(.small)
            } label: {
                Text("If the bars don’t move while music plays, Audio Recording may be off for Isle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Deep links into System Settings › Privacy & Security. The anchors are the
/// ones the Privacy pane has used since Ventura; an unknown one just opens
/// the pane, so the worst case is one extra click.
enum PrivacyPane: String {
    case audioCapture = "Privacy_AudioCapture"
    case bluetooth = "Privacy_Bluetooth"
    case calendars = "Privacy_Calendars"
    case reminders = "Privacy_Reminders"

    func open() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)")!
        NSWorkspace.shared.open(url)
    }
}

/// Lays its views out in rows, wrapping when a row is full: the guarded
/// commands' suggestion chips, which outgrow one row in a 720pt window.
private struct SuggestionFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map { $0.height }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
