//
//  NotchViewModel.swift
//
//  Single observable every island reads from. Owns the media feed, the Claude
//  bridge and the power toasts — i.e. everything the notch *shows*, which is
//  identical on every screen it's drawn on.
//
//  The other input that can open the notch, pointer hover, is per-screen and
//  lives on IslandPresentation. This file keeps the live-activity half of the
//  rule (`autoExpandsForActivity`); that file crosses it with its own hover.
//

import SwiftUI
import AppKit
import Combine

/// Element widths for the collapsed notch, shared by the width calculation
/// (NotchViewModel) and the layout (CollapsedNotchView) so they can't drift.
enum CollapsedSize {
    static let album: CGFloat = 22
    /// The waveform, one size in every layout. It used to narrow to 22 when
    /// the album shared the island, which drew the same waveform at a lighter
    /// weight in the split view; the album never shrank for Claude, and
    /// `NotchMetrics.collapsedClaudeExtra` says outright that the waveform
    /// isn't meant to either. Costs 4pt of island width in the split view.
    static let wave: CGFloat = 26
    static let dots: CGFloat = 16
    static let gap: CGFloat = 5          // between elements within a cluster
    static let cutoutGap: CGFloat = 6    // between a cluster and the camera
    static let minSide: CGFloat = 30     // resting half-width when a side is empty
    static let claudeSoloLeading: CGFloat = 14
    static let statusFontSize: CGFloat = 10
}

/// How many live sessions besides the island's own are busy or blocked —
/// see `NotchViewModel.otherSessions`.
struct ClaudeOtherSessions: Equatable {
    /// Working or compacting.
    var working = 0
    /// Blocked on an approval or a question.
    var needYou = 0

    var isEmpty: Bool { working == 0 && needYou == 0 }
}

/// The text fields in the panel — the Claude face's three and the agenda's
/// quick add. Each one makes the panel key while it's in use — see
/// `NotchViewModel.composing`.
enum ComposeKind: Equatable {
    /// A reply to a session at its prompt, typed into its terminal.
    case reply
    /// "Type something": a free-text answer to the question on screen.
    case answer
    /// "No, and tell Claude what to do differently": a denial with a reason.
    case denial
    /// "Add event or reminder…" on the agenda face.
    case quickAdd
}

/// What became of a reply, in the order it can happen. Nothing here is
/// claimed early: `sent` waits for the transcript to show the text as the
/// user's own turn.
enum ReplyDelivery: Equatable {
    case none
    /// Typed into the terminal; not yet seen in the transcript.
    case sending(String)
    /// The transcript holds it as a turn the user typed.
    case sent(String)
    /// It didn't get there. `text` is kept in the field; `reason` says why.
    case failed(text: String, reason: String)
}

/// Everything the island *shows*, shared by every island on every screen.
///
/// Hover and per-screen geometry are not here — they belong to one island and
/// live on `IslandPresentation`. See that file for where the line is drawn and
/// why the alert flags stayed on this side of it.
@MainActor
final class NotchViewModel: ObservableObject {

    /// The user retracted the current alert's auto-opened panel (hovered away or
    /// clicked it). The panel collapses to the island but the alert glyph stays
    /// until the state resolves; re-armed for the next alert. Ignored unless
    /// `settings.dismissAlertPanel` is on.
    @Published private(set) var alertDismissed = false

    /// The pointer entered the panel during the current alert — a prerequisite
    /// for hover-away to count as a dismiss (so an untouched auto-open isn't
    /// dismissed by a stray move nearby).
    private var alertWasHovered = false

    /// The user went somewhere themselves — a tile, Home, a swipe — while the
    /// current alert was live, so the auto-jump to the Claude face (see
    /// `expandedPlace`) should stop overriding their choice for the rest of
    /// this alert. Re-armed on the next state change, so a fresh interrupt
    /// still grabs the Claude face once.
    private var tabOverriddenDuringAlert = false

    /// Claude Code state from the hook bridge, driven by `ClaudeStatusWatcher`.
    /// Stays `.disconnected` when the active mode doesn't show Claude, or when
    /// there's no live session.
    @Published var claudeState: ClaudeCodeState = .disconnected

    /// Project directory name from the status file. For the Claude expanded
    /// view (Milestone 4).
    @Published private(set) var claudeProject: String?

    /// Session id from the status file, when the installed `isle-cli` emits it.
    @Published private(set) var claudeSessionId: String?

    /// The tool Claude is currently running (Edit / Bash / …) and its target,
    /// for the "what it's doing" line in the expanded view.
    @Published private(set) var claudeAction: String?
    @Published private(set) var claudeTarget: String?

    /// For `.failed`, the API `error_type` (rate_limit / overloaded / …) so the
    /// notch can name the failure. Nil in every other state.
    @Published private(set) var claudeErrorType: String?

    /// A tool is executing right now (between `PreToolUse` and `PostToolUse`).
    /// Only used to suppress the no-response inference — deliberately *not*
    /// wired into `isThinking`, which stays on the lingering-action rule so the
    /// collapsed word doesn't flap on every tool boundary.
    @Published private(set) var claudeToolActive: Bool = false

    /// For a `usage_limit` failure, the moment the limit resets (when the helper
    /// could recover it). Drives the pinned island's reset clock and the expanded
    /// countdown; the display eases back to idle at this moment. Nil when unknown.
    @Published private(set) var claudeResetAt: Date?

    /// For a usage limit, the window that was hit, and — on the limit or the
    /// turn Claude Code continued after it — what it said comes next
    /// (Milestone 19). Nil when the record didn't say.
    @Published private(set) var claudeLimitKind: String?
    @Published private(set) var claudeLimitNext: ClaudeLimitNext?

    /// The start of what Claude said at the end of its last turn, as the face
    /// and the home tile show it (see `ClaudeDoneLine`). Read from the
    /// session's record, which carries the message from `Stop` until the next
    /// prompt — so it stays through the checkmark easing back to "Ready" and
    /// the "waiting for your input" nudge, and goes the moment a new turn
    /// starts. Nil when the turn ended with nothing to quote (only code, or
    /// no text), and on a helper older than v10.
    @Published private(set) var claudeFinalLine: String?

    /// The subagents the island's session has running, by type, oldest
    /// first (Milestone 22): what its hooks reported, each until its own
    /// stop, and none once the session's process is gone. Empty when none
    /// are, or the helper or Claude Code is too old to say. See
    /// `ClaudeSubagents` for the line made of it.
    @Published private(set) var claudeSubagents: [String] = []

    /// Each live session's trail: the calls its turn has finished, as its
    /// records reported them (see `ClaudeTrail`). Kept from every scan, not
    /// just the island's session's, so a session picked from the list or
    /// taking the island arrives with its trail; dropped with the session's
    /// record.
    @Published private(set) var claudeTrails: [String: ClaudeTrail] = [:]

    /// The island's session's trail.
    var claudeTrail: ClaudeTrail? {
        claudeSessionId.flatMap { claudeTrails[$0] }
    }

    /// The last call auto mode blocked in the island's session since its
    /// last prompt (Milestone 23), as its record carries it. An event, not a
    /// state: it changes no headline, and the face says it in a line of its
    /// own. See `ClaudeBlock`.
    @Published private(set) var claudeBlock: ClaudeBlock?

    /// What the island's session's last turn left running or scheduled when
    /// it ended (Milestone 20), as its record carries it: the shells and
    /// agents still in flight at that Stop, and the wake-ups set for later.
    /// As of the turn's end, never a live count; the next prompt clears it.
    /// See `ClaudeLeftovers`.
    @Published private(set) var claudeLeftovers: ClaudeLeftovers?

    /// Each session's block as last read, by session id — what tells a new
    /// block from one already announced (see `announceBlocks`).
    private var seenBlocks: [String: String] = [:]

    /// When the last Claude status change arrived, for the "… ago" line in the
    /// Claude expanded view. `nil` when disconnected.
    @Published private(set) var claudeUpdatedAt: Date?

    /// Isle is holding the keep-awake assertion right now. A mirror of
    /// `ClaudeKeepAwake.isHeld`, re-published after every take and release,
    /// so the panel's mark is the assertion itself rather than the setting:
    /// on while `pmset -g assertions` lists the hold, off the moment it goes.
    @Published private(set) var isKeepingAwake = false

    /// Live sessions other than the one on the island that are busy or
    /// blocked — selection shows one session, and this is how the panel
    /// admits the rest. Counted only from sessions the registry vouches for,
    /// so a crashed session's leftover file never inflates it.
    @Published private(set) var otherSessions = ClaudeOtherSessions()

    // MARK: Every session at once (Milestone 16)

    /// Every live session, in the order selection ranks them — the list the
    /// Claude face can flip to. Only sessions the registry vouches for, each
    /// corrected as the island corrects its own (see `updateSessionList`).
    @Published private(set) var sessionList: [ClaudeSessionRow] = []

    /// The Claude face is showing the list rather than a session. Held here,
    /// like the question step, so every island shows the same thing; put
    /// away when the panel closes.
    @Published private(set) var sessionListShown = false

    /// The session the user picked from the list, while it holds the island
    /// (see `ClaudeSelection.Pin`). The face says so with a way back.
    @Published private(set) var pinnedSessionId: String?

    private var sessionPin: ClaudeSelection.Pin? {
        didSet {
            if pinnedSessionId != sessionPin?.sessionId { pinnedSessionId = sessionPin?.sessionId }
        }
    }

    /// Where each listed session is on screen, for its row's Jump. Resolved
    /// only while the list is up, and only from the session's own process
    /// tree — a row without one has no Jump.
    @Published private(set) var sessionHosts: [String: ClaudeSessionHost] = [:]

    /// The CLI pid each entry in `sessionHosts` was resolved for.
    private var sessionHostPIDs: [String: pid_t] = [:]

    // MARK: Background sessions (Milestone 21)

    /// Every session `claude agents --json --all` last listed.
    private var claudeAgents: [ClaudeAgent] = []

    /// When Isle saw each background session finish (see
    /// `ClaudeBackground.noteFinishes`), by session id.
    private var backgroundFinishedAt: [String: Date] = [:]

    /// The background half of the last reading: names, attach ids, Claude
    /// Code's states, and the sessions only agent view knows of.
    private var backgroundMerge = ClaudeBackground.Merge.empty

    /// What agent view adds about the island's session, when it hosts it:
    /// its name for the eyebrow and its attach id for Jump.
    @Published private(set) var claudeBackground: ClaudeBackgroundInfo?

    /// The island's state is Claude Code's (`claude agents`), not a hook's:
    /// the face says it in Claude Code's words, and nothing eases it away.
    @Published private(set) var claudeStateFromAgent = false

    /// Whether the live sessions the hooks report, besides the island's, are
    /// all quiet — what the reselect tick runs on. The background sessions
    /// only agent view knows of are counted in `otherSessions` but don't
    /// keep the tick going: nothing a tick re-reads can change them.
    private var hookOthersQuiet = true

    // MARK: Answering from the notch (Milestone 7)

    /// The request the selected session's hook says it is blocked on — the
    /// status file's `request_id`. Nil once any other verb has written.
    private var claudeRequestId: String?

    /// Every request a hook is blocked on right now, as `requestWatcher` last
    /// reported it.
    private var claudeRequests: [ClaudeRequest] = []

    /// The request the notch can answer right now: the one whose id the
    /// selected session's status names *and* whose file still exists. Either
    /// half going away retires the buttons — the file when the hook exits (an
    /// answer, its deadline, Esc in the terminal), the id when any other verb
    /// writes (the prompt was answered in the terminal and Claude moved on).
    /// Isle offers nothing it can't back with a hook that is actually waiting.
    @Published private(set) var pendingRequest: ClaudeRequest?

    /// The request a click has already answered, from the moment the response
    /// is written until the hook takes it and the request goes away. Disables
    /// the buttons so a double-click can't write twice.
    @Published private(set) var answeredRequestId: String?

    /// Which of a multi-question `AskUserQuestion` is on screen, and what has
    /// been picked for each so far. Held here rather than in the view so every
    /// island shows the same step.
    @Published private(set) var questionIndex = 0
    @Published private(set) var questionPicks: [Set<String>] = []

    /// "Always…" has been tapped on an approval that carries Claude Code's
    /// suggestions: the face shows exactly what accepting them would save,
    /// and only a second tap sends it. Held here, like the question step, so
    /// every island shows the same face.
    @Published private(set) var isReviewingRemember = false

    /// Whether `run/answering` is currently down, so it's only touched on a
    /// change.
    private var answeringMarkerWritten = false

    /// Free text typed for the current question ("Type something"), by
    /// question index. An entry replaces the picks for its question.
    @Published private(set) var questionTyped: [Int: String] = [:]

    // MARK: Jump and reply (Milestone 11)

    /// Where the island's session is on screen, from its CLI's process tree
    /// (see `ClaudeSessionHost`). Nil until resolved, and whenever the chain
    /// doesn't end at an app — the Jump pill and the Reply field are drawn
    /// only from this, so neither ever appears on a guess.
    @Published private(set) var sessionHost: ClaudeSessionHost?

    /// The CLI pid `sessionHost` was resolved for, so a re-selection of the
    /// same session doesn't walk the tree again.
    private var sessionHostPID: pid_t?

    /// Which text field is taking keys, if any. The window controller makes
    /// the panel key exactly while this is set, and hands focus back the
    /// moment it clears — see `NotchWindowController.observeComposing`.
    @Published private(set) var composing: ComposeKind? {
        didSet {
            // The reply's field let go — sent, Esc, or focus went elsewhere:
            // what changed while it held the face still lands now.
            if oldValue == .reply, composing != .reply { thawClaudeFace() }
        }
    }

    // MARK: Holding the face still while a reply is written

    /// The Claude face holds still while the reply field has the keys: a
    /// face that changes under the pointer — rows sliding in, the headline
    /// changing, Done swapping in for the working face, another session
    /// taking the island — throws off what's being typed. What arrives is
    /// kept, the latest of each, and applied once when the field lets go
    /// (`thawClaudeFace`). Only the field itself grows meanwhile. The
    /// draft is never touched by any of it.
    var claudeFaceFrozen: Bool { composing == .reply }

    /// The latest status that arrived while the face was held, and whether
    /// it would have announced itself.
    private var heldStatus: (status: ClaudeStatus, announce: Bool)?
    /// The trails as they stood when the face was last allowed to move.
    private var heldTrails: [String: ClaudeTrail]?
    /// Something held back says Claude needs the user — a permission prompt
    /// or a question — so the face says so, without moving, and switches to
    /// it once the reply is sent or put away.
    @Published private(set) var claudeNeedsYouWhileComposing = false
    /// Why Return didn't send: a prompt is up in this session's terminal,
    /// where the text would answer it. The field and the draft stay.
    @Published private(set) var replyRefusal: String?
    /// Held back: the eased revert to Ready, a request to refresh, queued
    /// rows Claude has taken.
    private var heldIdleRevert = false
    private var heldRequestRefresh = false
    private var heldQueueRemovals: [(session: String, id: UUID)] = []

    private func noteHeldNeedsYou(_ state: ClaudeCodeState) {
        if state.isAttention, !claudeNeedsYouWhileComposing { claudeNeedsYouWhileComposing = true }
    }

    /// Applies what the face held back while the reply was written, once,
    /// with the usual animations.
    private func thawClaudeFace() {
        claudeNeedsYouWhileComposing = false
        replyRefusal = nil
        if let trails = heldTrails {
            heldTrails = nil
            if trails != claudeTrails { withAnimation(.easeOut(duration: 0.22)) { claudeTrails = trails } }
        }
        if let held = heldStatus {
            heldStatus = nil
            applyClaudeStatus(held.status, announce: held.announce)
        } else if heldIdleRevert {
            heldIdleRevert = false
            scheduleIdleRevert(after: 0)
        }
        heldIdleRevert = false
        if heldRequestRefresh {
            heldRequestRefresh = false
            refreshPendingRequest()
        }
        let removals = heldQueueRemovals
        heldQueueRemovals = []
        if !removals.isEmpty {
            withAnimation(.easeOut(duration: 0.22)) {
                for removal in removals {
                    queuedReplies[removal.session]?.removeAll { $0.id == removal.id }
                    if queuedReplies[removal.session]?.isEmpty == true { queuedReplies[removal.session] = nil }
                }
            }
        }
        readTurnPrompts()
    }

    /// Reply drafts by session id, so text typed for one session never goes
    /// to another when the island moves on — it waits for its own session.
    @Published private var replyDrafts: [String: String] = [:]

    /// Text for the pending request ("Type something", "No, and tell
    /// Claude…"). Cleared when the request changes: its question is gone.
    @Published var answerDraft = ""
    @Published var denialDraft = ""

    /// What happened to the last reply, as far as Isle can vouch for it.
    @Published private(set) var replyDelivery: ReplyDelivery = .none

    /// Watches the transcript for a sent reply to land. Cancelled by a newer
    /// send or a session change.
    private var deliveryTask: Task<Void, Never>?

    /// A reply Isle typed while Claude was mid-turn, which Claude Code has
    /// queued: the transcript's `queue-operation` "enqueue" for its text
    /// says so. Claude takes queued prompts at its next tool boundary (or
    /// when the turn ends), writing "remove"; the row goes then. Measured
    /// on Claude Code 2.1.321: the queued text reaches the model as a
    /// `queued_command` in the same turn, every queued prompt at once, and
    /// `UserPromptSubmit` fires as it's typed rather than when it's taken —
    /// so the transcript is the one thing that says it was taken.
    struct QueuedReply: Identifiable, Equatable {
        let id: UUID
        let text: String
        /// When Claude Code queued it, by the transcript.
        let queuedAt: Date
    }

    /// Each session's queued replies, oldest first. Only what Isle typed and
    /// saw Claude Code queue; in memory, gone with the session.
    @Published private(set) var queuedReplies: [String: [QueuedReply]] = [:]

    /// The island's session's queued replies.
    var claudeQueued: [QueuedReply] {
        claudeSessionId.flatMap { queuedReplies[$0] } ?? []
    }

    /// Watches the transcript for each queued reply to be taken.
    private var queueWatches: [UUID: Task<Void, Never>] = [:]

    /// How much taller than one line the reply field is drawn, as the face
    /// last measured it: the panel grows by this while composing.
    @Published private(set) var replyFieldExtra: CGFloat = 0

    func setReplyFieldExtra(_ extra: CGFloat) {
        let rounded = max(0, extra.rounded())
        guard rounded != replyFieldExtra else { return }
        replyFieldExtra = rounded
    }

    /// The face the user last went into. Backed by AppSettings so it survives
    /// relaunch. Display may override this during an interrupt — see
    /// `expandedPlace`.
    @Published var activeTab: IsleTab {
        didSet {
            guard activeTab != oldValue else { return }
            settings.lastTab = activeTab
        }
    }

    /// The user last went back to the home grid rather than into a face, so
    /// that's where the panel opens. Persisted with `activeTab`: together
    /// they're the last place chosen. Only the user's own moves write either
    /// — a takeover shows Claude without touching them.
    @Published private(set) var isHome: Bool {
        didSet {
            guard isHome != oldValue else { return }
            settings.lastOnHome = isHome
        }
    }

    @Published private(set) var media = MediaPlaybackModel()

    /// Colours pulled from the current cover, recomputed only when the cover
    /// itself changes.
    ///
    /// This is cached rather than derived in the view because extraction is
    /// not stable under re-running. It picks `ranked[0]` winner-take-all, and
    /// on real covers the top cells are separated by well under 1% — the
    /// current one by 0.7%. Two artwork sources feed this (the adapter's
    /// embedded bytes and Spotify's CDN fetch) and their decodes differ
    /// slightly, so re-deriving could hand back a different winner each time
    /// and the notch visibly flashed between colours. Held steady here, the
    /// selection runs once per cover and the near-tie stops mattering.
    ///
    /// It also has to be cached for cost: as a computed property on the view
    /// it re-ran on every body evaluation, which is 30 times a second now that
    /// audio levels publish at display rate.
    /// Colours pulled from the current album art, or nil when there is no
    /// artwork to pull from.
    @Published private(set) var artworkPalette: ArtworkPalette?

    /// The palette everything draws from.
    ///
    /// Artwork wins whenever there is any. Without it — a Claude-only island,
    /// or music with no cover — the user's accent supplies one instead, which
    /// is the whole point of `ClaudeAccent`: `ArtworkColors.palette(from: nil)`
    /// returns three greys, and a `.palette` marker drawn from those is the
    /// flat look the accent exists to replace.
    var palette: ArtworkPalette {
        artworkPalette ?? settings.claudeAccentPalette
    }

    /// Identity of the cover `palette` was built from, to skip the work when
    /// an update carries the same image.
    private var paletteArtwork: NSImage?

    /// Position the user is dragging the scrubber to. Non-nil only mid-drag;
    /// while set, the scrubber renders this instead of the live position so
    /// the thumb doesn't fight the playback clock under the finger.
    @Published var scrubTarget: Double?

    /// The audio outputs and the system default, for the music face's output
    /// switcher. Handed out whole like `audioLevelSource`, so a device
    /// coming or going redraws the switcher alone; it listens to the HAL
    /// only while that face is on screen.
    let outputDevices = OutputDevices()

    /// What's left of today — events still to come or in progress, and
    /// reminders due by the end of the day — as `AgendaMonitor` last reported
    /// it. Empty when both agenda switches are off. Drawn by the agenda face
    /// of the expanded panel.
    @Published private(set) var agendaItems: [AgendaItem] = []

    private let settings: AppSettings
    private let adapter = MediaRemoteAdapterClient()
    /// One controller per supported player, in cold-start preference order.
    /// Commands go to the one whose track the island is showing — see
    /// `routedPlayer` — never to a fixed app.
    private let players: [MediaPlayerController] = [SpotifyController(), AppleMusicController()]
    private let audio = SystemAudioLevels()
    private let claudeWatcher = ClaudeStatusWatcher()
    private let requestWatcher = ClaudeRequestWatcher()
    private let sessionRegistry = ClaudeSessionRegistry()
    /// Agent view's background sessions (Milestone 21), read on a cue.
    private let agentsMonitor = ClaudeAgentsMonitor()
    private let keepAwake = ClaudeKeepAwake()
    private let power = PowerMonitor()
    private let bluetoothBattery = BluetoothBatteryMonitor()
    private let agenda: AgendaMonitor
    private var cancellables = Set<AnyCancellable>()

    /// The Pomodoro clock. Always constructed (it's cheap and idle until
    /// started) but only *offered* while `settings.pomodoroEnabled` is on —
    /// see `pomodoroAvailable`. Turning the setting off resets it.
    let pomodoro: PomodoroTimer

    /// Files and folders kept within reach. Offered as a face only while it
    /// holds something — see `availableTabs`.
    let shelf: ShelfStore

    /// The agenda face's days, ticks and quick-add. Observed by the face
    /// itself rather than forwarded through this model: none of it changes
    /// anything outside that face.
    let agendaModel: AgendaModel

    /// A drag carrying files is in flight somewhere on screen, as
    /// `FileDragWatch` reads it off the global mouse events and the drag
    /// pasteboard. Drives the drop notice.
    @Published private(set) var fileDragInFlight = false

    /// What the drag over an island carries, read off the drag's own
    /// pasteboard as it reached the island. Nil while no island is a drop
    /// target.
    @Published private(set) var dropPayload: DropPayload?

    /// True between `start()` and `stop()` — i.e. while the notch window is
    /// shown. Guards the live mode-change subscription so it doesn't spin up
    /// subsystems while the overlay is hidden.
    private var isRunning = false

    /// Whether the media subsystems (adapter, Spotify, audio) are currently
    /// live. Tracked so a mode change only toggles the delta rather than
    /// restarting an already-running capture.
    private var mediaRunning = false
    private var audioRunning = false

    /// Whether the Claude status watcher is currently live.
    private var claudeRunning = false

    /// Whether each power monitor is currently live. Tracked separately
    /// because the two settings are independent.
    private var powerRunning = false
    private var deviceBatteryRunning = false

    /// Reverts a `done` glyph back to `idle` after a beat, so the checkmark
    /// reads as a toast rather than sticking until the next prompt. Cancelled
    /// if any other status arrives first. Also times out a lingering
    /// `needs_question` (see `applyClaudeStatus`).
    private var doneRevertTask: Task<Void, Never>?

    /// How long a `needs_question` lingers before easing back to idle, so a
    /// declined or ignored terminal question can't wedge the island on
    /// "Question". Long enough to notice; short enough that an abandoned one
    /// clears on its own.
    private static let questionRevertSeconds: TimeInterval = 45

    /// How long the `compacting` glyph runs before easing back to idle. Only the
    /// `PreCompact` hook fires — Claude Code emits nothing when compaction ends
    /// or is cancelled — so without this a cancelled compact animates forever.
    /// A finished compaction is normally cleared sooner by the next real event
    /// (a tool call / prompt); this is the backstop for the cancelled/idle case.
    private static let compactingRevertSeconds: TimeInterval = 25

    /// Every session that currently has a status file, as last published by
    /// the watcher. Retained so selection can be re-run when the *registry*
    /// changes without waiting for a status write.
    private var claudeStatuses: [ClaudeStatus] = []

    /// Picks which session owns the island.
    ///
    /// Not "most recent": that was the old single-file behaviour and it's what
    /// let a background session's `Stop` or idle notification wipe the session
    /// the user was watching. Rank by how much the state wants attention, and
    /// only break ties by recency — so a quiescent session can never displace
    /// an active one, however recently it moved (`ClaudeSelection.ranked`).
    ///
    /// Except for a session the user picked from the list, which holds the
    /// island until another session newly needs them, or it goes away (see
    /// `ClaudeSelection.Pin`). Settles the pin as it goes.
    private func selectStatus(from statuses: [ClaudeStatus]) -> ClaudeStatus {
        var pin = sessionPin
        // A pin needs a process the registry can see — never a leftover file
        // — or a background session agent view still lists (Milestone 21).
        if let held = pin, !claudeSessions.contains(where: { $0.sessionId == held.sessionId }),
           backgroundMerge.agentOnly(held.sessionId) == nil {
            pin = nil
        }
        let selection = ClaudeSelection.select(from: selectionPool(statuses, pinned: pin?.sessionId), pin: pin)
        if sessionPin != selection.pin { sessionPin = selection.pin }
        return selection.status
    }

    /// The records selection chooses between, corrected.
    ///
    /// A background session only agent view knows of (Milestone 21) is in
    /// the pool only while it's the one pinned: it is listed and counted,
    /// but never takes the island by itself — its state comes from a read on
    /// a cue, not an event there is a moment to announce, and a session
    /// blocked for days would otherwise hold the island for days.
    private func selectionPool(_ statuses: [ClaudeStatus], pinned: String? = nil) -> [ClaudeStatus] {
        // Drop records whose process is gone. Skipped entirely while the
        // registry is empty (not yet scanned, or ~/.claude/sessions missing),
        // since filtering against nothing would blank the island.
        let live = claudeSessions.isEmpty ? statuses : statuses.filter { status in
            guard let id = status.sessionId else { return true }
            return claudeSessions.contains { $0.sessionId == id }
        }
        // A record's agents only while its process lives: one killed outright
        // fires no SessionEnd to clear them (Milestone 22). Only against a
        // registry that has been read: before the first pass, or with no
        // registry directory at all, nothing says a process is gone. An
        // empty registry that was read says every process is.
        let liveIds = Set(claudeSessions.map(\.sessionId))
        let pool = (live.isEmpty ? statuses : live).map(reconciled).map(backgroundMerge.resolve).map { status in
            guard claudeRegistryRead else { return status }
            var status = status
            status.subagents = ClaudeSubagents.counted(status.subagents, sessionId: status.sessionId, live: liveIds)
            return status
        }
        if let pinned, !pool.contains(where: { $0.sessionId == pinned }),
           let background = backgroundMerge.agentOnly(pinned) {
            return pool + [background]
        }
        return pool
    }

    /// Corrects a `working` record the hooks will never close out.
    ///
    /// Every exit from `working` is hook-driven — `Stop`, `SessionEnd`, a
    /// notification — and an *interrupt fires none of them*. Pressing ESC ends
    /// the turn silently, so the last `UserPromptSubmit` / `PreToolUse` write
    /// stays the newest thing on disk and the session sits at `working`
    /// forever. Because `working` outranks every quiescent state, that record
    /// also keeps the island away from whichever session is genuinely live. A
    /// hook that failed to run leaves exactly the same residue.
    ///
    /// Two independent signals have to agree before overriding the file, since
    /// getting this wrong blanks a session that really is thinking: the CLI's
    /// own record must no longer call the session busy, and its transcript must
    /// show the turn already closed. The second is what keeps a retry storm
    /// intact — a backing-off session reports `idle` too, but its transcript
    /// still owes a response.
    ///
    /// Except when the transcript carries the interrupt marker, which decides
    /// it on its own — see below.
    private func reconciled(_ status: ClaudeStatus) -> ClaudeStatus {
        if status.state.isAttention {
            return reconciledPrompt(status)
        }
        guard status.state == .working,
              let id = status.sessionId,
              let session = claudeSessions.first(where: { $0.sessionId == id }),
              // No readable transcript is no second signal — leave the record
              // alone rather than guess.
              let tail = transcriptTails[id]
        else {
            return status
        }

        // The marker is written for one reason only — the user ended the turn —
        // so it outranks everything else we could ask, and it is the *only*
        // thing that can retire a record frozen mid-tool. An interrupt during a
        // tool call fires neither PostToolUse nor Stop, so `tool_active` stays
        // true on disk forever; and since a tool that is genuinely still
        // running leaves identical residue (working, tool active, and the CLI
        // reporting idle while it waits), nothing weaker is safe to act on.
        // Typing the next prompt supersedes this immediately: that writes a
        // fresh `working` record and puts a new user turn at the tail.
        if !tail.interrupted {
            guard !status.toolActive,
                  session.status.isAtPrompt,
                  !tail.awaitingModel
            else {
                return status
            }
        }
        var corrected = status
        corrected.state = .idle
        corrected.action = nil
        corrected.target = nil
        // The turn is over without the Stop that says which agents outlived
        // it (isle-cli v18 keeps only those `background_tasks` lists), so
        // none are claimed: a background one may still run, but nothing here
        // can say so.
        corrected.subagents = []
        return corrected
    }

    /// Retires a prompt that was dismissed with Esc.
    ///
    /// Esc on Claude Code's permission dialog (or its question UI) interrupts
    /// the turn and fires no hook. It does cancel a hook blocked on the
    /// prompt — that much was verified — but the status file it leaves behind
    /// still says the prompt is up, and an approval has no revert timer, so
    /// without this the panel would sit open asking for something nobody is
    /// waiting on until the next prompt.
    ///
    /// Same evidence as the `working` case: the interrupt marker at the
    /// transcript's tail, which is written for no other reason. And never
    /// while a hook is still waiting under the status's request id — a live
    /// request is a prompt that is genuinely still up.
    private func reconciledPrompt(_ status: ClaudeStatus) -> ClaudeStatus {
        if let requestId = status.requestId, claudeRequests.contains(where: { $0.id == requestId }) {
            return status
        }
        guard let id = status.sessionId,
              claudeSessions.contains(where: { $0.sessionId == id }),
              let tail = transcriptTails[id],
              tail.interrupted
        else {
            return status
        }
        var corrected = status
        corrected.state = .idle
        corrected.action = nil
        corrected.target = nil
        corrected.requestId = nil
        corrected.subagents = []
        return corrected
    }

    /// Live sessions as the CLI itself reports them, hook-free. Ground truth
    /// for liveness: a session killed with SIGKILL fires no SessionEnd, and its
    /// pid simply stops existing here.
    ///
    /// Not published: no view reads it, and it changes with every CLI status
    /// flip, so publishing it would invalidate the whole notch on each one for
    /// nothing. Selection re-runs with each read and publishes through
    /// `claudeState` only when the result differs.
    ///
    /// Only as fresh as the last background read — the directory watch sees
    /// sessions start and exit, not status changes — so every selection path
    /// re-reads it first (`requestClaudeReading`).
    private var claudeSessions: [ClaudeSession] = []

    private var reselectTimer: Timer?

    /// Re-runs selection on a coarse timer while a state that claims work is in
    /// progress is showing.
    ///
    /// Nothing here measures silence. Isle has no signal that separates a long
    /// think from a stalled turn — both fire no hooks and write nothing — so it
    /// makes no claim either way, in text or in treatment, and the island holds
    /// the last state it was actually told about.
    ///
    /// The timer earns its place on the other job: nothing else re-examines a
    /// stuck record. An interrupt fires no hook, and the registry's directory
    /// watch can't see the CLI rewriting its record in place, so each tick
    /// re-reads the registry and re-selects.
    ///
    /// Also kept running while the keep-awake assertion is held, or the panel
    /// is counting other busy sessions, whatever the island shows: a session
    /// needing attention outranks one still working, so the island can sit on
    /// a state the timer ignores while a background session holds the Mac
    /// awake or is counted as working — and that session's interrupt or
    /// SIGKILL is only ever noticed by a tick. And while the session list is
    /// up, whose every row is subject to the same.
    ///
    /// A prompt dismissed with Esc is the same kind of stuck record — no hook
    /// fires — so the attention states ride along (see `reconciledPrompt`).
    private func updateReselectTimer(for state: ClaudeCodeState) {
        // Agents counted past their turn (Milestone 22) are work in progress
        // too: their session being killed outright is only seen by a tick.
        guard keepAwake.isHeld || !hookOthersQuiet || sessionListShown
                || state == .working || state == .compacting || state == .waitingInput
                || state.isAttention || !claudeSubagents.isEmpty else {
            stopReselectTimer()
            return
        }
        guard reselectTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // The registry's watch misses in-place rewrites and killed
                // pids, so the tick is also what keeps it current. Applied
                // only on a real change of state, so an unchanged one doesn't
                // re-render the island every tick.
                self?.requestClaudeReading(.tick)
            }
        }
        // Coarse by design, so it can afford to be coalesced with whatever
        // else wakes the process.
        timer.tolerance = 1
        reselectTimer = timer
    }

    // MARK: - Reading Claude's state, off the main thread

    /// The transcript's last conversation entry, as `reconciled` needs it.
    struct TranscriptTail: Equatable {
        /// A `user` turn the model still owes a response to.
        let awaitingModel: Bool
        /// The marker an interrupt (Esc) leaves.
        let interrupted: Bool
        let at: Date
    }

    /// One background pass: the registry, and the transcript tail of every
    /// session whose record reconciliation may have to correct.
    private struct ClaudeReading {
        let sessions: [ClaudeSession]
        let tails: [String: TranscriptTail]
        /// The registry's directory was there to read: an empty `sessions`
        /// then means no Claude Code process is alive, not that there was
        /// nothing to look at.
        var registryRead = true
    }

    /// Whether the last pass read a registry directory — see
    /// `ClaudeReading.registryRead`. Until one has, a session's agents can't
    /// be checked against its process.
    private var claudeRegistryRead = false

    /// Each live session's transcript tail, as the last background pass read
    /// it. Only for the sessions `reconciled` consults — working, or showing a
    /// prompt no hook is waiting on. Selection reads this, never the disk.
    private var transcriptTails: [String: TranscriptTail] = [:]

    /// Where the registry and transcript tails are read. Serial, so passes
    /// finish in the order they were asked for.
    private let claudeReadQueue = DispatchQueue(label: "isle.claude-read", qos: .utility)

    /// Bumped by every pass asked for, and when the bridge stops. A pass
    /// applies only if it is still the newest when it lands: the newest
    /// event always wins, and a pass that read the disk before it never
    /// overwrites one that read it after.
    private var claudeReadGeneration = 0

    /// Whether a pending pass was asked for by an event, which applies
    /// whatever selection resolves, rather than by the tick alone, which
    /// applies only a change of state. Survives a superseded pass, so an
    /// event's apply can't be lost to a tick that overtook it.
    private var claudeReadWantsApply = false

    private enum ClaudeReadCause { case event, tick }

    /// Re-reads the registry and the transcript tails off the main thread,
    /// then re-runs selection on the main thread with what it found. Every
    /// path that used to re-select in place — a status, a request, the
    /// registry, the tick — comes through here, so the decoding and the
    /// transcript parsing (megabytes of JSON lines, `split` and all) never
    /// run on the main thread.
    private func requestClaudeReading(_ cause: ClaudeReadCause = .event) {
        guard claudeRunning else { return }
        claudeReadGeneration += 1
        if cause == .event { claudeReadWantsApply = true }
        let generation = claudeReadGeneration
        let statuses = claudeStatuses
        let waitingRequests = Set(claudeRequests.map(\.id))
        let registryURL = sessionRegistry.directoryURL
        claudeReadQueue.async { [weak self] in
            let reading = Self.readClaude(statuses: statuses, waitingRequests: waitingRequests,
                                          registryURL: registryURL)
            Task { @MainActor in
                self?.applyClaudeReading(reading, generation: generation)
            }
        }
    }

    /// The read itself, on `claudeReadQueue`.
    nonisolated private static func readClaude(statuses: [ClaudeStatus], waitingRequests: Set<String>,
                                               registryURL: URL) -> ClaudeReading {
        let sessions = ClaudeSessionRegistry.scan(registryURL)
        var isDirectory: ObjCBool = false
        let registryRead = FileManager.default.fileExists(atPath: registryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
        var tails: [String: TranscriptTail] = [:]
        for status in statuses where status.state == .working || status.state.isAttention {
            guard let id = status.sessionId, tails[id] == nil,
                  let session = sessions.first(where: { $0.sessionId == id })
            else { continue }
            // A prompt a hook is still blocked on is up for certain; its
            // transcript has nothing to add (see `reconciledPrompt`).
            if status.state.isAttention, let request = status.requestId, waitingRequests.contains(request) {
                continue
            }
            tails[id] = transcriptTail(cwd: session.cwd, sessionId: id)
        }
        return ClaudeReading(sessions: sessions, tails: tails, registryRead: registryRead)
    }

    private func applyClaudeReading(_ reading: ClaudeReading, generation: Int) {
        // A newer pass is on its way, or the bridge stopped since.
        guard claudeRunning, generation == claudeReadGeneration else { return }
        let applyAny = claudeReadWantsApply
        claudeReadWantsApply = false

        let sessionsChanged = reading.sessions != claudeSessions
        // A background session's process starting, exiting or changing its
        // status is a cue to ask agent view what that means (Milestone 21).
        if reading.sessions.filter(\.isBackground) != claudeSessions.filter(\.isBackground) {
            agentsMonitor.cue()
        }
        claudeSessions = reading.sessions
        claudeRegistryRead = reading.registryRead
        transcriptTails = reading.tails
        updateBackgroundMerge()

        // A request that came or went shows (or retires) its buttons here,
        // after the same hops as the status that goes with it — so a click's
        // `working` and its request leaving land in the order they were
        // written, and the bare prompt never flashes between them.
        refreshPendingRequest()
        let resolved = selectStatus(from: claudeStatuses)
        // Agents going with their session's process change no state.
        if applyAny || resolved.state != claudeState || resolved.subagents != claudeSubagents {
            applyClaudeStatus(resolved)
        }
        updateKeepAwake()
        updateSessionList()
        syncIslandBackground()
        // The island's session may only now have a pid to resolve.
        if sessionsChanged { updateSessionHost() }
    }

    // MARK: - Background sessions (Milestone 21)

    /// A new read of `claude agents`. Applied like a reading: the merge,
    /// then selection, the counts and the list — and only when it changes
    /// what the merge says, so an unchanged read costs nothing more.
    private func receiveAgents(_ agents: [ClaudeAgent]) {
        let now = Date()
        backgroundFinishedAt = ClaudeBackground.noteFinishes(
            previous: claudeAgents, current: agents, finishedAt: backgroundFinishedAt, now: now)
        claudeAgents = agents
        guard claudeRunning else { return }
        let before = backgroundMerge
        updateBackgroundMerge(now: now)
        guard backgroundMerge != before else { return }
        let resolved = selectStatus(from: claudeStatuses)
        if resolved.state != claudeState || resolved.fromAgent != claudeStateFromAgent
            || resolved.sessionId != claudeSessionId {
            applyClaudeStatus(resolved)
        }
        updateKeepAwake()
        updateSessionList()
        syncIslandBackground()
    }

    /// Re-merges the last `claude agents` read with the bridge's sessions.
    /// Cheap and pure; run on every reading, since a hook record appearing
    /// or going changes which background sessions are agent view's alone.
    /// A finished session Isle saw finish drops off an hour later at the
    /// first reading after that — there's no timer for it.
    private func updateBackgroundMerge(now: Date = Date()) {
        var seen = Set<String>()
        let hookIds = claudeStatuses.compactMap { status -> String? in
            guard let id = status.sessionId, !seen.contains(id),
                  claudeSessions.contains(where: { $0.sessionId == id }) else { return nil }
            seen.insert(id)
            return id
        }
        backgroundMerge = ClaudeBackground.merge(
            hookSessionIds: hookIds, registry: claudeSessions, agents: claudeAgents,
            finishedAt: backgroundFinishedAt, now: now)
    }

    /// Publishes what agent view adds about the island's session.
    private func syncIslandBackground() {
        let info = claudeSessionId.flatMap { backgroundMerge.info[$0] }
        if claudeBackground != info { claudeBackground = info }
    }

    /// The transcript's last timestamped entry: whether it leaves the model
    /// owing a response, whether it's the marker an interrupt leaves behind,
    /// and when it was written.
    ///
    /// Reads only the tail of the file — transcripts run to megabytes and this
    /// is called on a timer. Entries without a timestamp (`file-history-snapshot`
    /// and friends) are skipped rather than treated as the end, since they're
    /// interleaved with the real ones.
    ///
    /// Line by line from the end, on the bytes: the window's first line is
    /// cut short (and may start inside a multi-byte character, which made the
    /// whole window fail to decode as one string), and only the last few
    /// lines are ever needed.
    nonisolated static func transcriptTail(cwd: String, sessionId: String) -> TranscriptTail? {
        for line in transcriptLines(cwd: cwd, sessionId: sessionId) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  // Only conversation turns answer the question. The transcript
                  // is interleaved with bookkeeping — `queue-operation`,
                  // `attachment`, `system`, `file-history-snapshot` — and any of
                  // those landing after a prompt would otherwise mask it and
                  // make an unanswered turn look answered.
                  type == "user" || type == "assistant",
                  let stamp = object["timestamp"] as? String,
                  let at = transcriptDate(stamp)
            else { continue }
            // A `user` entry is either a fresh prompt or a tool result; both
            // leave the model owing output. An `assistant` entry means it has
            // already answered. The exception is an interruption: ESC appends a
            // synthetic `user` entry and fires no hook at all, so reading it as
            // an outstanding turn is precisely what pins the island on
            // `Thinking` with nothing running.
            let interrupted = type == "user" && isInterruption(object)
            return TranscriptTail(awaitingModel: type == "user" && !interrupted,
                                  interrupted: interrupted, at: at)
        }
        return nil
    }

    /// The complete lines in the last 64 KB of a session's transcript, newest
    /// first. Empty when there's no transcript to read.
    nonisolated private static func transcriptLines(cwd: String, sessionId: String) -> [Data] {
        guard let url = transcriptURL(cwd: cwd, sessionId: sessionId),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return [] }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return [] }
        let window: UInt64 = 64 * 1024
        let start = end > window ? end - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // Starting mid-file, the first line is a fragment.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines.reversed().map { Data($0) }
    }

    /// A session's transcript, as Claude Code files it: under
    /// ~/.claude/projects, in a folder named for the working directory with
    /// every character but an ASCII letter or digit turned into "-" (one per
    /// UTF-16 unit, as its JavaScript does). Only "/" used to be replaced
    /// here, so a session in a folder with a dot, an underscore or a space in
    /// its path — `~/.config`, `my_app`, `Side Projects` — had no transcript
    /// as far as Isle could see, and neither the interrupt check nor reply
    /// confirmation worked for it. A very long path is shortened by Claude
    /// Code with a hash on the end; that folder is found by its prefix.
    nonisolated static func transcriptURL(cwd: String, sessionId: String) -> URL? {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let slug = String(String.UnicodeScalarView(cwd.utf16.map { unit -> Unicode.Scalar in
            let scalar = Unicode.Scalar(UInt8(truncatingIfNeeded: unit))
            let alphanumeric = unit < 0x80
                && (("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar))
            return alphanumeric ? scalar : "-"
        }))
        let file = "\(sessionId).jsonl"
        let direct = projects.appendingPathComponent(slug).appendingPathComponent(file)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        guard slug.count > 100,
              let folders = try? FileManager.default.contentsOfDirectory(atPath: projects.path)
        else { return nil }
        let prefix = String(slug.prefix(100))
        for folder in folders where folder.hasPrefix(prefix) {
            let candidate = projects.appendingPathComponent(folder).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Whether a transcript entry is the marker Claude Code writes when the
    /// user interrupts a turn ("[Request interrupted by user]", and the
    /// "…for tool use" variant). It arrives as a `user` entry but terminates a
    /// turn rather than opening one.
    nonisolated private static func isInterruption(_ object: [String: Any]) -> Bool {
        guard let message = object["message"] as? [String: Any] else { return false }
        let texts: [String]
        if let text = message["content"] as? String {
            texts = [text]
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts = blocks.compactMap { $0["text"] as? String }
        } else {
            return false
        }
        return texts.contains { $0.hasPrefix("[Request interrupted") }
    }

    nonisolated private static func transcriptDate(_ string: String) -> Date? {
        // Formatters per call: this runs on the read queue and in reply
        // confirmation, and making one is cheap next to the read.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func stopReselectTimer() {
        reselectTimer?.invalidate()
        reselectTimer = nil
    }

    // MARK: - Keep awake

    /// Holds the keep-awake assertion exactly while the setting is on and at
    /// least one live session is working, and releases it on every other path.
    ///
    /// Read from the per-session records, not from `claudeState`: selection is
    /// urgency-ranked, so an approval or a failure in one session takes the
    /// island while another is still mid-turn — and that turn is the one that
    /// needs the Mac awake.
    ///
    /// Each record goes through `reconciled`, the same correction selection
    /// applies, so an interrupted turn stops holding the Mac awake at the
    /// moment the island stops calling it working — no second opinion about
    /// what a frozen `working` means. Liveness is stricter than selection's,
    /// though: selection falls back to every record when the registry is empty
    /// rather than blank the island, but a record with no live pid behind it is
    /// exactly the SIGKILL residue that would otherwise pin the Mac awake
    /// forever. Holding a power assertion needs a process Isle can see.
    private func updateKeepAwake() {
        let before = liveSessionStates
        liveSessionStates = readLiveSessionStates()
        announceBackgroundFinishes(since: before)
        let wasHeld = keepAwake.isHeld
        keepAwake.setHeld(settings.keepAwakeWhileWorking && claudeRunning
                          && liveSessionStates.values.contains(.working))
        publishKeepAwake()
        updateOtherSessions()
        // The tick is what notices a background session's interrupt or kill,
        // so it has to run for as long as the assertion does.
        if keepAwake.isHeld != wasHeld {
            updateReselectTimer(for: claudeState)
        }
    }

    /// Mirrors the assertion into `isKeepingAwake`, publishing only on a
    /// change. Called after every take or release, so the panel's mark can
    /// never outlive the hold or show before it.
    private func publishKeepAwake() {
        if isKeepingAwake != keepAwake.isHeld { isKeepingAwake = keepAwake.isHeld }
    }

    /// The reconciled state of every session the registry can vouch for,
    /// keyed by session id — the shared reading behind the keep-awake hold
    /// and the other-sessions count. Liveness is the strict kind (see
    /// `updateKeepAwake`): a record with no live pid behind it is left out,
    /// and so is one with no session id to check. Reconciling reads each
    /// working session's transcript tail, so this is done once per pass and
    /// kept in `liveSessionStates`.
    private func readLiveSessionStates() -> [String: ClaudeCodeState] {
        var states: [String: ClaudeCodeState] = [:]
        for status in claudeStatuses {
            guard let id = status.sessionId,
                  claudeSessions.contains(where: { $0.sessionId == id })
            else { continue }
            let corrected = status.state == .working || status.state.isAttention
                ? reconciled(status)
                : status
            // A finished turn Claude Code says is blocked (Milestone 21).
            states[id] = backgroundMerge.resolve(corrected).state
        }
        return states
    }

    /// A toast for each session the island isn't showing that has just
    /// finished a turn — from mid-turn to `done`, as its own `Stop` wrote it,
    /// never inferred. The island's own session says "Done" itself, and a
    /// turn that ended any other way (an interrupt reconciled to idle, an
    /// error) isn't a finish. Only between two readings that both saw the
    /// session, so nothing is announced at launch.
    private func announceBackgroundFinishes(since before: [String: ClaudeCodeState]) {
        let midTurn: Set<ClaudeCodeState> = [.working, .compacting, .needsApproval, .needsQuestion]
        for (id, state) in liveSessionStates where state == .done && id != claudeSessionId {
            guard let previous = before[id], midTurn.contains(previous) else { continue }
            let project = claudeStatuses.first { $0.sessionId == id }?.project
            enqueueToast(.sessionDone(sessionId: id, project: project.flatMap { $0.isEmpty ? nil : $0 }))
        }
    }

    /// A toast for each block auto mode has just made (Milestone 23), in any
    /// session, the island's own included: Claude carries on after one, so
    /// nothing else on the island would change. Only between two readings
    /// that both saw the session, so a block already on disk at launch (or
    /// when the bridge comes back) isn't announced as news. A live alert
    /// drops it, as it drops every toast; the face still has the line.
    func announceBlocks(in statuses: [ClaudeStatus]) {
        var next: [String: String] = [:]
        for status in statuses {
            guard let id = status.sessionId else { continue }
            let key = status.blocked?.key ?? ""
            next[id] = key
            guard let block = status.blocked, let before = seenBlocks[id], before != key else { continue }
            let project = id == claudeSessionId ? nil : status.project.flatMap { $0.isEmpty ? nil : $0 }
            enqueueToast(.autoModeBlocked(block, sessionId: id, project: project))
        }
        seenBlocks = next
    }

    /// The last `readLiveSessionStates`. Re-read with the keep-awake decision
    /// on every status, registry and tick; a re-selection in between only
    /// changes which session is excluded from `otherSessions`.
    private var liveSessionStates: [String: ClaudeCodeState] = [:]

    /// Recounts `otherSessions` from `liveSessionStates`, leaving out the
    /// session the island is showing. Publishes only on a change.
    ///
    /// The background sessions only agent view knows of (Milestone 21) are
    /// counted too, as Claude Code reports them — blocked needs you, working
    /// is working — but kept out of `hookOthersQuiet`, the tick's reason.
    private func updateOtherSessions() {
        var others = ClaudeOtherSessions()
        func count(_ state: ClaudeCodeState) {
            if state.isAttention {
                others.needYou += 1
            } else if state == .working || state == .compacting {
                others.working += 1
            }
        }
        var hookQuiet = true
        if claudeRunning {
            for (id, state) in liveSessionStates where id != claudeSessionId {
                count(state)
            }
            hookQuiet = others.isEmpty
            for status in backgroundMerge.agentOnly where status.sessionId != claudeSessionId {
                count(status.state)
            }
        }
        let wasQuiet = hookOthersQuiet
        hookOthersQuiet = hookQuiet
        if others != otherSessions { otherSessions = others }
        // A busy background session is only ever noticed going quiet by an
        // event or a tick — an interrupt fires no hook — so the tick runs
        // for as long as the count does.
        if hookQuiet != wasQuiet {
            updateReselectTimer(for: claudeState)
        }
    }

    // MARK: - Every session at once (Milestone 16)

    /// Rebuilds `sessionList` from the last reading. Liveness is the strict
    /// kind, as for the keep-awake hold: a record with no live pid behind it,
    /// or no session id to check one, is left out — the list never names a
    /// session Isle can't see running.
    ///
    /// Each record gets the corrections the island would make. `reconciled`
    /// first, so an interrupted turn doesn't list as working. Then the ones
    /// the face makes on a clock, because the hooks never close those states
    /// out: a question nothing is waiting on any more, a compaction, and a
    /// usage limit whose reset has passed all read as Ready once the island
    /// would have eased them there. Ranked after that, so a row sits where
    /// its own word puts it.
    ///
    /// A finished turn stays Done, with what Claude said, until the session
    /// moves again — the record says so, and the list is where you go to
    /// find out what each session did.
    ///
    /// Background sessions (Milestone 21) are merged in last: a live one
    /// keeps its hook row, with its own name and Claude Code's word where
    /// the hooks have none; one only agent view knows of gets a row of its
    /// own. Matched on session id, so nothing is listed twice.
    private func updateSessionList() {
        var rows: [ClaudeSessionRow] = []
        if claudeRunning {
            let now = Date()
            let live = claudeStatuses.filter { status in
                guard let id = status.sessionId else { return false }
                return claudeSessions.contains { $0.sessionId == id }
            }
            rows = ClaudeBackground.rows(live: live.map { eased(reconciled($0), at: now) },
                                         merge: backgroundMerge, request: request(for:))
        }
        if rows != sessionList { sessionList = rows }
        updateSessionHosts()
    }

    /// `status` as the island would be showing it at `now`, for the states
    /// it eases off on a clock (see `applyClaudeStatus`).
    private func eased(_ status: ClaudeStatus, at now: Date) -> ClaudeStatus {
        let age = status.updatedAt.map { now.timeIntervalSince($0) } ?? 0
        let stale: Bool
        switch status.state {
        case .needsQuestion: stale = age > Self.questionRevertSeconds && request(for: status) == nil
        case .compacting: stale = age > Self.compactingRevertSeconds
        case .failed: stale = status.errorType == "usage_limit" && (Self.limitEasesAt(status).map { $0 <= now } ?? false)
        default: stale = false
        }
        guard stale else { return status }
        var eased = status
        eased.state = .idle
        eased.action = nil
        eased.target = nil
        eased.requestId = nil
        eased.subagents = []
        return eased
    }

    /// The request a session's hook is blocked on, if its file is still
    /// there.
    private func request(for status: ClaudeStatus) -> ClaudeRequest? {
        guard let id = status.requestId else { return nil }
        return claudeRequests.first { request in
            request.id == id && (request.sessionId == nil || request.sessionId == status.sessionId)
        }
    }

    /// Flips the Claude face to the list. Coming from a session picked from
    /// it, that session stops holding the island: the list is the way back
    /// up, and the next pick pins afresh.
    func showSessionList() {
        guard settings.effectiveMode.showsClaude else { return }
        releasePin()
        sessionListShown = true
        updateReselectTimer(for: claudeState)
        updateSessionHosts()
        // What agent view says now, not when it last changed a file.
        agentsMonitor.cue()
    }

    /// Back from the list to the face, on whichever session selection has.
    func closeSessionList() {
        guard sessionListShown else { return }
        sessionListShown = false
        updateReselectTimer(for: claudeState)
    }

    /// A row was clicked: that session takes the face, and everything on it
    /// — the approval, the question, the reply — is for that session, until
    /// another session newly needs you or you go back.
    func pinSession(_ sessionId: String) {
        guard claudeSessions.contains(where: { $0.sessionId == sessionId })
                || backgroundMerge.agentOnly(sessionId) != nil,
              let pin = ClaudeSelection.pin(sessionId, in: selectionPool(claudeStatuses, pinned: sessionId))
        else { return }
        sessionPin = pin
        sessionListShown = false
        updateReselectTimer(for: claudeState)
        reselectQuietly()
    }

    /// Drops the pin, if there is one, and puts selection's own pick back.
    private func releasePin() {
        guard sessionPin != nil else { return }
        sessionPin = nil
        reselectQuietly()
    }

    /// Re-runs selection on what the last reading saw, for a change the user
    /// made rather than one a session made: no chime, and no panel popping
    /// open for an alert they have already seen in the list.
    private func reselectQuietly() {
        applyClaudeStatus(selectStatus(from: claudeStatuses), announce: false)
    }

    /// The panel closed: the list goes, and so does the pin. The island
    /// collapsed always means selection's own pick — a session picked once
    /// and forgotten mustn't keep a more pressing one off it.
    private func resetSessionList() {
        if sessionListShown {
            sessionListShown = false
            updateReselectTimer(for: claudeState)
        }
        releasePin()
    }

    /// Resolves where each listed session is, while the list is up. Off the
    /// main thread, once per pid; a session gone from the list takes its
    /// host with it.
    private func updateSessionHosts() {
        let listed = Set(sessionList.map(\.id))
        for id in sessionHosts.keys where !listed.contains(id) { sessionHosts[id] = nil }
        for id in sessionHostPIDs.keys where !listed.contains(id) { sessionHostPIDs[id] = nil }
        guard sessionListShown else { return }
        for row in sessionList {
            guard let pid = claudeSessions.first(where: { $0.sessionId == row.id })?.pid,
                  sessionHostPIDs[row.id] != pid
            else { continue }
            sessionHostPIDs[row.id] = pid
            sessionHosts[row.id] = nil
            let id = row.id
            Task.detached(priority: .utility) { [weak self] in
                let host = ClaudeHostResolver.resolve(cliPID: pid)
                await self?.receiveSessionHost(host, id: id, pid: pid)
            }
        }
    }

    private func receiveSessionHost(_ host: ClaudeSessionHost?, id: String, pid: pid_t) {
        guard sessionHostPIDs[id] == pid else { return }
        sessionHosts[id] = host?.app == nil ? nil : host
    }

    /// The app a row's Jump names, or nil when there's nowhere resolved. A
    /// background session with no terminal of its own (Milestone 21) jumps
    /// by attaching in Terminal, when its attach id is known.
    func jumpTarget(for sessionId: String) -> String? {
        sessionHosts[sessionId]?.app?.name
            ?? (backgroundMerge.info[sessionId]?.attachId != nil ? ClaudeLauncher.attachApp : nil)
    }

    /// Whether a row's Jump attaches (`claude attach`) rather than going to
    /// a terminal the session is already in.
    func jumpAttaches(_ sessionId: String) -> Bool {
        sessionHosts[sessionId]?.app == nil && backgroundMerge.info[sessionId]?.attachId != nil
    }

    /// A row's Jump: that session's tab, resolved again at the click — or,
    /// for a background session with no terminal, a Terminal window
    /// attached to it.
    func jumpToSession(_ sessionId: String) {
        if jumpAttaches(sessionId), let info = backgroundMerge.info[sessionId], let id = info.attachId {
            ClaudeLauncher.attach(id, in: info.cwd)
            return
        }
        guard let pid = claudeSessions.first(where: { $0.sessionId == sessionId })?.pid,
              sessionHosts[sessionId] != nil
        else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let host = ClaudeHostResolver.resolve(cliPID: pid)
            await self?.receiveSessionHost(host, id: sessionId, pid: pid)
            guard let host, host.app != nil else { return }
            _ = await TerminalBridge.jump(to: host)
        }
    }

    // MARK: - Working words

    /// A rotating "thinking" word shown in the expanded view while working,
    /// echoing the Claude Code CLI's spinner (the real word isn't exposed to
    /// hooks, so this is our own set in the same spirit). Stored bare — the
    /// trailing "…" is added where it's displayed, since the collapsed label
    /// drops it when a duration follows the word.
    @Published private(set) var workingWord: String = "Working"

    private var workingWordTimer: Timer?
    private var workingWordIndex = 0

    private static let workingWords = [
        "Thinking", "Coalescing", "Percolating", "Ruminating", "Cogitating",
        "Simmering", "Pondering", "Noodling", "Churning", "Brewing",
        "Conjuring", "Wrangling", "Synthesizing", "Contemplating", "Marinating",
        "Deliberating", "Computing", "Puzzling", "Finagling", "Vibing",
    ]

    private func startWorkingWords() {
        guard workingWordTimer == nil else { return }
        workingWordIndex = Int.random(in: 0..<Self.workingWords.count)
        workingWord = Self.workingWords[workingWordIndex]
        let timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.claudeFaceFrozen else { return }
                self.workingWordIndex = (self.workingWordIndex + 1) % Self.workingWords.count
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.workingWord = Self.workingWords[self.workingWordIndex]
                }
            }
        }
        // Nobody is counting the seconds between "Coalescing" and "Percolating".
        timer.tolerance = 2
        workingWordTimer = timer
    }

    private func stopWorkingWords() {
        workingWordTimer?.invalidate()
        workingWordTimer = nil
    }

    // MARK: - Settings passthrough

    /// Show the seekable scrubber in the expanded panel (Settings).
    var showScrubber: Bool { settings.showScrubber }

    /// Show the shuffle/repeat toggles in the expanded panel (Settings).
    var showShuffleRepeat: Bool { settings.showShuffleRepeat }

    /// Focus intervals per Pomodoro cycle (Settings), for the tally dots.
    var pomodoroSessionsPerCycle: Int { settings.pomodoroSessionsPerCycle }

    // The now-playing sources, kept separately and merged in
    // `recomputeSource`. The adapter (MediaRemote) is preferred when a
    // supported player owns the system session — it pushes updates and ships
    // artwork as bytes. The per-player AppleScript polls are the fallback for
    // when something else (a browser tab, say) owns the session, so the notch
    // still shows the player.
    private var adapterModel = MediaPlaybackModel()
    /// Each player's latest poll, keyed by bundle id. Absent when that player
    /// isn't running or is stopped.
    private var pollModels: [String: MediaPlaybackModel] = [:]
    private var lastApplied = MediaPlaybackModel()

    /// The player whose track the island is showing, by bundle id — the one
    /// every command is sent to. Nil while nothing is showing.
    private var routedPlayerID: String?

    /// The last player that was routed. Breaks the tie when both players are
    /// running with a track and neither is playing: the one the island was
    /// on stays, rather than a cold-start default displacing it.
    private var lastActivePlayerID: String?

    private var routedPlayer: MediaPlayerController? {
        players.first { $0.bundleID == routedPlayerID }
    }

    // After a manual transport action, trust the optimistic value and ignore
    // contradicting source reads until a source confirms it or this window
    // lapses — otherwise a stale 1 Hz poll flickers play/pause back and snaps
    // the scrubber to the pre-seek position, which reads as lag.
    private var pendingPlayState: Bool?
    private var pendingSeekTarget: TimeInterval?
    private var pendingShuffle: Bool?
    private var pendingRepeat: RepeatMode?
    private var pendingCommandDeadline: Date = .distantPast
    private static let commandGrace: TimeInterval = 1.5

    /// The live per-band magnitudes, handed out as the object that publishes
    /// them rather than as a republished array.
    ///
    /// Deliberately *not* mirrored into an `@Published` here. Levels change 30
    /// times a second, and republishing them on this view model invalidated
    /// every view observing it — which is the whole notch, including the shape
    /// sizing, the hit rect and the Claude glyph, none of which depend on audio.
    /// Handing the source out directly means only the waveform itself (see
    /// `LiveEqualizer`) redraws on a level change. Empty levels mean capture
    /// isn't running, which EqualizerView reads as "use the procedural fallback".
    var audioLevelSource: SystemAudioLevels { audio }

    /// What the open panel is drawn on, as chosen in Settings — read here so
    /// a change re-renders the island through this model.
    var panelBackground: PanelBackground { settings.panelBackground }

    /// Whether glass grows black out of the notch — see `AppSettings`.
    var panelNotchGlow: Bool { settings.panelNotchGlow }

    /// The waveform source as chosen in Settings. The views read it here rather
    /// than from `AppSettings` so a change re-renders them through this model.
    var waveformSource: WaveformSource { settings.waveformSource }

    /// Whether a waveform is drawn at all. Off gives the bars' space back in
    /// the split layout and holds it in music-solo — see `waveSlot`.
    var showsWaveform: Bool { settings.waveformSource.isShown }

    /// Why audio capture isn't running, if it isn't.
    var audioFailureReason: String? { audio.failureReason }

    // `settings` defaults to the shared instance, resolved inside the
    // main-actor-isolated init body rather than as a default argument — a
    // default-argument reference to a main-actor static is a Swift 6 error.
    init(settings: AppSettings? = nil) {
        let resolvedSettings = settings ?? .shared
        self.settings = resolvedSettings
        self.activeTab = resolvedSettings.lastTab
        self.isHome = resolvedSettings.lastOnHome
        self.pomodoro = PomodoroTimer(settings: resolvedSettings)
        self.shelf = ShelfStore(settings: resolvedSettings)
        let agenda = AgendaMonitor()
        self.agenda = agenda
        self.agendaModel = AgendaModel(monitor: agenda)

        // The timer publishes on its own object; the island reads it through
        // this model, so forward its changes (they're at most once a second
        // apart from the phase rolls — the digits themselves tick off a
        // TimelineView, not off a publish).
        pomodoro.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // The shelf publishes on its own object too; its face, its tile and
        // whether it's in the grid at all read it through this model.
        shelf.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        shelf.$items
            .map(\.count)
            .removeDuplicates()
            .sink { [weak self] count in self?.fitShelfRows(count) }
            .store(in: &cancellables)

        pomodoro.onIntervalEnded = { [weak self] _ in
            guard let self, self.settings.pomodoroSoundEnabled else { return }
            self.settings.pomodoroSound.play()
        }

        // Switching the feature off takes the timer with it: a clock that kept
        // running behind a hidden tab would ring with nothing on screen to say
        // why. Also drops the user off the Pomodoro tab if they were on it.
        resolvedSettings.$pomodoroEnabled
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self, !enabled else { return }
                self.pomodoro.reset()
                if self.activeTab == .pomodoro {
                    self.activeTab = self.availableTabs.first ?? .music
                }
            }
            .store(in: &cancellables)

        adapter.onUpdate = { [weak self] model in
            guard let self else { return }
            let wasPlaying = self.adapterModel.isPlaying
            self.adapterModel = model
            // For a track both sources can see, the poll — not the adapter —
            // supplies `isPlaying` (see `recomputeSource`), and a collapsed
            // island reads that poll only every third second. So a play
            // pressed anywhere but in the panel — Spotify's own button, a
            // media key, a phone on Spotify Connect — took up to three
            // seconds to be believed. Nothing on a collapsed island shows
            // the transport, so the only visible symptom was the waveform:
            // past the pause grace the tap is suspended, and it is this flag
            // that resumes it, so the bars stayed dots for those seconds
            // while music played. The adapter hears the change in ~100ms;
            // take that as the cue to read the truth now rather than at the
            // next relaxed tick.
            if model.isPlaying != wasPlaying {
                self.players.first { $0.bundleID == model.bundleIdentifier }?.pollNow()
            }
            // The adapter losing the track is the moment a poll's model — and
            // so its cover — becomes the one on screen. `recomputeSource`
            // fetches any cover the routed player's poll held back while the
            // adapter was supplying one; see `wantsArtwork` below.
            self.recomputeSource()
        }
        for player in players {
            let id = player.bundleID
            player.onUpdate = { [weak self] model in
                guard let self else { return }
                self.pollModels[id] = model
                self.recomputeSource()
            }
            // A poll's cover is only drawn when its player is the one the
            // island is routed to and the adapter isn't supplying the track
            // (`recomputeSource` prefers the adapter's model whole, artwork
            // included). Fetching it otherwise was a download — or, for
            // Music, an Apple-event blob — and a decode per track change that
            // never reached the screen. "Routed to nobody" counts as yes: the
            // first poll to show a track is about to become the island.
            player.wantsArtwork = { [weak self] in
                guard let self else { return false }
                return !self.adapterModel.hasTrack
                    && (self.routedPlayerID == nil || self.routedPlayerID == id)
            }
            // Full rate while this player's poll is the only source (the
            // adapter has no track — a browser owns the session), or while a
            // panel is open and its scrubber and toggles are actually drawn
            // from it. Otherwise the adapter pushes every change a collapsed
            // island shows, and the poll can relax — see `tick` in either
            // controller. A player the island isn't routed to always relaxes —
            // including when nothing is routed at all, so an open-but-stopped
            // player isn't sent an Apple event every second for nothing. It
            // only needs to be noticed if it starts playing: the adapter hears
            // that in ~100ms when the player takes the session, and three
            // seconds is soon enough when a browser holds it. Hovering an
            // empty island still asks every player at once.
            player.wantsFullRate = { [weak self] in
                guard let self else { return false }
                guard self.routedPlayerID == id else { return false }
                return !self.adapterModel.hasTrack
                    || self.hoveredIslands > 0
                    || self.autoExpandsForActivity
            }
        }

        claudeWatcher.onStatuses = { [weak self] statuses in
            guard let self else { return }
            self.claudeStatuses = statuses
            self.announceBlocks(in: statuses)
            self.followTrails(statuses)
            // Selection reads the registry's `status` and session ids, which
            // the CLI rewrites in place where the registry's watch can't see
            // it, so the read re-scans it: a snapshot left at `idle` from
            // before the prompt makes `reconciled` retire a turn that is still
            // running, and one holding an outdated session id would filter the
            // live session out.
            self.requestClaudeReading()
        }

        requestWatcher.onRequests = { [weak self] requests in
            guard let self else { return }
            self.claudeRequests = requests
            // A request that disappears with no status write behind it is a
            // hook Claude Code cancelled — Esc on its prompt. Re-select so an
            // interrupted prompt stops asking (see `reconciledPrompt`); the
            // reselect timer catches it if the transcript marker lands after
            // this. The buttons themselves update when the read lands.
            self.requestClaudeReading()
        }

        sessionRegistry.onChange = { [weak self] in
            // A session dropping out of the registry is dead for real — its pid
            // is gone. A clean exit removes its status file too, but a SIGKILL
            // fires no SessionEnd, so the file lingers and no status event will
            // ever arrive. Re-running selection here is what retires it.
            self?.requestClaudeReading()
        }

        agentsMonitor.onAgents = { [weak self] agents in
            self?.receiveAgents(agents)
        }

        power.onEvent = { [weak self] toast in
            self?.enqueueToast(toast)
        }

        // Plugging in is the one moment a flat pair of headphones is worth
        // mentioning unprompted — you are sitting down to charge things.
        // Peripheral levels can't be watched (only read, at the cost of a
        // subprocess), so this is the cue to go and look.
        power.onPluggedIn = { [weak self] in
            guard let self, self.settings.showDeviceBattery else { return }
            self.bluetoothBattery.refreshLowDevices()
        }

        bluetoothBattery.onDeviceConnected = { [weak self] device in
            self?.enqueueToast(.device(device))
        }

        bluetoothBattery.onLowDevice = { [weak self] device in
            self?.enqueueToast(.device(device))
        }

        agenda.onEvent = { [weak self] toast in
            self?.enqueueToast(toast)
        }

        agenda.onAgendaChanged = { [weak self] items in
            guard let self, self.agendaItems != items else { return }
            self.agendaItems = items
            self.agendaModel.listChanged(items)
        }

        agenda.onDaysChanged = { [weak self] days in
            self?.agendaModel.update(days: days)
        }

        agendaModel.onAdded = { [weak self] in
            guard self?.composing == .quickAdd else { return }
            self?.endCompose()
        }

        // The tap only earns its keep while something is playing. Paused, the
        // bars rest at zero whether or not anything is listening, so the
        // capture is told to stand down — see `SystemAudioLevels.setPlaybackPaused`
        // for what that saves. `hasTrack` is folded in so "nothing playing at
        // all" counts as paused too.
        $media
            .map { $0.isPlaying && $0.hasTrack }
            .removeDuplicates()
            .sink { [weak self] playing in
                self?.audio.setPlaybackPaused(!playing)
            }
            .store(in: &cancellables)

        // Re-render notch views on any settings change (waveform/scrubber
        // toggles etc.), since those views observe this view model, not
        // AppSettings directly. Mode changes are handled separately below so
        // they also restart subsystems.
        self.settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // React to a live mode change (Settings — Milestone 6): start or
        // stop the affected subsystems and re-derive the collapsed layout.
        self.settings.$mode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isRunning else { return }
                self.applyMode()
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // The power and agenda toggles start and stop their own monitors, the
        // same way mode does — turning the feature off should stop watching
        // IOKit, Bluetooth or EventKit, not just hide the toasts. The waveform
        // source rides the same path: leaving Live tears the tap down,
        // returning to it builds one (and, first time, asks).
        Publishers.MergeMany(
            self.settings.$showBatteryEvents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$showDeviceBattery.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$showCalendarEvents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$showReminders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$eventLeadMinutes.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$waveformSource.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            self.settings.$keepAwakeWhileWorking.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            // Puts down or picks up `run/answering`. Off releases every hook
            // that is waiting on the notch, back to its terminal prompt.
            self.settings.$answerFromNotch.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            guard let self, self.isRunning else { return }
            self.applyMode()
        }
        .store(in: &cancellables)
    }

    func start() {
        isRunning = true
        observeDisplayState()
        applyMode()
    }

    /// The termination path: stop everything, then give the audio teardown a
    /// bounded moment to land before the process exits. See
    /// `SystemAudioLevels.awaitTeardown`.
    func shutdown() {
        stop()
        audio.awaitTeardown()
    }

    func stop() {
        isRunning = false
        setAudioRunning(false)
        setMediaRunning(false)
        setClaudeRunning(false)
        setPowerRunning(battery: false, devices: false)
        agenda.configure(events: false, reminders: false, leadMinutes: settings.eventLeadMinutes)
        for (center, token) in displayObservers { center.removeObserver(token) }
        displayObservers.removeAll()
    }

    /// Brings the running subsystems in line with the active mode, and with
    /// whether there's a display awake to show any of it on.
    private func applyMode() {
        let media = settings.effectiveMode.showsMusic && !displayAsleep
        setMediaRunning(media)
        setAudioRunning(media && settings.waveformSource.capturesAudio)
        setClaudeRunning(settings.effectiveMode.showsClaude)
        updateKeepAwake()
        updateAnsweringMarker()
        // Power is ambient — it runs in every mode, gated only by its own two
        // toggles. Suppressed while the display is off for the same reason the
        // media pipeline is: nothing it produces could be seen.
        setPowerRunning(battery: settings.showBatteryEvents && !displayAsleep,
                        devices: settings.showDeviceBattery && !displayAsleep)
        // Ambient in the same way. Also stood down while the display is off:
        // a "Standup · in 5 min" that fires into a dark screen would be found
        // on wake as a stale claim, and the monitor drops those anyway.
        agenda.configure(events: settings.showCalendarEvents && !displayAsleep,
                         reminders: settings.showReminders && !displayAsleep,
                         leadMinutes: settings.eventLeadMinutes)

        // Anything already on screen that the user has just switched off
        // shouldn't sit out the rest of its four seconds.
        if let toast = activeToast, !allows(toast.gate) {
            clearToasts()
        }
    }

    /// Whether a message's governing switch is on. Each source answers to its
    /// own toggle — the Mac's battery and a peripheral's are separate
    /// questions about separate hardware, and the calendar and reminders are
    /// separate permissions.
    private func allows(_ gate: IslandToast.Gate) -> Bool {
        switch gate {
        case .macBattery: return settings.showBatteryEvents
        case .deviceBattery: return settings.showDeviceBattery
        case .calendar: return settings.showCalendarEvents
        case .reminders: return settings.showReminders
        case .fileDrag: return true
        case .claudeSessions: return claudeRunning
        }
    }

    // MARK: - Display sleep

    /// The screen is off or locked, so nothing the media pipeline produces can
    /// be seen.
    ///
    /// Worth gating on because the expensive half of that pipeline doesn't stop
    /// by itself. The marker's animation does — it's driven off the display,
    /// which isn't ticking — but audio capture is not: the tap keeps running,
    /// the FFT keeps running ~94 times a second, and the levels keep publishing
    /// at 30Hz, all to move a waveform on a dark screen. Music playing with the
    /// lid shut is the normal case for this, not an edge case.
    ///
    /// Note that occlusion is deliberately *not* part of this. The notch window
    /// is `.fullScreenAuxiliary` and sits above the menu bar, so it stays up over
    /// full-screen apps and is never covered — there is no occluded state to
    /// react to.
    private var displayAsleep = false

    private var displayObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Sleep and lock are watched separately because they're genuinely different
    /// events: locking the screen doesn't put the display to sleep, and the
    /// display sleeping doesn't lock. Either one means nobody can see the notch.
    private func observeDisplayState() {
        guard displayObservers.isEmpty else { return }

        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: Notification.Name, asleep: Bool) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setDisplayAsleep(asleep) }
            }
            displayObservers.append((center, token))
        }

        observe(workspace, NSWorkspace.screensDidSleepNotification, asleep: true)
        observe(workspace, NSWorkspace.screensDidWakeNotification, asleep: false)
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), asleep: true)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), asleep: false)
    }

    private func setDisplayAsleep(_ asleep: Bool) {
        guard asleep != displayAsleep else { return }
        displayAsleep = asleep
        guard isRunning else { return }
        applyMode()
    }

    private func setMediaRunning(_ running: Bool) {
        guard running != mediaRunning else { return }
        mediaRunning = running
        if running {
            adapter.start()
            players.forEach { $0.start() }
        } else {
            adapter.stop()
            players.forEach { $0.stop() }
        }
    }

    /// The audio tap runs on its own switch, apart from the rest of the media
    /// pipeline: it is the one piece that costs a permission prompt. Only the
    /// `.live` waveform asks for it — `.animated` and `.off` never build a
    /// tap, so macOS never asks, which is the whole point of those choices.
    private func setAudioRunning(_ running: Bool) {
        guard running != audioRunning else { return }
        audioRunning = running
        running ? audio.start() : audio.stop()
    }

    private func setClaudeRunning(_ running: Bool) {
        guard running != claudeRunning else { return }
        claudeRunning = running
        if running {
            claudeWatcher.start()
            requestWatcher.start()
            sessionRegistry.start()
            agentsMonitor.start()
            // The registry, even if no status file ever publishes.
            requestClaudeReading()
        } else {
            claudeWatcher.stop()
            requestWatcher.stop()
            sessionRegistry.stop()
            agentsMonitor.stop()
            claudeAgents = []
            backgroundFinishedAt = [:]
            backgroundMerge = .empty
            claudeBackground = nil
            claudeStateFromAgent = false
            hookOthersQuiet = true
            // Not watching means nothing to back the claim with.
            keepAwake.release()
            publishKeepAwake()
            liveSessionStates = [:]
            otherSessions = ClaudeOtherSessions()
            sessionList = []
            sessionListShown = false
            sessionPin = nil
            sessionHosts = [:]
            sessionHostPIDs = [:]
            // Drop any read still in flight.
            claudeReadGeneration += 1
            claudeReadWantsApply = false
            transcriptTails = [:]
            claudeSessions = []
            claudeRegistryRead = false
            claudeStatuses = []
            claudeRequests = []
            claudeRequestId = nil
            pendingRequest = nil
            answeredRequestId = nil
            isReviewingRemember = false
            questionTyped = [:]
            composing = nil
            sessionHost = nil
            sessionHostPID = nil
            deliveryTask?.cancel()
            deliveryTask = nil
            replyDelivery = .none
            lastAppliedStatus = nil
            doneRevertTask?.cancel()
            doneRevertTask = nil
            stopWorkingWords()
            stopReselectTimer()
            claudeState = .disconnected
            claudeProject = nil
            claudeSessionId = nil
            claudeAction = nil
            claudeTarget = nil
            claudeErrorType = nil
            claudeResetAt = nil
            claudeLimitKind = nil
            claudeLimitNext = nil
            claudeFinalLine = nil
            claudeSubagents = []
            claudeBlock = nil
            claudeLeftovers = nil
            seenBlocks = [:]
            claudeUpdatedAt = nil
        }
        updateAnsweringMarker()
    }

    /// Puts `run/answering` down exactly while the Claude bridge is running
    /// with "Answer from the notch" on, and picks it up otherwise — so a hook
    /// only ever blocks when there is a notch on screen that can answer it.
    /// Hiding the notch, a mode without Claude, and quitting all stop the
    /// bridge, and with it every wait.
    private func updateAnsweringMarker() {
        let answering = claudeRunning && settings.answerFromNotch
        guard answering != answeringMarkerWritten else { return }
        answeringMarkerWritten = answering
        if answering {
            ClaudeAnsweringMarker.write()
        } else {
            ClaudeAnsweringMarker.remove()
        }
    }

    /// Starts or stops each power monitor from its own switch.
    ///
    /// A switch that is off stops the watching, not just the drawing: there is
    /// no point paying for a signal whose only purpose is a message the user
    /// has said they don't want. Off means Isle isn't looking.
    ///
    /// That has one honest consequence worth knowing. The peripheral check on
    /// plug-in is cued by `PowerMonitor` — the charger event *is* the cue — so
    /// with battery updates off, device updates are connect-driven only. The
    /// alternative was keeping IOKit watched purely to serve the other switch,
    /// which is exactly the cost this is meant to avoid.
    private func setPowerRunning(battery: Bool, devices: Bool) {
        if battery != powerRunning {
            powerRunning = battery
            battery ? power.start() : power.stop()
        }

        if devices != deviceBatteryRunning {
            deviceBatteryRunning = devices
            devices ? bluetoothBattery.start() : bluetoothBattery.stop()
        }
    }

    /// The record most recently put through `applyClaudeStatus`, so a re-run
    /// of selection that lands on the same record is a no-op.
    ///
    /// Selection re-runs on every registry event, and the registry is
    /// rewritten whenever any session's CLI status changes — so without this
    /// an unchanged `done` record was re-applied on each of those, which
    /// restarted its revert timer, reset the "… ago" clock, and — once the
    /// checkmark had already eased back to idle — put it back on the island as
    /// if the turn had just finished again. Compared as a whole record: a
    /// genuine re-write carries a fresh `updatedAt` and still gets through.
    private var lastAppliedStatus: ClaudeStatus?

    /// Applies a fresh status from the watcher. Keeps the `done` checkmark on
    /// screen briefly, then eases it back to `idle` so it behaves like a toast.
    ///
    /// `announce` is false for a change the user made — picking a session from
    /// the list, or going back. That rings nothing, and an alert it lands on
    /// counts as already seen, so the panel doesn't pop open for it.
    private func applyClaudeStatus(_ status: ClaudeStatus, announce: Bool = true) {
        guard status != lastAppliedStatus else { return }
        if claudeFaceFrozen {
            // Held until the reply's field lets go; the latest wins, and an
            // announcement held back is still made then.
            heldStatus = (status, announce || (heldStatus?.announce ?? false))
            noteHeldNeedsYou(status.state)
            return
        }
        lastAppliedStatus = status

        doneRevertTask?.cancel()
        doneRevertTask = nil

        // The glyph's cross-fade between states (BreathingShapeView ->
        // CheckmarkBurstView and back) rides `.animation(value:)` inside
        // ClaudeStatusGlyphView, but that only fires for changes made in a
        // SwiftUI transaction. This assignment comes from the watcher's async
        // callback, so wrap it explicitly — see the note in
        // ClaudeStatusGlyphView.swift.
        // Re-arm the dismiss state whenever the actual state changes, so a fresh
        // alert opens even if the previous one was dismissed — but a re-write of
        // the same state (e.g. a still-pending approval) stays dismissed.
        if status.state != claudeState {
            alertDismissed = !announce
            alertWasHovered = false
            // Re-arm the Claude-face auto-jump: a fresh interrupt gets to grab
            // the face once again, even if the user overrode the previous one.
            tabOverriddenDuringAlert = false
            if announce { playSound(for: status.state, errorType: status.errorType, limitNext: status.limitNext) }
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            claudeState = status.state
        }
        claudeProject = status.project
        if claudeSessionId != status.sessionId {
            // Another session took the island: whatever was being typed or
            // confirmed was for the one before. Its draft stays filed under
            // its own id.
            composing = nil
            deliveryTask?.cancel()
            deliveryTask = nil
            replyDelivery = .none
        }
        claudeSessionId = status.sessionId
        if claudeStateFromAgent != status.fromAgent { claudeStateFromAgent = status.fromAgent }
        syncIslandBackground()
        claudeAction = status.action
        claudeTarget = status.target
        claudeErrorType = status.errorType
        claudeToolActive = status.toolActive
        claudeResetAt = status.resetAt
        claudeLimitKind = status.limitKind
        claudeLimitNext = status.limitNext
        let finalLine = ClaudeDoneLine.line(from: status.lastMessage)
        if claudeFinalLine != finalLine { claudeFinalLine = finalLine }
        if claudeSubagents != status.subagents { claudeSubagents = status.subagents }
        if claudeBlock != status.blocked {
            withAnimation(.easeInOut(duration: 0.22)) { claudeBlock = status.blocked }
        }
        if claudeLeftovers != status.left {
            withAnimation(.easeInOut(duration: 0.22)) { claudeLeftovers = status.left }
        }
        // A background session no hook wrote for has no "when" Isle can
        // vouch for: no "… ago" rather than one counted from the read.
        claudeUpdatedAt = status.state == .disconnected || (status.fromAgent && status.updatedAt == nil)
            ? nil : Date()
        claudeRequestId = status.requestId
        refreshPendingRequest()
        // The island may have moved to another session; the count leaves out
        // whichever one it now shows.
        updateOtherSessions()
        updateSessionHost()
        settleReplyState(for: status.state)

        // Rotate the "thinking" word only while actually working.
        if status.state == .working {
            startWorkingWords()
        } else {
            stopWorkingWords()
        }
        updateReselectTimer(for: status.state)

        // Claude Code's own state isn't a hook's toast: it says blocked
        // until Claude Code says otherwise, so nothing eases it to Ready.
        guard !status.fromAgent else { return }

        // `done` and `failed` are both terminal toasts: show them, then ease
        // back to idle so they don't stick until the next prompt. A failure
        // lingers a little longer since it's easier to miss and worth reading.
        let revertDelay: TimeInterval
        switch status.state {
        case .done: revertDelay = settings.doneToastSeconds
        case .failed:
            if status.errorType == "usage_limit" {
                // The usage/subscription limit is pinned, not a transient toast:
                // it stays on the island until it resets. When the reset moment is
                // known, ease back to idle exactly then (clearing at once if it's
                // already past); when it isn't, leave it pinned with no timer —
                // the next real session activity replaces it. A limit waiting for
                // Enter, or one that won't continue, can be past its reset and
                // stays until something moves (see `limitEasesAt`).
                guard let reset = Self.limitEasesAt(status) else { return }
                revertDelay = max(0, reset.timeIntervalSinceNow)
            } else {
                revertDelay = max(settings.doneToastSeconds, 6)
            }
        case .needsQuestion:
            // A question is answered in the terminal, and nothing clears it if
            // you decline or ignore it (Claude Code fires no hook for a declined
            // tool). So ease it back to idle after a spell rather than letting
            // "Question" wedge the island until the next prompt. Held while
            // a hook is still waiting on the notch — see `scheduleIdleRevert`.
            revertDelay = Self.questionRevertSeconds
        case .compacting:
            // Only PreCompact fires — a cancelled compaction sends no follow-up,
            // so ease back to idle rather than animating forever. A finished
            // compaction is usually cleared sooner by the next real event.
            revertDelay = Self.compactingRevertSeconds
        default: return
        }
        scheduleIdleRevert(after: revertDelay)
    }

    /// Eases the island back to idle after `delay`, unless something else
    /// arrives first (any new status cancels it).
    ///
    /// Never while a request is pending: a question the notch is offering is
    /// not an abandoned one, however long it has been up. The revert then
    /// stands down, and `refreshPendingRequest` re-arms it once the request
    /// goes away.
    private func scheduleIdleRevert(after delay: TimeInterval) {
        doneRevertTask?.cancel()
        doneRevertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            guard self.pendingRequest == nil else {
                self.doneRevertTask = nil
                return
            }
            if self.claudeFaceFrozen {
                self.doneRevertTask = nil
                self.heldIdleRevert = true
                return
            }
            // Idle is quiescent — nothing left to re-select for, unless a
            // background session is holding the Mac awake.
            self.updateReselectTimer(for: .idle)
            // Ready says no agents are running, as `eased` does for the list.
            self.claudeSubagents = []
            withAnimation(.easeInOut(duration: 0.25)) {
                self.claudeState = .idle
            }
        }
    }

    /// The chime for a state the user asked to hear about. Only called on a
    /// genuine state change, so a still-pending approval being re-written
    /// doesn't ring again, and a `done` that eased back to idle and is then
    /// re-selected rings only if the turn genuinely finished again (the
    /// `lastAppliedStatus` guard above handles the re-selection case).
    ///
    /// A usage-limit failure is deliberately silent: it is pinned for as
    /// long as hours, and there is nothing to do about it but wait.
    private func playSound(for state: ClaudeCodeState, errorType: String?, limitNext: ClaudeLimitNext? = nil) {
        switch state {
        case .needsApproval, .needsQuestion:
            guard settings.claudeAlertSoundEnabled else { return }
            settings.claudeAlertSound.play()
        case .failed:
            // …except one waiting for Enter: that one needs you.
            guard settings.claudeAlertSoundEnabled, errorType != "usage_limit" || limitNext == .enter else { return }
            settings.claudeAlertSound.play()
        case .done:
            guard settings.claudeDoneSoundEnabled else { return }
            settings.claudeDoneSound.play()
        default:
            return
        }
    }

    /// Picks which source drives the notch, which player the island is routed
    /// to, and feeds the result through `apply`.
    ///
    /// Prefer the adapter whenever it carries a supported player's track (that
    /// player owns the system session); otherwise fall back to a poll — see
    /// `fallbackPollModel` for which. The equality guard matters: without it,
    /// a 1 Hz poll tick would re-apply an unchanged adapter model and yank the
    /// scrubber back to that model's now-stale elapsed time every second.
    private func recomputeSource() {
        var effective = adapterModel.hasTrack
            ? adapterModel
            : (fallbackPollModel() ?? MediaPlaybackModel())

        // The AppleScript poll reads the player's *true* position, which the
        // adapter's cached elapsed lags after a seek/restart (MediaRemote
        // catches up on its own schedule). The poll is the ground truth for
        // the clock, so let it drive the timing fields while the adapter still
        // supplies metadata and byte artwork. Without this, a stale adapter
        // position snaps the bar back over a fresh seek; apply()'s drift
        // easing absorbs the steady 1 Hz corrections so this doesn't
        // reintroduce jitter, and a restart self-corrects within ~1s. Keyed by
        // the track's owner, so Music's poll can never time Spotify's track.
        if let poll = pollModels[effective.bundleIdentifier], poll.hasTrack,
           poll.title == effective.title, poll.album == effective.album {
            effective.reportedElapsed = poll.reportedElapsed
            effective.timestamp = poll.timestamp
            effective.isPlaying = poll.isPlaying
            effective.playbackRate = poll.playbackRate
            // Shuffle/repeat come from the poll too: the MediaRemote adapter
            // doesn't report them for Spotify (they're absent from its payload),
            // so without this the toggles would read permanently off and never
            // light up even when the player has them on.
            effective.isShuffled = poll.isShuffled
            effective.repeatMode = poll.repeatMode
        }

        holdOptimisticTransport(&effective)

        // Route to whoever owns the track on screen. The waveform's tap
        // follows: it is bound to one process, and it must be this one.
        routedPlayerID = effective.hasTrack ? effective.bundleIdentifier : nil
        if let routedPlayerID {
            lastActivePlayerID = routedPlayerID
            audio.setTarget(routedPlayerID)
        }
        // With the adapter silent, the routed poll's model — and so its cover —
        // is the one on screen. Any cover it held back while the adapter was
        // supplying one, or while another player was routed, is fetched now.
        if !adapterModel.hasTrack {
            routedPlayer?.fetchArtworkIfNeeded()
        }

        guard effective != lastApplied else { return }
        lastApplied = effective
        apply(effective)
    }

    /// Which poll drives the island when the adapter is silent: the player
    /// that's playing; failing that, the one the island was already on; and on
    /// a cold start with two paused players, the first in `players` order —
    /// Spotify, the behaviour Isle has always had. Nil when no player has a
    /// track.
    private func fallbackPollModel() -> MediaPlaybackModel? {
        let candidates = players.compactMap { pollModels[$0.bundleID] }.filter(\.hasTrack)
        return candidates.first(where: \.isPlaying)
            ?? candidates.first(where: { $0.bundleIdentifier == lastActivePlayerID })
            ?? candidates.first
    }

    /// Keeps the user's last play/pause or seek in place until a source agrees
    /// (or the grace window passes), so a stale poll can't undo it.
    private func holdOptimisticTransport(_ model: inout MediaPlaybackModel) {
        let now = Date()
        let expired = now >= pendingCommandDeadline

        if let want = pendingPlayState {
            if model.isPlaying == want || expired {
                pendingPlayState = nil            // confirmed, or gave up
            } else {
                model.isPlaying = want
                model.playbackRate = want ? 1 : 0
            }
        }

        if let target = pendingSeekTarget {
            // Landed once the source reports within a couple seconds of the seek.
            if abs(model.elapsed(at: now) - target) < 2.0 || expired {
                pendingSeekTarget = nil
            } else {
                model.reportedElapsed = target
                model.timestamp = now
            }
        }

        if let want = pendingShuffle {
            if model.isShuffled == want || expired {
                pendingShuffle = nil            // confirmed, or gave up
            } else {
                model.isShuffled = want
            }
        }

        if let want = pendingRepeat {
            if model.repeatMode == want || expired {
                pendingRepeat = nil
            } else {
                model.repeatMode = want
            }
        }
    }

    // MARK: - Haptics

    private var lastHapticDate: Date = .distantPast

    /// One tick per open/close, throttled.
    ///
    /// Expanding changes the notch's shape, which changes its hit-test region,
    /// which can hand back a fresh hover event — so a single deliberate open
    /// could emit a burst of ticks that felt like a drum roll. The throttle
    /// collapses any such burst into the one click the gesture deserves.
    func playTransitionHaptic() {
        guard settings.haptics else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHapticDate) > 0.35 else { return }
        lastHapticDate = now
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )
    }

    // MARK: - Playback clock

    // The scrubber runs off its own anchor rather than off whatever the
    // adapter last reported.
    //
    // The adapter re-reports elapsed time about once a second, and each report
    // is quantised to the source app's own update granularity. Anchoring
    // directly to it meant the extrapolated position was yanked back into line
    // every second — small, but a visible stutter on a bar that's otherwise
    // moving continuously. Here a report only moves the anchor outright when
    // it disagrees materially (a seek, a track change, a play/pause); ordinary
    // sub-second disagreement is absorbed a fraction at a time, so the bar
    // stays monotonic and the correction is invisible.
    private var anchorElapsed: TimeInterval = 0
    private var anchorDate: Date?
    private var anchorRate: Double = 0

    /// How much of a small disagreement to absorb per report. Low enough to be
    /// imperceptible, high enough to converge within a couple of seconds.
    private static let driftCorrection: Double = 0.18

    /// Beyond this many seconds of disagreement, assume it's a real jump
    /// (seek, track change) and snap rather than easing.
    private static let snapThreshold: TimeInterval = 1.5

    private func apply(_ model: MediaPlaybackModel) {
        var model = model
        let now = Date()
        let reported = model.elapsed(at: now)

        let isNewTrack = model.title != media.title || model.album != media.album
        let transportChanged = model.isPlaying != media.isPlaying
            || model.playbackRate != anchorRate

        // Same track, no cover: keep the one on screen. The sources swap when
        // a browser takes the now-playing session — the adapter drops out and
        // the poll takes over — and the poll's model arrives before its cover
        // does (the download is deferred until it's needed; see
        // `SpotifyController.wantsArtwork`). Without this the island showed
        // the gradient for the fraction of a second in between, for a track
        // that hadn't changed.
        if model.artwork == nil, !isNewTrack {
            model.artwork = media.artwork
        }

        if anchorDate == nil || isNewTrack || transportChanged {
            anchorElapsed = reported
        } else {
            let predicted = projectedElapsed(at: now)
            let disagreement = reported - predicted
            anchorElapsed = abs(disagreement) > Self.snapThreshold
                ? reported
                : predicted + disagreement * Self.driftCorrection
        }

        anchorDate = now
        anchorRate = model.playbackRate

        // Reference identity, not image equality: the sources hand over a new
        // NSImage only when they actually fetched or decoded one, so this is
        // exactly the question of whether the cover changed.
        if model.artwork !== paletteArtwork {
            paletteArtwork = model.artwork
            // nil artwork leaves this nil rather than storing `.fallback`, so
            // `palette` can hand over to the accent instead of the greys.
            artworkPalette = model.artwork.map { ArtworkColors.palette(from: $0) }
        }

        // The anchor above is the only thing that needs the timing fields, and
        // it has them now. Publish only when something a view draws has
        // changed — otherwise every 1 Hz poll re-evaluated the whole notch
        // (shape, glyph, equalizer bridge, palette) to redraw nothing.
        guard !model.hasSameDisplay(as: media) else { return }
        media = model
    }

    /// Elapsed position extrapolated from the anchor, clamped to the track.
    private func projectedElapsed(at date: Date) -> TimeInterval {
        guard let anchorDate else { return 0 }
        let raw = anchorElapsed + date.timeIntervalSince(anchorDate) * anchorRate
        guard media.duration > 0 else { return max(0, raw) }
        return min(max(0, raw), media.duration)
    }

    // MARK: - Derived state

    /// Whether Claude Code warrants opening the notch on its own.
    ///
    /// Only `needsApproval` interrupts. `working` and `done` are ambient —
    /// they show in the collapsed glyph but must not pop the panel open, or
    /// the notch would flap open on every tool call. Suppressed entirely when
    /// the active mode doesn't show Claude.
    var hasLiveActivity: Bool {
        // Approvals/questions interrupt; a transient failure also pops the panel
        // so the stopped turn is noticed (it auto-reverts to idle — see
        // applyClaudeStatus). The usage limit is the exception: it's pinned
        // ambient info, shown in the island but never taking over the panel, so
        // it doesn't sit maximized for however long the limit lasts.
        guard settings.effectiveMode.showsClaude else { return false }
        if claudeState.isAttention || isLimitWaitingForEnter { return true }
        return claudeState == .failed && !isUsageLimit
    }

    /// The limit reset while the Mac slept, and Claude Code is waiting for
    /// Enter (`quota_auto_resume_stale`): unlike the limit itself, this one
    /// needs you, so it opens the panel and rings like a question.
    var isLimitWaitingForEnter: Bool {
        isUsageLimit && claudeLimitNext == .enter
    }

    /// When a usage-limit record stops being the island's news: at its reset,
    /// except a limit waiting for Enter (its reset has passed; that's the
    /// point), or one that won't continue whose reset had already passed when
    /// it said so. Those stay until the session moves. Nil: pinned.
    nonisolated static func limitEasesAt(_ status: ClaudeStatus) -> Date? {
        guard let reset = status.resetAt else { return nil }
        switch status.limitNext {
        case .enter: return nil
        case .stopped: return reset > (status.updatedAt ?? .distantPast) ? reset : nil
        default: return reset
        }
    }

    /// The current failure is the Claude usage/subscription limit (pinned, resets
    /// on a schedule) rather than a transient API error.
    var isUsageLimit: Bool {
        claudeState == .failed && claudeErrorType == "usage_limit"
    }

    /// A live activity takes over the panel only when the user hasn't chosen to
    /// receive alerts minimized. When off, the alert still shows in the collapsed
    /// island (glyph/label) and the user expands on hover — it just doesn't pop
    /// open on its own. `hasLiveActivity` itself stays true so a manual expand
    /// still lands on the Claude face (see `expandedPlace`).
    /// Internal rather than private: `IslandPresentation.state` crosses it with
    /// that island's own hover.
    var autoExpandsForActivity: Bool {
        hasLiveActivity && settings.expandOnAlert && !alertDismissed
    }

    /// An island was hovered while this alert was live — a prerequisite for
    /// hover-away to count as a dismiss, so an untouched auto-open isn't
    /// dismissed by a stray move nearby. Called by `IslandPresentation`.
    func noteAlertVisited() {
        if hasLiveActivity { alertWasHovered = true }
    }

    /// How many islands the pointer currently holds open. The pointer is only
    /// ever on one screen, so this is 0 or 1 in practice; a count rather than
    /// a flag so two islands changing in the same event can't leave it wrong.
    /// Feeds the player polls' cadence — see `wantsFullRate` in `init`.
    private var hoveredIslands = 0

    /// An island's hover flipped. Called by `IslandPresentation` on every
    /// transition, in both directions.
    func islandHoverChanged(_ hovering: Bool) {
        hoveredIslands = max(0, hoveredIslands + (hovering ? 1 : -1))
        if !hovering, hoveredIslands == 0 { resetSessionList() }
        // Opening the panel puts the scrubber on screen: bring the position
        // current now rather than at the next relaxed read. With nothing
        // routed, every player gets asked, so whichever has a track is found.
        if hovering, hoveredIslands == 1 {
            (routedPlayer.map { [$0] } ?? players).forEach { $0.pollNow() }
            // The Claude face and the home tile count agent view's sessions;
            // opening the panel is the moment to have them current.
            if settings.effectiveMode.showsClaude { agentsMonitor.cue() }
            // The shelf's watches catch a file leaving; this catches what a
            // watch can't (a volume that went before its watch was set).
            shelf.prune()
        }
        // Closed: the shelf can give back a row it was holding.
        if hoveredIslands == 0 { fitShelfRows(shelf.items.count) }
    }

    /// The pointer left an island. Hovering away from an auto-opened alert the
    /// user has visited retracts the panel (if they allow it); the glyph stays
    /// in the island until the alert resolves.
    ///
    /// Shared across islands on purpose: the alert has been seen and waved off,
    /// and it should not stay open on a screen the user isn't looking at.
    func noteHoveredAway() {
        if hasLiveActivity, alertWasHovered, settings.dismissAlertPanel {
            alertDismissed = true
        }
    }

    /// Retract the current alert's panel now (a click on it). No-op unless an
    /// alert is live and the user allows dismissing; the glyph stays until the
    /// alert resolves. Returns whether it actually dismissed, so the island the
    /// click landed on can drop its hover to match.
    @discardableResult
    func dismissAlert() -> Bool {
        guard hasLiveActivity, settings.dismissAlertPanel else { return false }
        alertDismissed = true
        return true
    }

    // MARK: - Answering from the notch

    /// Re-derives `pendingRequest` from the status's request id and the
    /// requests on disk. Called whenever either side moves.
    private func refreshPendingRequest() {
        if claudeFaceFrozen {
            // A request taking the face would take the field with it: it
            // waits, and the face says Claude needs you.
            heldRequestRefresh = true
            if claudeRequests.contains(where: { $0.sessionId == claudeSessionId }) { claudeNeedsYouWhileComposing = true }
            return
        }
        let match = claudeRequests.first { request in
            guard request.id == claudeRequestId else { return false }
            // The id is session-scoped already; this just refuses to show one
            // session's request under another's status.
            if let session = request.sessionId, session != claudeSessionId { return false }
            switch request.kind {
            case .approval: return claudeState == .needsApproval
            case .question: return claudeState == .needsQuestion
            }
        }
        guard match != pendingRequest else { return }

        if match?.id != pendingRequest?.id {
            // A different request (or none): start its questions from the top
            // and re-arm the buttons.
            questionIndex = 0
            questionPicks = Array(repeating: [], count: match?.questions.count ?? 0)
            questionTyped = [:]
            answeredRequestId = nil
            isReviewingRemember = false
            // Text typed for the request before belongs to a question or a
            // call that has already gone, one way or another.
            answerDraft = ""
            denialDraft = ""
            if composing == .answer || composing == .denial { composing = nil }
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            pendingRequest = match
        }

        // The question went back to the terminal (or was answered) without a
        // status write to restart the clock: let it ease off as any other
        // question would.
        if match == nil, claudeState == .needsQuestion, doneRevertTask == nil {
            scheduleIdleRevert(after: Self.questionRevertSeconds)
        }
    }

    /// A click has been sent for the pending request and is waiting for the
    /// hook to take it.
    var isAnsweringRequest: Bool {
        guard let id = pendingRequest?.id else { return false }
        return answeredRequestId == id
    }

    /// Approve or Deny the pending tool call. Whether the answer went —
    /// for a keyboard shortcut's notice (the buttons ignore it).
    @discardableResult
    func decide(allow: Bool) -> Bool {
        guard let request = pendingRequest, request.kind == .approval, !isAnsweringRequest else { return false }
        return send(allow ? .allow : .deny, to: request)
    }

    /// "Always…": puts what would be saved on the face, for a second tap to
    /// confirm. Saving a rule outlives this one call, so it is never one tap.
    func reviewRemember() {
        guard let request = pendingRequest, request.kind == .approval, request.remember != nil,
              !isAnsweringRequest else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isReviewingRemember = true }
    }

    /// Back from the review to the plain decision.
    func cancelRemember() {
        guard isReviewingRemember, !isAnsweringRequest else { return }
        withAnimation(.easeInOut(duration: 0.2)) { isReviewingRemember = false }
    }

    /// The confirm on the review: allow this call and accept the suggestions
    /// as Claude Code offered them.
    @discardableResult
    func allowRemembering() -> Bool {
        guard let request = pendingRequest, request.kind == .approval, request.remember != nil,
              isReviewingRemember, !isAnsweringRequest else { return false }
        return send(.allowRemembering, to: request)
    }

    /// The question currently on screen, when a question is pending.
    var currentQuestion: ClaudeQuestion? {
        guard let request = pendingRequest, request.kind == .question,
              request.questions.indices.contains(questionIndex) else { return nil }
        return request.questions[questionIndex]
    }

    /// A tap on an option. Single-select records it and moves on — to the
    /// next question, or, on the last, sends every answer. Multi-select only
    /// toggles; `advanceQuestion` commits it.
    func pickOption(_ label: String) {
        guard let question = currentQuestion, !isAnsweringRequest,
              questionPicks.indices.contains(questionIndex) else { return }
        // A tap on an option takes the place of anything typed for it.
        questionTyped[questionIndex] = nil
        if question.multiSelect {
            if questionPicks[questionIndex].contains(label) {
                questionPicks[questionIndex].remove(label)
            } else {
                questionPicks[questionIndex].insert(label)
            }
        } else {
            questionPicks[questionIndex] = [label]
            advanceQuestion()
        }
    }

    /// Next / Done: moves past the current question once it has an answer,
    /// and sends them all after the last.
    func advanceQuestion() {
        guard let request = pendingRequest, request.kind == .question, !isAnsweringRequest,
              questionPicks.indices.contains(questionIndex),
              !questionPicks[questionIndex].isEmpty || questionTyped[questionIndex] != nil
        else { return }

        if questionIndex + 1 < request.questions.count {
            withAnimation(.easeInOut(duration: 0.2)) { questionIndex += 1 }
            return
        }

        // Keyed by the question text, as Claude Code expects. A multi-select's
        // labels go in the order the options were offered, comma-joined.
        // Typed text goes in as it was written: Claude Code takes any string
        // here, and shows it as the answer just as the terminal's "Type
        // something" row would (verified on 2.1.318 — "Which fruit? → Mango,
        // and make it a smoothie").
        var answers: [String: String] = [:]
        for (index, question) in request.questions.enumerated() {
            if let typed = questionTyped[index] {
                answers[question.question] = typed
                continue
            }
            let picked = questionPicks[index]
            answers[question.question] = question.options
                .map(\.label)
                .filter { picked.contains($0) }
                .joined(separator: ", ")
        }
        send(.answers(answers), to: request)
    }

    /// Back to the previous question of a multi-question ask.
    func previousQuestion() {
        guard currentQuestion != nil, questionIndex > 0, !isAnsweringRequest else { return }
        withAnimation(.easeInOut(duration: 0.2)) { questionIndex -= 1 }
    }

    /// Answer in terminal: releases the hook with no decision, so Claude shows
    /// its own prompt now rather than at the deadline. For a question that is
    /// the difference between a blank terminal and the question UI.
    func deferToTerminal() {
        guard let request = pendingRequest, !isAnsweringRequest else { return }
        send(.terminal, to: request)
    }

    @discardableResult
    private func send(_ reply: ClaudeRequestWatcher.Reply, to request: ClaudeRequest) -> Bool {
        answeredRequestId = request.id
        guard requestWatcher.respond(reply, to: request) else {
            // The hook let go first (its deadline, Esc in the terminal) or the
            // write failed. Claim nothing: re-arm, and re-scan so buttons for a
            // request that is already gone retire now.
            answeredRequestId = nil
            requestWatcher.refresh()
            return false
        }
        return true
    }

    // MARK: - Keyboard shortcuts

    /// The Claude face with the pending request on it is what the open
    /// panel shows — not the list, not another face. Where a shortcut's
    /// press counts as made in view of it (see `ShortcutPlan.command`).
    var showsPendingRequestFace: Bool {
        pendingRequest != nil && expandedPlace == .face(.claude) && !sessionListShown
    }

    /// Puts the pending request's face up — out of the list, onto the Claude
    /// face — for a shortcut that opens the island to it.
    func revealPendingRequest() {
        guard pendingRequest != nil else { return }
        closeSessionList()
        if expandedPlace != .face(.claude), availableTabs.contains(.claude) {
            selectTab(.claude)
        }
    }

    /// The keys the face's buttons carry (Approve ⌃', ⌥1 on an option), and
    /// which a press would act on now — `NotchShortcuts` keeps it, from the
    /// bindings and the same plan a press goes through. See `ShortcutHints`.
    @Published private(set) var shortcutHints = ShortcutHints()

    func setShortcutHints(_ hints: ShortcutHints) {
        if shortcutHints != hints { shortcutHints = hints }
    }

    /// What a shortcut just did, said in the collapsed island — so a press
    /// made with the island closed is never silent. Unlike a toast it shows
    /// over a live alert: it's the answer to that alert, and it's the user's
    /// own doing. Brief, and replaced by the next.
    @Published private(set) var shortcutNotice: IslandToast?
    private var shortcutNoticeTask: Task<Void, Never>?
    private static let shortcutNoticeSeconds: TimeInterval = 2.5

    func showShortcutNotice(_ notice: IslandToast) {
        shortcutNoticeTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { shortcutNotice = notice }
        shortcutNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.shortcutNoticeSeconds))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.25)) { self.shortcutNotice = nil }
            self.shortcutNoticeTask = nil
        }
    }

    // MARK: - Jump and reply (Milestone 11)

    /// The island's session as the registry last reported it.
    private var selectedSession: ClaudeSession? {
        guard let id = claudeSessionId else { return nil }
        return claudeSessions.first { $0.sessionId == id }
    }

    /// Re-resolves `sessionHost` when the island's session, or its pid,
    /// changes. Off the main thread: tmux in the chain means asking tmux.
    private func updateSessionHost() {
        let pid = selectedSession?.pid
        guard pid != sessionHostPID else { return }
        sessionHostPID = pid
        // Never show the last session's host for this one, even briefly.
        sessionHost = nil
        guard let pid else { return }
        Task.detached(priority: .utility) { [weak self] in
            let host = ClaudeHostResolver.resolve(cliPID: pid)
            await self?.receiveHost(host, for: pid)
        }
    }

    /// A resolution landing, for whichever session was asked about: kept
    /// only if that session is still the island's.
    private func receiveHost(_ host: ClaudeSessionHost?, for pid: pid_t) {
        guard sessionHostPID == pid else { return }
        sessionHost = host
    }

    /// What the Jump pill says — the hosting app's own name — or nil when
    /// there's nowhere resolved to jump to.
    var jumpTarget: String? {
        guard claudeState != .disconnected else { return nil }
        return sessionHost?.app?.name ?? (islandAttachId != nil ? ClaudeLauncher.attachApp : nil)
    }

    /// The island's session is a background one with no terminal of its own
    /// (Milestone 21): Jump attaches to it in Terminal.
    var jumpAttaches: Bool {
        sessionHost?.app == nil && islandAttachId != nil
    }

    private var islandAttachId: String? {
        claudeBackground?.attachId
    }

    /// Brings the session's tab (or its app) to the front. Resolved again
    /// at the click, since tabs move between windows and a tmux client can
    /// re-attach elsewhere; a session that no longer resolves goes nowhere.
    /// A background session with no terminal is attached to instead.
    func jumpToSession() {
        if jumpAttaches, let id = islandAttachId {
            ClaudeLauncher.attach(id, in: claudeBackground?.cwd)
            return
        }
        guard let pid = selectedSession?.pid, sessionHost?.app != nil else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let host = ClaudeHostResolver.resolve(cliPID: pid)
            await self?.receiveHost(host, for: pid)
            guard let host, host.app != nil else { return }
            _ = await TerminalBridge.jump(to: host)
        }
    }

    /// Whether the face offers "Reply to Claude…", and how it would land.
    enum ReplyGate: Equatable {
        /// No field: no terminal Isle can type into, the setting's off, a
        /// request on the face has fields of its own, or no session.
        case unavailable
        /// At its prompt: the reply starts the next turn.
        case open
        /// Mid-turn: Claude Code queues the reply and takes it at its next
        /// tool boundary (see `QueuedReply`).
        case queues
        /// A permission prompt or a question is up in the terminal, where a
        /// typed Return would answer it. The field shows, disabled, saying
        /// why.
        case dialog(String)
    }

    /// See `ReplyGate`. From the island's state and the CLI's own status;
    /// the same checks run again, fresh, at Send.
    var replyGate: ReplyGate {
        guard repliesFromNotch, pendingRequest == nil, !claudeStateFromAgent else { return .unavailable }
        let dialog = ReplyGate.dialog("Answer Claude's prompt in \(sessionHost?.app?.name ?? "its terminal") first")
        switch claudeState {
        case .disconnected: return .unavailable
        case .needsApproval, .needsQuestion: return dialog
        default: break
        }
        switch selectedSession?.status {
        case .waiting: return dialog
        case .busy: return .queues
        default: break
        }
        return claudeState == .working || claudeState == .compacting ? .queues : .open
    }

    /// The face offers a reply that can be sent now: at the prompt (idle,
    /// Done, Ready, a shell running), or mid-turn, where Claude Code queues
    /// it. Never while a prompt is up in the terminal.
    var canReply: Bool {
        replyGate == .open || replyGate == .queues
    }

    /// Whether this session's row ever holds a reply: the setting is on and
    /// its terminal can be typed into. Not whether it can right now — that's
    /// `canReply`, which comes and goes with the state. The face places Jump
    /// by this, so the pill doesn't move when the reply field appears.
    var repliesFromNotch: Bool {
        settings.answerFromNotch && sessionHost?.typingRoute != nil
    }

    /// The reply being written for the island's session.
    var replyDraft: String {
        get { claudeSessionId.flatMap { replyDrafts[$0] } ?? "" }
        set {
            guard let id = claudeSessionId else { return }
            replyDrafts[id] = newValue.isEmpty ? nil : newValue
        }
    }

    /// Starts taking keys for one of the face's fields. The panel becomes key
    /// (without activating Isle) in response; see `NotchWindowController`.
    func beginCompose(_ kind: ComposeKind) {
        switch kind {
        case .reply:
            guard canReply else { return }
        case .answer:
            guard pendingRequest?.kind == .question, !isAnsweringRequest else { return }
        case .denial:
            guard pendingRequest?.kind == .approval, !isAnsweringRequest, !isReviewingRemember else { return }
        case .quickAdd:
            guard showsAgenda else { return }
        }
        guard composing != kind else { return }
        composing = kind
    }

    /// Esc, or focus going elsewhere: stop taking keys. What was typed is
    /// kept, and is there when the field is opened again.
    func endCompose() {
        guard composing != nil else { return }
        composing = nil
    }

    /// Return, or the Send button.
    func sendCompose() {
        switch composing {
        case .reply: sendReply()
        case .answer: answerWithTypedText()
        case .denial: denyWithMessage()
        // The first Return previews, a second adds — and an add that lands
        // ends composing (see `agendaModel.onAdded`).
        case .quickAdd: agendaModel.submit()
        case nil: break
        }
    }

    /// "Type something": the typed text answers the question on screen, then
    /// the ask moves on — to the next question, or, on the last, sends.
    private func answerWithTypedText() {
        let text = answerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, currentQuestion != nil, !isAnsweringRequest,
              questionPicks.indices.contains(questionIndex) else { return }
        composing = nil
        questionTyped[questionIndex] = text
        questionPicks[questionIndex] = []
        answerDraft = ""
        advanceQuestion()
    }

    /// "No, and tell Claude what to do differently": a denial whose message
    /// carries the user's words. The message is what Claude reads as the
    /// tool's result, the same slot the terminal's own option fills.
    private func denyWithMessage() {
        let text = denialDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let request = pendingRequest, request.kind == .approval,
              !isAnsweringRequest else { return }
        composing = nil
        send(.denySaying(text), to: request)
    }

    /// Sends the draft: typed into the session's terminal as the next
    /// prompt, or mid-turn as one Claude Code queues. Never while a prompt
    /// is up in the terminal: the field is disabled then, and the same check
    /// runs again here, fresh, in `deliver`.
    private func sendReply() {
        let text = Self.replyText(replyDraft)
        guard !text.isEmpty, let session = selectedSession else { return }
        if case .sending = replyDelivery { return }
        // A prompt has come up in this session's terminal while the reply
        // was written: typed now, it would answer that. The field stays
        // open with the draft in it, and says why.
        if replyReadiness(session.sessionId) == false {
            replyRefusal = "Claude is asking something in \(sessionHost?.app?.name ?? "its terminal") — answer it first (esc)"
            return
        }
        composing = nil
        let id = session.sessionId
        // Out of the field now: it's sending, or comes back with the reason
        // if it can't be sent.
        replyDrafts[id] = nil
        deliveryTask?.cancel()
        replyDelivery = .sending(text)
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.deliver(text, sessionId: id)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .sent:
                self.replyDelivery = .sent(text)
            case .queued(let at, let session):
                self.replyDelivery = .none
                self.queue(text, at: at, session: session)
            case .failed(let reason):
                if self.replyDraft(for: id).isEmpty { self.replyDrafts[id] = text }
                self.replyDelivery = .failed(text: text, reason: reason)
            }
        }
    }

    private func replyDraft(for sessionId: String) -> String { replyDrafts[sessionId] ?? "" }

    /// What became of one delivery.
    private enum DeliveryOutcome {
        /// The transcript has it as a turn the user typed.
        case sent
        /// Claude Code queued it mid-turn, at this moment.
        case queued(Date, ClaudeSession)
        case failed(String)
    }

    /// Types `text` into session `sessionId`'s terminal and waits for the
    /// transcript to say it landed.
    ///
    /// Every check that decides whether keys would land in Claude's prompt
    /// runs here, against fresh state: the CLI must report itself idle or
    /// busy — never waiting, where a permission prompt or a question is up
    /// and a typed Return would answer it — and its process group must own
    /// the tab's terminal (so it isn't a shell after Claude exited, where the
    /// text would run as a command). Then it's typed, and only the transcript
    /// can say it arrived: a turn the user typed (`origin.kind == "human"`)
    /// or, mid-turn, Claude Code queueing it. A few seconds is plenty: Claude
    /// Code writes either the moment Return lands. Not seeing it isn't proof
    /// it went nowhere — it may be sitting in the prompt — so the reason
    /// says to look before sending again.
    private func deliver(_ text: String, sessionId: String) async -> DeliveryOutcome {
        // Read now: the CLI rewrites its record in place, and only a fresh
        // read says what it's showing.
        guard let fresh = sessionRegistry.currentSessions().first(where: { $0.sessionId == sessionId }) else {
            return .failed("Claude's session has ended")
        }
        let queues: Bool
        switch fresh.status {
        case .idle, .shell: queues = false
        case .busy: queues = true
        case .waiting: return .failed(Self.dialogUp)
        case .unknown: return .failed("Claude isn't at its prompt right now")
        }
        if replyReadiness(sessionId) == false { return .failed(Self.dialogUp) }

        let pid = fresh.pid
        let since = Date()
        let typed = await Task.detached(priority: .userInitiated) { () -> (Result<Void, TerminalBridge.Failure>, String)? in
            guard let host = ClaudeHostResolver.resolve(cliPID: pid),
                  let route = host.typingRoute,
                  ProcessSnapshot(pid: pid)?.ownsTerminal == true
            else { return nil }
            return (await TerminalBridge.type(text, via: route), host.app?.name ?? "the terminal")
        }.value
        guard let (result, app) = typed else { return .failed("Something else is in front in Claude's tab") }
        if case .failure(let failure) = result { return .failed(Self.reason(for: failure, app: app)) }

        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return .failed("Cancelled") }
            // Off the main thread: the read and the JSON are the transcript's.
            let cwd = fresh.cwd
            let (turn, queuedAt) = await Task.detached(priority: .userInitiated) {
                (Self.transcriptHasHumanTurn(text, cwd: cwd, sessionId: sessionId, since: since),
                 queues ? Self.transcriptQueueOperation(["enqueue"], text, cwd: cwd, sessionId: sessionId, since: since) : nil)
            }.value
            if turn { return .sent }
            if let queuedAt { return .queued(queuedAt, fresh) }
        }
        return .failed("Typed into \(app), but Claude didn't take it — check its prompt")
    }

    /// Whether typing into session `id` now would land in its prompt, as
    /// far as the island knows: nil when the session is gone, false while a
    /// permission prompt or a question is up — a request waiting on the
    /// notch, its record asking, or the CLI saying it's waiting.
    private func replyReadiness(_ id: String) -> Bool? {
        guard let session = claudeSessions.first(where: { $0.sessionId == id }) else { return nil }
        switch session.status {
        case .idle, .shell, .busy: break
        case .waiting, .unknown: return false
        }
        if claudeRequests.contains(where: { $0.sessionId == id }) { return false }
        if let status = claudeStatuses.first(where: { $0.sessionId == id }),
           status.state == .needsApproval || status.state == .needsQuestion { return false }
        return true
    }

    private static let dialogUp = "Claude is asking something in its terminal: answer it there first"

    /// Shows `text` as queued, and watches the transcript for Claude to take
    /// it: the "remove" Claude Code writes when it hands the queue to the
    /// model, or the text arriving as a turn of its own. Gone, too, with the
    /// session, and after an hour at most.
    private func queue(_ text: String, at queuedAt: Date, session: ClaudeSession) {
        let entry = QueuedReply(id: UUID(), text: text, queuedAt: queuedAt)
        let id = session.sessionId
        withAnimation(.easeOut(duration: 0.22)) { queuedReplies[id, default: []].append(entry) }
        queueWatches[entry.id] = Task { [weak self] in
            let cwd = session.cwd
            let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.claudeSessions.contains(where: { $0.sessionId == id }) else { break }
                let taken = await Task.detached(priority: .utility) {
                    Self.transcriptQueueOperation(["remove", "dequeue", "popAll"], text, cwd: cwd, sessionId: id,
                                                  since: queuedAt) != nil
                        || Self.transcriptHasHumanTurn(text, cwd: cwd, sessionId: id, since: queuedAt)
                }.value
                guard !Task.isCancelled else { return }
                if taken { break }
            }
            guard let self else { return }
            self.queueWatches[entry.id] = nil
            if self.claudeFaceFrozen {
                self.heldQueueRemovals.append((id, entry.id))
                return
            }
            withAnimation(.easeOut(duration: 0.22)) {
                self.queuedReplies[id]?.removeAll { $0.id == entry.id }
                if self.queuedReplies[id]?.isEmpty == true { self.queuedReplies[id] = nil }
            }
        }
    }

    /// When the transcript, since `since`, has a `queue-operation` of one of
    /// `operations` for `text`; nil when it hasn't.
    nonisolated private static func transcriptQueueOperation(_ operations: Set<String>, _ text: String, cwd: String,
                                                             sessionId: String, since: Date) -> Date? {
        queueOperation(operations, text, in: transcriptLines(cwd: cwd, sessionId: sessionId), since: since)
    }

    /// The same, over transcript lines newest first — the entries Claude
    /// Code 2.1.321 writes: `{"type":"queue-operation","operation":
    /// "enqueue","timestamp":…,"content":"…"}`.
    nonisolated static func queueOperation(_ operations: Set<String>, _ text: String, in lines: [Data],
                                           since: Date) -> Date? {
        let want = oneLine(text)
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let stamp = object["timestamp"] as? String,
                  let at = transcriptDate(stamp)
            else { continue }
            guard at >= since.addingTimeInterval(-1) else { return nil }
            guard object["type"] as? String == "queue-operation",
                  let operation = object["operation"] as? String, operations.contains(operation),
                  let content = object["content"] as? String
            else { continue }
            if oneLine(content) == want { return at }
        }
        return nil
    }

    /// Keeps the reply's outcome honest as the session moves on.
    private func settleReplyState(for state: ClaudeCodeState) {
        if composing == .reply, !canReply { composing = nil }
        switch replyDelivery {
        case .sent:
            // Shown for the turn it started; gone when that turn ends.
            if state != .working && state != .compacting { replyDelivery = .none }
        case .failed:
            // The user carried on in the terminal.
            if state == .working { replyDelivery = .none }
        default:
            break
        }
    }

    private static func reason(for failure: TerminalBridge.Failure, app: String) -> String {
        switch failure {
        case .notPermitted(let name): return "Allow Isle to control \(name) in Privacy › Automation"
        case .tabMissing: return "Couldn't find Claude's tab in \(app)"
        case .appGone: return "\(app) isn't running"
        case .failed: return "\(app) didn't take the text"
        }
    }

    /// The reply as it's typed: its lines kept — they go in inside a
    /// bracketed paste, where a newline is part of the prompt, not Return
    /// (measured, 2.1.321) — with Windows and old-Mac line ends made plain
    /// newlines, and blank lines at either end dropped.
    nonisolated static func replyText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text on one line, for matching what was typed against what the
    /// transcript holds.
    nonisolated private static func oneLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether the session's transcript, since `since`, has a user turn typed
    /// by a person that ends with `text`. "Ends with": anything the user had
    /// already typed in the prompt is sent along with it, and that still
    /// delivered the reply.
    nonisolated private static func transcriptHasHumanTurn(_ text: String, cwd: String, sessionId: String,
                                                           since: Date) -> Bool {
        for line in transcriptLines(cwd: cwd, sessionId: sessionId) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "user",
                  let stamp = object["timestamp"] as? String,
                  let at = transcriptDate(stamp)
            else { continue }
            guard at >= since.addingTimeInterval(-1) else { return false }
            if let origin = object["origin"] as? [String: Any], origin["kind"] as? String != "human" { continue }
            guard let message = object["message"] as? [String: Any] else { continue }
            let content: String
            if let string = message["content"] as? String {
                content = string
            } else if let blocks = message["content"] as? [[String: Any]] {
                content = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                continue
            }
            if oneLine(content).hasSuffix(oneLine(text)) { return true }
        }
        return false
    }

    /// Whether the agenda face is on at all — either switch is enough. The
    /// face shows even when access was declined, so the panel can say so;
    /// hiding it would leave the switch in Settings looking like it did nothing.
    var showsAgenda: Bool {
        settings.showCalendarEvents || settings.showReminders
    }

    /// The two switches individually, for the agenda face's empty-state copy.
    var agendaShowsEvents: Bool { settings.showCalendarEvents }
    var agendaShowsReminders: Bool { settings.showReminders }

    /// How long before a call its Join comes forward on the agenda face and
    /// the home tile: the island's own lead, so the toast and the button
    /// arrive together, and never less than ten minutes.
    var agendaJoinLead: TimeInterval { TimeInterval(max(10, settings.eventLeadMinutes) * 60) }

    /// The Pomodoro timer is offered — the Settings toggle is on.
    var pomodoroAvailable: Bool { settings.pomodoroEnabled }

    /// The faces the expanded panel can show right now, in grid order — the
    /// order of the home tiles, and the order a swipe walks: whatever the
    /// mode brings, then Pomodoro if it's been switched on, then the agenda
    /// if either of its switches is. A face that exists only while it holds
    /// something (a shelf) is appended here only while it does.
    var availableTabs: [IsleTab] {
        var tabs: [IsleTab] = []
        if settings.effectiveMode.showsMusic { tabs.append(.music) }
        if settings.effectiveMode.showsClaude { tabs.append(.claude) }
        if pomodoroAvailable { tabs.append(.pomodoro) }
        if showsAgenda { tabs.append(.agenda) }
        if !shelf.isEmpty { tabs.append(.shelf) }
        return tabs
    }

    /// Whether there's a home grid at all — only when there is more than one
    /// face to choose between. A single source is just shown, with no crumb
    /// and nothing to swipe to.
    var showsHome: Bool {
        availableTabs.count > 1
    }

    /// Where the open panel is right now. Normally the last place the user
    /// chose — the grid, or a face — except that a live Claude interrupt (an
    /// approval, a question, a failure) goes straight to the Claude face,
    /// without touching that choice, so it's back once the alert clears. A
    /// chosen face that is no longer offered (the mode changed, the agenda or
    /// Pomodoro was switched off) falls back to the grid rather than a guess.
    var expandedPlace: NotchPlace {
        let tabs = availableTabs
        // An alert auto-jumps to Claude, but going anywhere during the alert
        // sticks (see `selectTab` / `selectHome`), so the user can still
        // look at music.
        if hasLiveActivity, !tabOverriddenDuringAlert, tabs.contains(.claude) {
            return .face(.claude)
        }
        guard tabs.count > 1 else { return .face(tabs.first ?? .music) }
        if isHome { return .home }
        if tabs.contains(activeTab) { return .face(activeTab) }
        return .home
    }

    /// The face `step` places from `tab` in grid order (-1 the previous, +1
    /// the next), or nil past either end. What a swipe moves to.
    func neighbor(of tab: IsleTab, step: Int) -> IsleTab? {
        let tabs = availableTabs
        guard let index = tabs.firstIndex(of: tab) else { return nil }
        let target = index + step
        return tabs.indices.contains(target) ? tabs[target] : nil
    }

    /// Claude is blocked on the user: an approval or a question, from the
    /// selected session or any other the registry vouches for. Only ever from
    /// a status that says so — never inferred from a quiet session.
    var claudeNeedsYou: Bool {
        guard settings.effectiveMode.showsClaude else { return false }
        return claudeState.isAttention || otherSessions.needYou > 0
    }

    /// A face other than the one on screen needs the user — what the crumb's
    /// home mark lights for. Claude is the only face that can ask today.
    var needsYouElsewhere: Bool {
        guard let face = expandedPlace.face else { return false }
        return face != .claude && claudeNeedsYou
    }

    /// The content height the face on screen wants, when it wants more than
    /// the standard panel — the one place a face's height is decided. The
    /// panel grows to it, up to `NotchMetrics.panelMaxHeight`; `room` is the
    /// most content that cap holds, for a face that can fit itself to it.
    /// Nil keeps `expandedSize`, which Home and every other face do. A new
    /// face that grows is one more case here and nothing else: the window is
    /// already sized for the cap.
    func faceContentHeight(room: CGFloat) -> CGFloat? {
        guard let face = expandedPlace.face else { return nil }
        return faceContentHeight(of: face, room: room)
    }

    /// The content height `face` wants, whether or not it's the face on
    /// screen — for the pager, which lays the face coming in beside the
    /// current one out at its own height (see `FaceCarousel`).
    func faceContentHeight(of face: IsleTab, room: CGFloat) -> CGFloat? {
        switch face {
        case .claude:
            if face == expandedPlace.face, let question = questionContentHeight(room: room) { return question }
            // A reply grown past one line takes the panel with it.
            let extra = face == expandedPlace.face && composing == .reply ? replyFieldExtra : 0
            return extra > 0 ? NotchMetrics.standardContentHeight(room: room) + extra : nil
        case .agenda: return min(room, AgendaLayout.contentHeight)
        case .shelf: return min(room, ShelfLayout.contentHeight(rows: shelfRows))
        case .music, .pomodoro: return nil
        }
    }

    /// A turn is in progress on the island's session, as its hooks said:
    /// working or compacting, from a record rather than `claude agents`.
    var claudeTurnActive: Bool {
        !claudeStateFromAgent && (claudeState == .working || claudeState == .compacting)
    }

    /// The working face has a row under its headline: an agent running, a
    /// block, a reply on its way, or a finished call other than the one the
    /// headline names. Read by the face and the panel's height alike.
    var claudeWorkHasRows: Bool {
        if !claudeSubagents.isEmpty || claudeBlock != nil || !claudeQueued.isEmpty { return true }
        if claudeTrail?.prompt != nil { return true }
        switch replyDelivery {
        case .sending, .sent: return true
        default: break
        }
        return !(claudeTrail?.shown(current: claudeActivity, limit: 1).isEmpty ?? true)
    }

    /// The status face has an action row: the session's app to jump to or
    /// attach in, a reply to type or one on its way. Read by the face and
    /// the panel's height alike, so the two agree.
    var claudeHasActions: Bool {
        if composing == .reply || jumpAttaches || jumpTarget != nil || canReply { return true }
        if case .dialog = replyGate { return true }
        switch replyDelivery {
        case .sending, .sent: return true
        default: return false
        }
    }

    /// The height the question face wants, while it is the face on screen
    /// (see `faceContentHeight`). Nil without a live question, when the
    /// face keeps the standard height. The tallest question of a multi-question
    /// ask sizes it, so stepping through them doesn't bob the panel. Depends
    /// on the description setting (row heights); the rows have the face's
    /// full width, with nothing in the panel's corner to clear.
    ///
    /// Each question is fitted to `room`, the most the capped panel holds, so
    /// a question whose descriptions had to shorten asks for the height it's
    /// drawn at rather than the cap with a gap above the buttons.
    func questionContentHeight(room: CGFloat) -> CGFloat? {
        guard expandedPlace == .face(.claude), !sessionListShown,
              let request = pendingRequest, request.kind == .question else {
            return nil
        }
        return request.questions.map {
            ClaudePanelLayout.questionContentHeight(
                $0, descriptions: optionDescriptions, trailingClearance: 0, room: room
            )
        }.max()
    }

    /// How much of each option's description the question face shows.
    var optionDescriptions: OptionDescriptions { settings.optionDescriptions }


    /// The user went into a face: a home tile, or a swipe landing. Records
    /// the pick and, when an alert is live, marks it as a manual override so
    /// `expandedPlace` stops forcing the Claude face for the rest of this
    /// alert.
    func selectTab(_ tab: IsleTab) {
        if hasLiveActivity { tabOverriddenDuringAlert = true }
        activeTab = tab
        isHome = false
        // The changes publish, but publish explicitly too: if the tap
        // re-selects the face already showing, only the override flag moved
        // and the view still needs to re-read `expandedPlace`.
        objectWillChange.send()
    }

    /// The user went back to the home grid, from the crumb. Same override
    /// rule as `selectTab`: during an alert, Home sticks.
    func selectHome() {
        if hasLiveActivity { tabOverriddenDuringAlert = true }
        isHome = true
        objectWillChange.send()
    }

    var hasMusicActivity: Bool {
        settings.effectiveMode.showsMusic && media.hasTrack
    }

    /// Nothing worth showing in the collapsed island — no music, no Claude. In
    /// this state the notch shrinks to the physical cutout so it disappears into
    /// the hardware; it stays hoverable (see NotchWindowController's pointer
    /// backstop), so hovering the notch still reveals it.
    var isCollapsedIdle: Bool {
        collapsedToast == nil && !hasMusicActivity && !hasClaudeActivity && !hasPomodoroActivity
    }

    /// The Pomodoro clock has something worth showing in the collapsed island:
    /// it's enabled and has been started (running or paused mid-interval). A
    /// fresh, untouched timer stays off the island — it's reachable from the
    /// expanded panel, and a "25:00" that never moves says nothing.
    var hasPomodoroActivity: Bool {
        pomodoroAvailable && pomodoro.isActive
    }

    /// The collapsed island is showing the timer alone — no music, no Claude —
    /// so it straddles the cutout the way Claude solo does: glyph on the left
    /// in the album's footprint, the clock on the right.
    var isPomodoroSolo: Bool {
        hasPomodoroActivity && !hasMusicActivity && !hasClaudeActivity
    }

    /// Width reserved for the collapsed clock. Measured from a template shaped
    /// by the interval's full length rather than from the live string, so the
    /// slot is fixed for the whole interval and the island never jitters as
    /// the digits count down. Measured in the *monospaced-digit* font the
    /// clock is actually drawn in — its digits are wider than the status
    /// font's, and measuring with the wrong one left the text spilling past
    /// its slot and clipped by the notch outline. Padded by a couple of points
    /// so rounding in either layout can't shave the last digit.
    var pomodoroClockWidth: CGFloat {
        let template: String
        switch pomodoro.phaseDuration {
        case 3600...: template = "0:00:00"
        case 600...: template = "00:00"
        default: template = "0:00"
        }
        return Self.clockTextWidth(template) + 2
    }

    private static let clockFont = NSFont.monospacedDigitSystemFont(
        ofSize: CollapsedSize.statusFontSize, weight: .semibold
    )

    private static var clockWidthCache: [String: CGFloat] = [:]

    private static func clockTextWidth(_ string: String) -> CGFloat {
        if let cached = clockWidthCache[string] { return cached }
        let width = ceil((string as NSString).size(withAttributes: [.font: clockFont]).width)
        clockWidthCache[string] = width
        return width
    }

    /// Claude has something worth showing in the collapsed notch.
    var hasClaudeActivity: Bool {
        settings.effectiveMode.showsClaude
            && claudeState != .disconnected && claudeState != .idle
            // `waiting` is opt-out (settings > Claude Code): when it's off the
            // state is ambient like `idle` — the expanded panel still says
            // "Waiting for you", but the island stays with the music rather
            // than splitting to seat the word. Selection is untouched: waiting
            // already sits in the bottom urgency tier, so a working session
            // elsewhere outranks it either way.
            && (claudeState != .waitingInput || settings.showWaitingStatus)
    }

    /// The collapsed island is showing Claude alone (no music). Drives the
    /// dots-left / status-right layout and the warm thinking/working colouring —
    /// when music shares the island the Claude cluster stays compact on the
    /// right and keeps the artwork tint.
    var isClaudeSolo: Bool {
        hasClaudeActivity && !hasMusicActivity
    }

    /// Status colour for the working phases in the Claude-solo island: the
    /// lighter stop while thinking (no tool yet), the fuller one once a tool is
    /// running. Nil for every other state and layout, so those keep their
    /// marker colour.
    ///
    /// This used to be two literals, `#F2C14E` and `#E8842B`. What they encoded
    /// was never those particular hues but the *relationship* — thinking is the
    /// paler form of working — and that survives any accent, so it now comes
    /// off the palette. Isle keeps the distinction because it is real
    /// information: whether a tool is actually running.
    var workingTint: Color? {
        guard isClaudeSolo, claudeState == .working else { return nil }
        // Full strength for as long as the state stands. It used to fade once
        // hooks had been quiet a while, but hook silence is normal during a
        // long think, so the fade only ever second-guessed a state that was
        // still true.
        let accent = palette
        return isThinking ? accent.accent : accent.primary
    }

    /// Both sources live at once — collapsed view splits (spec 3.1): music keeps
    /// its place on the left, Claude sits on the right. Alerts (approval /
    /// question) stay on Claude's side too rather than taking over the whole
    /// island, so the music isn't displaced.
    var shouldSplitCollapsed: Bool {
        hasMusicActivity && (hasClaudeActivity || hasPomodoroActivity)
    }

    /// The Pomodoro clock is seated on the trailing side beside (or instead
    /// of) the Claude cluster — i.e. it isn't the solo straddle, whose glyph
    /// sits on the left.
    var pomodoroOnTrailingSide: Bool {
        hasPomodoroActivity && !isPomodoroSolo
    }

    /// Content widths either side of the camera cutout in the collapsed notch,
    /// including the small gap that separates each cluster from the camera.
    /// Music (album + waveform) groups on the left, Claude (dots + status text)
    /// on the right. Everything is sized to the actual content — including the
    /// measured width of the status word — so the island grows and shrinks with
    /// what's shown (e.g. "Working" → "Done" narrows it) rather than sitting at
    /// a fixed width. The notch shape is sized and shifted from these — see
    /// NotchRootView.
    var collapsedSideWidths: (leading: CGFloat, trailing: CGFloat) {
        let s = CollapsedSize.self
        let g = s.cutoutGap

        // A toast — power, calendar, reminder — borrows the whole island for
        // its few seconds: the symbol takes the album's footprint on the left,
        // the message sits on the right. Same straddle as the Claude-solo
        // layout, so music and Claude slide back into place when it ends
        // rather than jumping.
        if let toast = collapsedToast {
            return (s.album + g, IslandToast.width(of: toast.text) + g)
        }

        if shouldSplitCollapsed {
            // Music cluster is album + waveform, with the waveform tucked toward
            // the camera so the album sits outboard, clear of the housing. With
            // the waveform off the album is the whole cluster and the island
            // narrows — see `waveSlot`. The other side seats Claude, the timer,
            // or both in that order.
            let leading = s.album + waveSlot + g
            var trailing: CGFloat = 0
            if hasClaudeActivity { trailing += s.dots + statusSlot }
            if pomodoroOnTrailingSide {
                trailing += (trailing > 0 ? s.gap : 0) + pomodoroSlot
            }
            return (leading, trailing + g)
        }
        if hasClaudeActivity {
            // Claude solo: the dot glyph moves to the *left* of the camera and
            // the status word sits on the *right*, so the two straddle the
            // cutout instead of crowding together on one side. The glyph takes
            // the album's footprint (not the smaller split-view dots) so it
            // lands in exactly the spot the album cover occupies in music mode.
            // A running timer follows the word on the right.
            let word = Self.textWidth(collapsedStatusText)
            var trailing = word
            if pomodoroOnTrailingSide {
                trailing += (trailing > 0 ? s.gap : 0) + pomodoroSlot
            }
            return (s.album + g, trailing > 0 ? trailing + g : s.minSide)
        }
        if hasPomodoroActivity {
            // Timer solo: same straddle as Claude solo — the timer glyph in the
            // album's footprint on the left, the clock on the right.
            return (s.album + g, pomodoroClockWidth + g)
        }
        if hasMusicActivity {
            // The waveform's seat on the right is held whether or not the bars
            // are drawn, so the album and the island stay exactly put when the
            // waveform is switched off — see `waveSlot`.
            return (s.album + g, s.wave + g)
        }
        return (s.minSide, s.minSide)   // resting
    }

    /// The waveform's share of the music cluster — the gap plus the bars, or
    /// nothing when the bars are switched off.
    ///
    /// Only the music-solo layout holds the empty seat (see `collapsedSideWidths`),
    /// where album and waveform straddle the camera and the seat is what keeps
    /// the two sides even. In the split layout Claude already sits on the other
    /// side, so an empty seat is just 31pt of dead air between the album and the
    /// housing: it goes back and the island narrows with it.
    private var waveSlot: CGFloat {
        showsWaveform ? CollapsedSize.gap + CollapsedSize.wave : 0
    }

    /// The timer's compact cluster on the trailing side: a small glyph, a gap,
    /// and the clock.
    private var pomodoroSlot: CGFloat {
        CollapsedSize.dots + CollapsedSize.gap + pomodoroClockWidth
    }

    /// Extra trailing width for the status word beside the dots — the gap plus
    /// the word's measured width, or zero when there's no word.
    private var statusSlot: CGFloat {
        let width = Self.textWidth(collapsedStatusText)
        return width > 0 ? CollapsedSize.gap + width : 0
    }

    /// Feeds every session's record to its trail, and lets go of the trails
    /// of sessions whose record is gone. A step arriving slides in on the
    /// face, and the panel grows to seat the first one.
    private func followTrails(_ statuses: [ClaudeStatus]) {
        var trails = claudeTrails
        var live = Set<String>()
        for status in statuses where !status.fromAgent {
            guard let id = status.sessionId, !id.isEmpty else { continue }
            live.insert(id)
            var trail = trails[id] ?? ClaudeTrail()
            trail.observe(phase: Self.trailPhase(status.state), action: status.action,
                          target: status.target, toolActive: status.toolActive, at: status.updatedAt)
            trails[id] = trail
        }
        for id in trails.keys where !live.contains(id) { trails[id] = nil }
        if claudeFaceFrozen {
            heldTrails = trails
            return
        }
        if trails != claudeTrails {
            withAnimation(.easeOut(duration: 0.22)) { claudeTrails = trails }
        }
        readTurnPrompts()
    }

    /// When each session's prompt read was last tried, so a turn whose
    /// prompt isn't in the transcript yet is asked again on a later scan,
    /// and no more than once a second.
    private var promptReads: [String: Date] = [:]

    /// Reads the prompt that started each running turn from its session's
    /// transcript, for the trail's "You" row. Off the main thread.
    private func readTurnPrompts() {
        guard !claudeFaceFrozen else { return }
        for (id, trail) in claudeTrails where trail.wantsPrompt {
            if let last = promptReads[id], Date().timeIntervalSince(last) < 1 { continue }
            guard let cwd = claudeSessions.first(where: { $0.sessionId == id })?.cwd else { continue }
            promptReads[id] = Date()
            let since = trail.turnStartedAt
            Task { [weak self] in
                let prompt = await Task.detached(priority: .utility) {
                    ClaudeTrail.turnPrompt(in: Self.transcriptLines(cwd: cwd, sessionId: id), since: since)
                }.value
                guard let self, let prompt, !self.claudeFaceFrozen, self.claudeTrails[id]?.wantsPrompt == true,
                      self.claudeTrails[id]?.turnStartedAt == since else { return }
                withAnimation(.easeOut(duration: 0.22)) { self.claudeTrails[id]?.setPrompt(prompt) }
            }
        }
        for id in promptReads.keys where claudeTrails[id] == nil { promptReads[id] = nil }
    }

    private static func trailPhase(_ state: ClaudeCodeState) -> ClaudeTrail.Phase {
        switch state {
        case .working, .compacting: return .working
        case .needsApproval, .needsQuestion: return .waiting
        case .done, .idle, .waitingInput, .failed, .disconnected: return .ended
        }
    }

    /// The current tool call as a display model, used by the expanded "what it's
    /// doing" line. Nil until a `PreToolUse` has reported a tool (e.g. right
    /// after a prompt submit, before the first tool runs).
    var claudeActivity: ClaudeActivity? {
        ClaudeActivity(action: claudeAction, target: claudeTarget)
    }

    /// Claude is `working` but not inside a tool call — the reasoning/planning
    /// phase. That's the case right after a prompt (before the first tool) and
    /// for a whole text-only turn, so the island can honestly say "Thinking"
    /// then and "Working" once a tool is actually running. Between tools the
    /// last tool's action lingers (we don't clear it on PostToolUse), so this
    /// deliberately doesn't flip on every tool boundary — that would flap the
    /// collapsed word constantly.
    var isThinking: Bool {
        claudeState == .working && claudeActivity == nil
    }

    /// The word for the collapsed notch. During the no-tool reasoning phase it's
    /// an honest "Thinking"; once a tool is actually running it becomes the same
    /// rotating word the expanded panel shows (`workingWord`) — "Coalescing",
    /// "Percolating", … — so the label stays truthful about the phase while the
    /// working phase still gets the CLI spinner's personality. Deliberately *not*
    /// the per-tool action (that changes every tool call); the rotating word
    /// turns over on a slow 15s timer, so the occasional resize is gentle, not
    /// churn. The expanded view shows the detailed "Editing …" line separately.
    var collapsedStatusText: String {
        switch claudeState {
        case .working:
            // No clock on the working word, in either phase. Hooks are silent
            // through a whole reasoning turn and through a long tool call, so
            // the number was only ever counting normal quiet, and a figure
            // ticking up next to "Coalescing…" reads as a fault when nothing
            // is wrong. Past the staleness threshold the word just dims
            // (`claudeTint`) — the island says nothing it can't back up.
            return (isThinking ? "Thinking" : workingWord) + "…"
        // "Approve" only while a hook is actually waiting on the notch's
        // Approve / Deny; every other prompt — a question, or an approval
        // whose wait has ended and lives on only in the terminal — reads as
        // the one word for "it needs you".
        case .needsApproval, .needsQuestion:
            return pendingRequest?.kind == .approval ? "Approve" : "Question"
        case .waitingInput: return "Waiting"
        case .done: return "Done"
        case .idle: return "Ready"
        // A usage limit says when it resets (Milestone 19), as a clock rather
        // than a ticking count, so the island keeps one width for hours; or
        // "Press Enter" once it waits for that. Any other failure is "Error".
        case .failed:
            return isUsageLimit ? ClaudeLimit.islandWord(resetAt: claudeResetAt, next: claudeLimitNext) : "Error"
        case .compacting: return "Compacting"
        case .disconnected: return ""
        }
    }

    /// The marker to render for the current Claude state. For a failure this
    /// picks a specific error marker from `error_type` (rate-limit vs server vs
    /// generic) so the glyph itself distinguishes them; otherwise it's the plain
    /// lifecycle marker.
    var claudeMarkerKind: MarkerKind {
        guard claudeState == .failed else { return MarkerKind(state: claudeState) }
        switch claudeErrorType {
        case "usage_limit", "rate_limit", "rate_limit_error", "rate_limited": return .rateLimited
        case "server_error", "api_error", "overloaded", "overloaded_error": return .serverError
        default: return .apiError
        }
    }

    /// Measured widths, kept because this is on the hot path. `collapsedSideWidths`
    /// is read several times per body evaluation (the shape's size, the shift that
    /// re-centres the cutout, the hit rect, and the collapsed layout itself), and
    /// laying out a string to measure it is not cheap — it was the single largest
    /// main-thread cost in the app. The status word comes from a fixed handful
    /// ("Thinking…", "Done", the rotating working words), so the cache stays tiny
    /// and every read after the first is a dictionary hit.
    private static var textWidthCache: [String: CGFloat] = [:]

    /// The font is resolved once for the same reason — `systemFont(ofSize:weight:)`
    /// is a lookup, not a constant.
    private static let statusFont = NSFont.systemFont(
        ofSize: CollapsedSize.statusFontSize, weight: .semibold
    )

    private static func textWidth(_ string: String) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        if let cached = textWidthCache[string] { return cached }
        let width = ceil((string as NSString).size(withAttributes: [.font: statusFont]).width)
        textWidthCache[string] = width
        return width
    }

    // MARK: - Toasts

    /// The momentary message currently on screen, if any. Set only through
    /// `enqueueToast` / `advanceToast` so the timer and the value
    /// can't drift apart.
    @Published private(set) var activeToast: IslandToast?

    /// Toasts waiting their turn. Deliberately shallow: plugging in can
    /// produce a charging toast and then a flat-headphones toast, and that is
    /// about as much as anyone wants to read off a notch in one go.
    private var toastQueue: [IslandToast] = []

    private var toastTask: Task<Void, Never>?

    /// How long each toast holds the island. Matched to the Claude `done`
    /// checkmark's default so the island's two transient messages have the
    /// same rhythm — but a constant, not a setting: `doneToastSeconds` is
    /// tunable because a slow reader wants the checkmark to linger, and this
    /// is the same reading task at the same size.
    private static let toastSeconds: TimeInterval = 4

    private static let toastQueueLimit = 2

    /// Whether the toast should actually be drawn. Separate from
    /// `activeToast != nil` so a Claude alert arriving mid-toast takes the
    /// island back immediately — attention outranks ambient. The toast's timer
    /// keeps running underneath and it simply expires unseen, rather than
    /// being queued to reappear after the alert, which would deliver "Charging
    /// · 42%" minutes after the fact.
    var showsToast: Bool {
        activeToast != nil && !hasLiveActivity
    }

    /// What borrows the collapsed island right now, if anything: the drop
    /// notice while a file drag is under way — the user is mid-gesture, and
    /// that outranks a toast — else a keyboard shortcut's notice, which may
    /// sit over the alert it answered — else the toast. The drop notice and
    /// the toast never show under a live alert.
    var collapsedToast: IslandToast? {
        if showsDropNotice { return .dropNotice }
        if let shortcutNotice { return shortcutNotice }
        return showsToast ? activeToast : nil
    }

    /// Accepts a toast, or declines it. Dropped rather than queued when a
    /// Claude alert is live — a power event or a meeting reminder is ambient
    /// and stale within seconds, so waiting its turn behind an approval would
    /// make it a lie.
    private func enqueueToast(_ toast: IslandToast) {
        guard allows(toast.gate), !hasLiveActivity else { return }

        // Coalesce: a second event of the same kind replaces the first rather
        // than stacking. A loose MagSafe connector jiggling in and out should
        // leave one current message, not six stale ones.
        if let current = activeToast, current.coalesces(with: toast) {
            showToast(toast)
            return
        }
        toastQueue.removeAll { $0.coalesces(with: toast) }

        guard activeToast != nil else {
            showToast(toast)
            return
        }
        toastQueue.append(toast)
        if toastQueue.count > Self.toastQueueLimit {
            toastQueue.removeFirst()
        }
    }

    /// Puts a toast on screen and restarts the clock. The animation is
    /// explicit because these arrive from IOKit and subprocess callbacks,
    /// outside any SwiftUI transaction.
    private func showToast(_ toast: IslandToast) {
        toastTask?.cancel()
        // Chime as the toast lands, not when it's accepted: a queued toast
        // that rang on arrival and appeared four seconds later would have the
        // sound pointing at the wrong message.
        if settings.agendaSoundEnabled, toast.gate == .calendar || toast.gate == .reminders {
            settings.agendaSound.play()
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            activeToast = toast
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            self?.advanceToast()
        }
    }

    /// The current toast's time is up: show the next one, or hand the island
    /// back to music and Claude.
    private func advanceToast() {
        toastTask = nil
        if toastQueue.isEmpty {
            withAnimation(.easeInOut(duration: 0.25)) {
                activeToast = nil
            }
        } else {
            showToast(toastQueue.removeFirst())
        }
    }

    private func clearToasts() {
        toastTask?.cancel()
        toastTask = nil
        toastQueue.removeAll()
        withAnimation(.easeInOut(duration: 0.25)) {
            activeToast = nil
        }
    }

    // MARK: - Drop and shelf

    /// The rows the shelf face lays its items out in, which set its height
    /// (see `ShelfLayout`). They follow the items — one up to five, two past
    /// that — except that while a panel is open they only ever grow. An item
    /// removed from six leaves the face as it was, two rows with a gap,
    /// rather than pulling the panel's edge up from under a pointer that was
    /// just at the bottom of it, on the button; the next open is one row.
    @Published private(set) var shelfRows = 1

    private func fitShelfRows(_ count: Int) {
        let needed = ShelfLayout.rows(for: count)
        let rows = hoveredIslands > 0 ? max(shelfRows, needed) : needed
        if shelfRows != rows { shelfRows = rows }
    }

    /// The collapsed island says "Drop on Isle" while a file drag is under
    /// way — but never over a live alert, which outranks everything.
    var showsDropNotice: Bool {
        fileDragInFlight && acceptsDrops
    }

    /// Whether the island takes a drop at all right now. Not while an
    /// approval, question or failure holds the panel: the drop face would
    /// cover the thing that needs answering.
    var acceptsDrops: Bool {
        !hasLiveActivity
    }

    /// From `FileDragWatch`, on every change.
    func fileDragChanged(_ inFlight: Bool) {
        guard fileDragInFlight != inFlight else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            fileDragInFlight = inFlight
        }
    }

    /// A drag reached an island (or left the last one): what it carries.
    func setDropPayload(_ payload: DropPayload?) {
        guard dropPayload != payload else { return }
        dropPayload = payload
    }

    /// The targets the drop face offers for this payload, in order: Start
    /// Claude only for exactly one folder, AirDrop only when AirDrop can
    /// take these items. Keep is always offered — when the shelf is full it
    /// says so and doesn't light (see `canKeep`).
    func dropTargets(for payload: DropPayload) -> [DropTarget] {
        var targets: [DropTarget] = []
        if payload.claudeFolder != nil { targets.append(.startClaude) }
        targets.append(.keep)
        if payload.canAirDrop { targets.append(.airDrop) }
        return targets
    }

    /// A target that would do something if released on: offered, and for
    /// Keep, room on the shelf for at least one of the items.
    func canPerform(_ target: DropTarget, with payload: DropPayload) -> Bool {
        guard dropTargets(for: payload).contains(target) else { return false }
        if target == .keep { return shelf.wouldKeep(payload.urls) > 0 }
        return true
    }

    /// The drop was released on a target. Keeping goes to the shelf face, so
    /// the panel the pointer is still over shows what was kept; the other
    /// two leave the panel where it was.
    func performDrop(_ target: DropTarget, with payload: DropPayload) {
        guard acceptsDrops, canPerform(target, with: payload) else { return }
        switch target {
        case .startClaude:
            if let folder = payload.claudeFolder { ClaudeLauncher.start(in: folder) }
        case .keep:
            if shelf.add(payload.items) > 0 { selectTab(.shelf) }
        case .airDrop:
            AirDropSender.shared.send(payload.urls)
        }
    }

    /// From the shelf face.
    func startClaude(in folder: URL) {
        shelf.prune()
        ClaudeLauncher.start(in: folder)
    }

    func airDrop(_ urls: [URL]) {
        shelf.prune()
        AirDropSender.shared.send(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    // MARK: - Transport

    // The routed player handles every command over AppleScript, so controls
    // are live whenever a track is showing, regardless of which app owns the
    // system now-playing session.
    var canControlPlayback: Bool { media.hasTrack && routedPlayer != nil }
    var canSeek: Bool { canControlPlayback && media.duration > 0 }

    /// Shuffle/repeat state for the transport buttons, read from the merged
    /// model so the optimistic hold in `holdOptimisticTransport` shows through.
    var isShuffled: Bool { media.isShuffled }
    var repeatMode: RepeatMode { media.repeatMode }

    func togglePlayPause() {
        guard let player = routedPlayer else { return }
        player.playPause()
        // Optimistic: flip locally so the icon and scrubber react at once
        // rather than waiting up to a second for the next poll to confirm.
        // Re-anchor the clock at the current position with the new rate so
        // the bar stops/resumes from where it visually is.
        let now = Date()
        anchorElapsed = projectedElapsed(at: now)
        anchorDate = now
        media.isPlaying.toggle()
        media.playbackRate = media.isPlaying ? 1 : 0
        anchorRate = media.playbackRate
        lastApplied = media

        // Hold this state until a source confirms it, so the next poll can't
        // flicker it back before the player has processed the command.
        pendingPlayState = media.isPlaying
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    func nextTrack() { routedPlayer?.nextTrack() }
    func previousTrack() { routedPlayer?.previousTrack() }

    /// Toggle shuffle, optimistically, then hold it until a source confirms so a
    /// stale 1 Hz poll can't flicker it back before the player processes the flip.
    func toggleShuffle() {
        guard let player = routedPlayer, canControlPlayback else { return }
        player.toggleShuffle()
        let want = !media.isShuffled
        media.isShuffled = want
        lastApplied = media
        pendingShuffle = want
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Toggle repeat, optimistically. Off ↔ all in both players: Spotify's
    /// AppleScript has no repeat-one at all, and Music's `one` — set in Music
    /// itself, shown here as the lit repeat-1 key — clears to off, which is
    /// what pressing a lit key should do. One control, one meaning.
    func toggleRepeat() {
        guard let player = routedPlayer, canControlPlayback else { return }
        player.toggleRepeat()
        let want: RepeatMode = media.repeatMode == .off ? .all : .off
        media.repeatMode = want
        lastApplied = media
        pendingRepeat = want
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Commits a scrub. Called on drag end, not continuously — seeking on
    /// every drag sample makes the source app stutter.
    func commitScrub() {
        guard let scrubTarget, media.duration > 0, let player = routedPlayer else {
            self.scrubTarget = nil
            return
        }
        let seconds = scrubTarget * media.duration
        player.seek(to: seconds)

        // Optimistically move our own clock, otherwise the thumb snaps back
        // to the old position until the source reports the new one. The
        // anchor has to move too — it's what the scrubber actually renders
        // from, so updating only the model would leave the bar where it was.
        media.reportedElapsed = seconds
        media.timestamp = Date()
        anchorElapsed = seconds
        anchorDate = Date()
        lastApplied = media
        self.scrubTarget = nil

        // Hold the seek target so a stale poll can't snap the bar back to the
        // pre-seek position before Spotify reports the new one.
        pendingSeekTarget = seconds
        pendingCommandDeadline = Date().addingTimeInterval(Self.commandGrace)
    }

    /// Progress to render: the drag target while scrubbing, else the smoothed
    /// playback clock.
    func displayProgress(at date: Date = Date()) -> Double {
        if let scrubTarget { return scrubTarget }
        guard media.duration > 0 else { return 0 }
        return projectedElapsed(at: date) / media.duration
    }
}


#if DEBUG
// MARK: - Preview support

/// Drives the toasts from SwiftUI previews and the debug menu. In this
/// file rather than beside the previews because `activeToast` and
/// `showToast` are private, and Swift's `private` is file-scoped — so an
/// extension here can reach them without widening their access for the app.
extension NotchViewModel {
    /// One of each kind, in the order they read best: the two adapter events
    /// that bracket a charge, the two terminal states, a peripheral, then the
    /// two agenda messages.
    ///
    /// Levels come from the machine the preview is running on rather than from
    /// constants, so the numbers on screen are in the same ballpark as the
    /// menu bar's — a demo that says 89% on a Mac sitting at 100% reads as a
    /// mock-up rather than as the feature. Rounded to the nearest ten, which
    /// is as precise as a glance at a demo needs to be.
    ///
    /// A function rather than a stored value because it samples live state:
    /// held as a `static let` it would freeze whatever the battery happened to
    /// read the first time the preview was built.
    static func previewToasts() -> [IslandToast] {
        let live = PowerMonitor.read()
        let level = live.map { roundedToTen($0.percent) } ?? 80

        // The one level that can't just mirror reality: a low-battery toast
        // fires on crossing a threshold, so on a Mac at 100% the honest
        // preview is what the toast *will* say — 20% — not the current level.
        // On a Mac that really is low, the real number is the accurate one.
        let lowLevel = min(level, 20)

        return [
            .pluggedIn(percent: level, minutesToFull: live?.minutesToFull ?? 80),
            .fullyCharged(),
            .lowBattery(percent: lowLevel),
            .unplugged(percent: level, minutesToEmpty: live?.minutesToEmpty ?? 627),
            .lowPowerMode(on: live?.isLowPowerMode == false),
            .device(PeripheralBattery(
                name: "AirPods Pro", address: "A4:F6:E6:76:55:32",
                percent: 12, minorType: "Headphones",
                vendorID: DeviceSymbol.appleVendorID, productID: 0x2024
            )),
            .event(
                key: "preview-event", title: "Design review",
                minutesBefore: 5, tint: IslandToast.legible(NSColor.systemBlue.cgColor)
            ),
            .reminder(
                key: "preview-reminder", title: "Call the dentist",
                tint: IslandToast.legible(NSColor.systemOrange.cgColor)
            ),
        ]
    }

    /// Nearest ten, clamped to a real battery's range.
    private static func roundedToTen(_ percent: Int) -> Int {
        min(100, max(0, Int((Double(percent) / 10).rounded()) * 10))
    }

    /// Pins a toast on screen with no timer, so a static preview doesn't empty
    /// itself four seconds after the canvas renders it.
    func pinPreviewToast(_ toast: IslandToast) {
        activeToast = toast
    }

    /// The same for a shortcut's notice.
    func pinShortcutNotice(_ notice: IslandToast) {
        shortcutNotice = notice
    }

    /// Cycles the full set on a loop, through the real queue and the real
    /// timers. The gap between toasts is deliberate: it's long enough to see
    /// the island hand itself back to whatever was underneath before the next
    /// one claims it, which is the half of the behaviour a still can't show.
    func runPreviewToastLoop() async {
        while !Task.isCancelled {
            for toast in Self.previewToasts() {
                enqueueToast(toast)
                try? await Task.sleep(for: .seconds(5.2))
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

/// Puts the Claude face into a fixed state for previews and the offscreen
/// render harness — see `ClaudePanelFixture`. Sets the published values the
/// face reads directly, with no watcher, hook or timer behind them, so a
/// render shows exactly the state described and nothing eases it away.
extension NotchViewModel {
    /// Feeds one reading through the real selection path — the records, the
    /// registry, the requests — as a background pass would land it, with no
    /// watcher, registry scan or transcript behind it. For checking the
    /// session list and the pin off-app; never starts the bridge.
    func applyTestReading(statuses: [ClaudeStatus], sessions: [ClaudeSession], requests: [ClaudeRequest] = []) {
        claudeRunning = true
        claudeStatuses = statuses
        claudeRequests = requests
        claudeReadWantsApply = true
        applyClaudeReading(ClaudeReading(sessions: sessions, tails: [:]), generation: claudeReadGeneration)
    }

    /// Lands one `claude agents` read, as the monitor would (Milestone 21).
    /// After `applyTestReading`, which is what turns the bridge on.
    func applyTestAgents(_ agents: [ClaudeAgent]) {
        receiveAgents(agents)
    }

    /// A record arriving from the watcher, through the same path a real
    /// one takes — for tests of what the face does with it.
    func previewReceive(_ status: ClaudeStatus) {
        applyClaudeStatus(status)
        followTrails([status])
    }

    /// The trail's steps, as a scan would deliver them, for tests.
    func previewReceiveTrail(_ status: ClaudeStatus) {
        followTrails([status])
    }

    func applyPreviewFixture(_ fixture: ClaudePanelFixture) {
        claudeState = fixture.state
        claudeProject = fixture.project
        claudeSessionId = fixture.sessionId ?? fixture.request?.sessionId ?? "preview-session"
        claudeRequests = fixture.sessionRequests + (fixture.request.map { [$0] } ?? [])
        // Through the real merge, as if `claude agents` had listed
        // `fixture.agents` (Milestone 21).
        backgroundMerge = ClaudeBackground.merge(
            hookSessionIds: fixture.sessions.compactMap(\.sessionId), registry: [], agents: fixture.agents,
            finishedAt: [:], now: Date())
        sessionList = ClaudeBackground.rows(live: fixture.sessions, merge: backgroundMerge, request: request(for:))
        claudeBackground = claudeSessionId.flatMap { backgroundMerge.info[$0] }
        claudeStateFromAgent = fixture.stateFromAgent
        sessionListShown = fixture.listShown
        sessionPin = fixture.pinned ? claudeSessionId.map { ClaudeSelection.Pin(sessionId: $0) } : nil
        sessionHosts = fixture.sessionHosts
        claudeAction = fixture.action
        claudeTarget = fixture.target
        claudeErrorType = fixture.errorType
        claudeResetAt = fixture.resetAt
        claudeLimitKind = fixture.limitKind
        claudeLimitNext = fixture.limitNext
        claudeUpdatedAt = fixture.state == .disconnected ? nil : fixture.updatedAt
        claudeRequestId = fixture.request?.id
        pendingRequest = fixture.request
        questionIndex = fixture.questionIndex
        isReviewingRemember = fixture.reviewingRemember
        questionPicks = fixture.picks.isEmpty
            ? Array(repeating: [], count: fixture.request?.questions.count ?? 0)
            : fixture.picks
        if let word = fixture.workingWord { workingWord = word }
        // The published mirrors only — no assertion is taken for a preview.
        isKeepingAwake = fixture.keepAwake
        otherSessions = fixture.others
        sessionHost = fixture.host
        composing = fixture.composing
        replyDelivery = fixture.delivery
        claudeFinalLine = ClaudeDoneLine.line(from: fixture.lastMessage)
        claudeSubagents = fixture.subagents
        if let id = claudeSessionId {
            var trail = ClaudeTrail()
            for step in fixture.steps {
                trail.observe(phase: .working, action: step.action, target: step.target, toolActive: false)
            }
            trail.setPrompt(fixture.prompt)
            claudeTrails = fixture.steps.isEmpty && fixture.prompt == nil ? [:] : [id: trail]
        }
        claudeBlock = fixture.blocked
        claudeLeftovers = fixture.left
        if let toast = fixture.toast { pinPreviewToast(toast) }
        if let id = claudeSessionId {
            queuedReplies = fixture.queued.isEmpty ? [:] : [id: fixture.queued.map {
                QueuedReply(id: UUID(), text: $0, queuedAt: Date())
            }]
        }
        // In the face, not on the home grid, whatever the suite last had —
        // unless the fixture is the grid's.
        isHome = fixture.home
        if let id = claudeSessionId { replyDrafts[id] = fixture.replyDraft.isEmpty ? nil : fixture.replyDraft }
        answerDraft = fixture.answerDraft
        denialDraft = fixture.denialDraft
        activeTab = .claude
    }
}
#endif
