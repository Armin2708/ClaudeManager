// ClaudeSessions — native macOS floating status panel for live Claude Code sessions.
// Single-file AppKit app. See docs/superpowers/specs/2026-07-09-claude-sessions-panel-design.md

import AppKit
import Foundation
import QuartzCore
#if canImport(ServiceManagement)
import ServiceManagement
#endif

// MARK: - Model

enum SessionStatus: Int {
    // Ordered by sort priority (lower sorts first).
    case error = 0
    case waiting = 1
    case working = 2
    case doneUnseen = 3
    case idle = 4

    init(fileString s: String) {
        switch s {
        case "working": self = .working
        case "waiting": self = .waiting
        case "done_unseen": self = .doneUnseen
        case "error": self = .error
        default: self = .idle // "idle" or anything unexpected
        }
    }

    var label: String {
        switch self {
        case .error: return "Error"
        case .waiting: return "Waiting"
        case .working: return "Working"
        case .doneUnseen: return "Done"
        case .idle: return "Idle"
        }
    }

    var color: NSColor {
        switch self {
        case .error: return .systemRed
        case .waiting: return .systemYellow
        case .working: return .systemGreen
        case .doneUnseen: return .systemOrange
        case .idle: return NSColor.systemGray
        }
    }
}

struct Session {
    let sessionId: String
    let name: String
    let cwd: String
    let pid: Int
    let status: SessionStatus
    // True when the effective status came from a hook status file (overlay).
    let fromFile: Bool
    // Set when this session's process is a descendant of another live
    // session's process — i.e. a subagent/teammate spawned by that session —
    // or when this is a synthetic child row (subagent/background task).
    var parentId: String? = nil
    // SF Symbol override for synthetic child rows ("person" / "terminal").
    var childGlyph: String? = nil
}

enum HostApp {
    case iterm, terminal, vscode, pycharm, unknown

    var glyphSymbol: String {
        switch self {
        case .iterm, .terminal: return "terminal"
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .pycharm: return "hammer"
        case .unknown: return "app.dashed"
        }
    }
    var appName: String? {
        switch self {
        case .iterm: return "iTerm"
        case .terminal: return "Terminal"
        case .vscode: return "Visual Studio Code"
        case .pycharm: return "PyCharm"
        case .unknown: return nil
        }
    }
}

// MARK: - Environment / paths

enum Env {
    static var statusDir: String {
        if let override = ProcessInfo.processInfo.environment["SESSION_STATUS_DIR"], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".claude/session-status")
    }
    static var agentsCmdOverride: String? {
        if let c = ProcessInfo.processInfo.environment["CLAUDE_AGENTS_CMD"], !c.isEmpty { return c }
        return nil
    }
}

// Debug logging to file (enabled while diagnosing click-to-focus).
func dbg(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = ("~/Library/Logs/ClaudeSessions.log" as NSString).expandingTildeInPath
    if let h = FileHandle(forWritingAtPath: path) {
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Process helpers

@discardableResult
func runProcess(_ launchPath: String, _ args: [String], timeout: TimeInterval = 8) -> (out: String, code: Int32)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = Pipe()
    do {
        try p.run()
    } catch {
        return nil
    }
    // Read fully then wait to avoid pipe deadlock on large output.
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let s = String(data: data, encoding: .utf8) ?? ""
    return (s, p.terminationStatus)
}

// MARK: - Claude binary resolution

final class ClaudeLocator {
    static let shared = ClaudeLocator()
    private(set) var path: String?

    private init() {
        resolve()
    }

    private func resolve() {
        // 1. `which claude` via a login shell (picks up user PATH).
        if let r = runProcess("/bin/zsh", ["-lc", "which claude"]), r.code == 0 {
            let candidate = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty, FileManager.default.isExecutableFile(atPath: candidate) {
                path = candidate
                return
            }
        }
        // 2. Fallback well-known locations.
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/share/claude",
            "\(home)/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            path = c
            return
        }
        path = nil
    }
}

// MARK: - Host app detection (process ancestry)

final class HostResolver {
    static let shared = HostResolver()
    private var cache: [Int: (host: HostApp, hostPid: Int?)] = [:]

    func host(forPid pid: Int) -> HostApp {
        return resolve(pid).host
    }

    func hostPid(forPid pid: Int) -> Int? {
        return resolve(pid).hostPid
    }

    private func resolve(_ pid: Int) -> (host: HostApp, hostPid: Int?) {
        if let cached = cache[pid] { return cached }
        var current = pid
        var result: (host: HostApp, hostPid: Int?) = (.unknown, nil)
        for _ in 0..<16 {
            guard current > 1, let info = procInfo(current) else { break }
            let comm = (info.comm as NSString).lastPathComponent.lowercased()
            if comm.contains("iterm") { result = (.iterm, current); break }
            if comm.contains("pycharm") || comm.contains("jetbrains") { result = (.pycharm, current); break }
            if comm.contains("code") || comm.contains("electron") { result = (.vscode, current); break }
            if comm == "terminal" { result = (.terminal, current); break }
            if info.ppid <= 1 { result = (.unknown, current); break }
            current = info.ppid
        }
        cache[pid] = result
        return result
    }

    func prune(livePids: Set<Int>) {
        cache = cache.filter { livePids.contains($0.key) }
        ancestorCache = ancestorCache.filter { livePids.contains($0.key) }
    }

    // Ancestor pid chain (nearest first), cached per pid.
    private var ancestorCache: [Int: [Int]] = [:]

    func ancestors(of pid: Int) -> [Int] {
        if let cached = ancestorCache[pid] { return cached }
        var chain: [Int] = []
        var current = pid
        for _ in 0..<24 {
            guard current > 1, let info = procInfo(current), info.ppid > 1 else { break }
            chain.append(info.ppid)
            current = info.ppid
        }
        ancestorCache[pid] = chain
        return chain
    }

    private func procInfo(_ pid: Int) -> (ppid: Int, comm: String)? {
        guard let r = runProcess("/bin/ps", ["-o", "ppid=,comm=", "-p", "\(pid)"]), r.code == 0 else { return nil }
        let line = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        // Format: "<ppid> <comm...>"
        guard let spaceIdx = line.firstIndex(where: { $0 == " " }) else { return nil }
        let ppidStr = String(line[line.startIndex..<spaceIdx])
        let comm = String(line[line.index(after: spaceIdx)...]).trimmingCharacters(in: .whitespaces)
        guard let ppid = Int(ppidStr.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (ppid, comm)
    }
}

// MARK: - Terminal title resolution (iTerm2, by tty)

/// Shows the real terminal-tab title for iTerm2-hosted sessions. Batch-queries
/// iTerm2 once per 10s cycle (single AppleScript round-trip), maps tty → title,
/// and matches sessions via their pid's tty. Non-iTerm hosts keep the agents name.
final class TitleResolver {
    static let shared = TitleResolver()
    private var titlesByTty: [String: String] = [:]   // "ttys012" -> tab title
    private var ttyByPid: [Int: String] = [:]
    private var lastQuery = Date.distantPast
    private let queue = DispatchQueue(label: "title-resolver")

    func title(for session: Session) -> String? {
        guard HostResolver.shared.host(forPid: session.pid) == .iterm else { return nil }
        var t: String?
        queue.sync {
            if let tty = ttyByPid[session.pid] { t = titlesByTty[tty] }
        }
        return (t?.isEmpty == false) ? t : nil
    }

    /// Called from the poll loop (background thread).
    func refresh(pids: [Int]) {
        guard Date().timeIntervalSince(lastQuery) > 10 else { return }
        lastQuery = Date()

        var newTtyByPid: [Int: String] = [:]
        for pid in pids {
            if let r = runProcess("/bin/ps", ["-o", "tty=", "-p", "\(pid)"]) {
                let tty = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !tty.isEmpty, tty != "??" { newTtyByPid[pid] = tty }
            }
        }

        // One round-trip: "tty<TAB>title" per line.
        let script = """
        tell application "iTerm2"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (tty of s) & (character id 9) & (name of s) & linefeed
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        var newTitles: [String: String] = [:]
        var err: NSDictionary?
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.googlecode.iterm2" }),
           let s = NSAppleScript(source: script) {
            let result = s.executeAndReturnError(&err)
            if let err = err { dbg("title query error: \(err)") }
            if err == nil, let text = result.stringValue {
                dbg("title query ok: \(text.split(separator: "\n").count) sessions")
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    // iTerm reports "/dev/ttys012"; ps reports "ttys012".
                    let tty = (String(parts[0]) as NSString).lastPathComponent
                    newTitles[tty] = Self.sanitize(String(parts[1]))
                }
            }
        }
        queue.sync {
            ttyByPid = newTtyByPid
            if !newTitles.isEmpty { titlesByTty = newTitles }
        }
        dbg("titles map=\(newTitles) ttyByPid=\(newTtyByPid)")
    }

    /// iTerm session names arrive as "⠂ Actual Title (node)": a braille
    /// spinner / status glyph prefix from Claude Code's terminal-title updates
    /// plus iTerm's trailing job name. Strip both, keep the real title.
    static func sanitize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // Leading spinner/status glyphs (braille range + common markers).
        while let first = s.unicodeScalars.first,
              (0x2800...0x28FF).contains(first.value) || "✳✶●○◐◓◑◒*".unicodeScalars.contains(first) {
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }
        // Trailing " (job)" appended by iTerm (single token, e.g. "(node)").
        if let r = s.range(of: #"\s*\([A-Za-z0-9._-]+\)$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Data source

final class DataSource {
    struct Result {
        let sessions: [Session]
        let reachable: Bool
    }

    func fetch() -> Result {
        guard let agents = fetchAgents() else {
            return Result(sessions: [], reachable: false)
        }
        let liveIds = Set(agents.map { $0.sessionId })
        let livePids = Set(agents.map { $0.pid })
        HostResolver.shared.prune(livePids: livePids)
        TitleResolver.shared.refresh(pids: agents.map { $0.pid })

        // Read status files, delete stale ones, build overlay map.
        let overlay = loadAndReapStatusFiles(liveIds: liveIds)

        var sessions: [Session] = []
        for a in agents {
            let effective: SessionStatus
            let fromFile: Bool
            if let s = overlay[a.sessionId] {
                effective = s
                fromFile = true
            } else {
                effective = (a.status == "busy") ? .working : .idle
                fromFile = false
            }
            sessions.append(Session(sessionId: a.sessionId,
                                    name: titleBySid[a.sessionId] ?? a.name,
                                    cwd: a.cwd,
                                    pid: a.pid, status: effective, fromFile: fromFile))
        }

        dbg("overlay titles=\(titleBySid.mapValues { String($0.prefix(20)) })")
        // Subagent nesting: a session whose process descends from another live
        // session's process is that session's child (nearest ancestor wins).
        let sessionByPid = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0.sessionId) })
        for i in sessions.indices {
            for anc in HostResolver.shared.ancestors(of: sessions[i].pid) {
                if let parentSid = sessionByPid[anc], parentSid != sessions[i].sessionId {
                    sessions[i].parentId = parentSid
                    break
                }
            }
        }

        // Synthetic child rows: in-session subagents and running background
        // tasks published by the hook (they have no CLI process of their own).
        var withChildren = sessions
        for parent in sessions {
            for child in childrenBySid[parent.sessionId] ?? [] {
                withChildren.append(Session(
                    sessionId: "\(parent.sessionId)#\(child.id)",
                    name: child.name,
                    cwd: parent.cwd,
                    pid: parent.pid,
                    status: .working,
                    fromFile: true,
                    parentId: parent.sessionId,
                    childGlyph: ["agent", "teammate", "local_agent"].contains(child.kind)
                        ? "person.fill" : "gearshape.fill"))
            }
        }
        return Result(sessions: withChildren, reachable: true)
    }

    private struct Agent {
        let pid: Int; let cwd: String; let sessionId: String; let name: String; let status: String
    }

    private func fetchAgents() -> [Agent]? {
        let raw: (out: String, code: Int32)?
        if let cmd = Env.agentsCmdOverride {
            raw = runProcess("/bin/zsh", ["-lc", cmd])
        } else if let bin = ClaudeLocator.shared.path {
            raw = runProcess(bin, ["agents", "--json"])
        } else {
            return nil
        }
        guard let r = raw, r.code == 0 else { return nil }
        guard let data = r.out.data(using: .utf8) else { return nil }
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var result: [Agent] = []
        for obj in arr {
            guard let sid = obj["sessionId"] as? String else { continue }
            let pid = (obj["pid"] as? Int) ?? 0
            let cwd = (obj["cwd"] as? String) ?? ""
            let name = (obj["name"] as? String) ?? sid
            let status = (obj["status"] as? String) ?? "idle"
            result.append(Agent(pid: pid, cwd: cwd, sessionId: sid, name: name, status: status))
        }
        return result
    }

    struct ChildInfo {
        let id: String
        let kind: String
        let name: String
    }

    private var childrenBySid: [String: [ChildInfo]] = [:]
    // Session topic titles extracted by the hook from transcript ai-title
    // entries — host-app agnostic (works for VS Code/PyCharm terminals too).
    private(set) var titleBySid: [String: String] = [:]

    private func loadAndReapStatusFiles(liveIds: Set<String>) -> [String: SessionStatus] {
        var overlay: [String: SessionStatus] = [:]
        childrenBySid = [:]
        titleBySid = [:]
        let fm = FileManager.default
        let dir = Env.statusDir
        guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return overlay }
        for file in files where file.hasSuffix(".json") {
            let full = (dir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: full),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = obj["session_id"] as? String else { continue }
            if !liveIds.contains(sid) {
                // Stale: no live session — delete.
                try? fm.removeItem(atPath: full)
                continue
            }
            let statusStr = (obj["status"] as? String) ?? "idle"
            overlay[sid] = SessionStatus(fileString: statusStr)
            if let t = obj["title"] as? String, !t.isEmpty { titleBySid[sid] = t }
            if let kids = obj["children"] as? [[String: Any]] {
                childrenBySid[sid] = kids.compactMap { k in
                    guard let id = k["id"] as? String else { return nil }
                    return ChildInfo(id: id,
                                     kind: (k["kind"] as? String) ?? "task",
                                     name: (k["name"] as? String) ?? "subtask")
                }
            } else {
                childrenBySid[sid] = []
            }
        }
        return overlay
    }
}

// MARK: - Status edge bar (the panel's signature: a scannable color column)

final class StatusBar: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 1.5
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ status: SessionStatus) {
        layer?.removeAnimation(forKey: "pulse")
        layer?.opacity = 1
        layer?.backgroundColor = status.color
            .withAlphaComponent(status == .idle ? 0.35 : 1.0).cgColor
        if status == .working {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.3
            a.duration = 1.1
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(a, forKey: "pulse")
        }
    }
}

// MARK: - Row view

final class RowView: NSView {
    let sessionId: String
    private(set) var session: Session
    private let bar = StatusBar(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    private var barLeading: NSLayoutConstraint!
    private var rowHeight: NSLayoutConstraint!
    private var hovered = false
    var onClick: ((RowView) -> Void)?

    init(session: Session) {
        self.sessionId = session.sessionId
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        for v in [bar, nameLabel, projectLabel, statusLabel, glyph] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }

        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        // Repo path in monospace — the terminal's own vernacular.
        projectLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        projectLabel.textColor = .tertiaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle
        projectLabel.maximumNumberOfLines = 1
        glyph.contentTintColor = .quaternaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        statusLabel.font = NSFont.systemFont(ofSize: 9, weight: .bold)
        statusLabel.alignment = .right
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(bar)
        addSubview(nameLabel)
        addSubview(projectLabel)
        addSubview(statusLabel)
        addSubview(glyph)

        barLeading = bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        rowHeight = heightAnchor.constraint(equalToConstant: 46)
        NSLayoutConstraint.activate([
            rowHeight,
            barLeading,
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            bar.widthAnchor.constraint(equalToConstant: 3),

            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),

            glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            glyph.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),

            nameLabel.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -8),

            projectLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            projectLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            projectLabel.trailingAnchor.constraint(lessThanOrEqualTo: glyph.leadingAnchor, constant: -8),
        ])

        update(session: session)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(session: Session) {
        self.session = session
        bar.configure(session.status)
        let isChild = session.parentId != nil
        barLeading.constant = isChild ? 26 : 12
        rowHeight.constant = isChild ? 36 : 46
        // Synthetic children keep their own name (task/agent description) —
        // never the parent terminal's title (same pid).
        let title = session.childGlyph != nil
            ? session.name
            : (TitleResolver.shared.title(for: session) ?? session.name)
        nameLabel.stringValue = title
        nameLabel.font = NSFont.systemFont(ofSize: isChild ? 11 : 13, weight: isChild ? .medium : .semibold)
        nameLabel.textColor = isChild ? .secondaryLabelColor : .labelColor
        // Children show what they are instead of the repo path; parents show
        // the home-relative path in mono.
        if isChild {
            projectLabel.stringValue = session.childGlyph == "person.fill" ? "agent" : "task"
        } else {
            let home = NSHomeDirectory()
            projectLabel.stringValue = session.cwd.hasPrefix(home)
                ? "~" + session.cwd.dropFirst(home.count)
                : session.cwd
        }
        // Status as a tracked-out uppercase word in its color.
        statusLabel.attributedStringValue = NSAttributedString(
            string: session.status.label.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .kern: 0.9,
                .foregroundColor: session.status.color,
            ])
        let symbol = session.childGlyph
            ?? HostResolver.shared.host(forPid: session.pid).glyphSymbol
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        applyBackground()
    }

    private func applyBackground() {
        var base = NSColor.clear
        if session.status == .waiting { base = NSColor.systemYellow.withAlphaComponent(0.10) }
        if session.status == .error { base = NSColor.systemRed.withAlphaComponent(0.10) }
        if hovered {
            base = base == .clear
                ? NSColor.labelColor.withAlphaComponent(0.06)
                : base.withAlphaComponent(0.16)
        }
        layer?.backgroundColor = base.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; applyBackground() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyBackground() }

    override func mouseDown(with event: NSEvent) {
        // Single click focuses. Right-click handled via menu(for:).
        onClick?(self)
    }
}

// MARK: - Panel content view

final class ContentView: NSView {
    weak var controller: AppController?
    override var isFlipped: Bool { true }
    override func menu(for event: NSEvent) -> NSMenu? {
        return controller?.buildContextMenu()
    }
    override func rightMouseDown(with event: NSEvent) {
        if let m = controller?.buildContextMenu() {
            NSMenu.popUpContextMenu(m, with: event, for: self)
        }
    }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var effectView: NSVisualEffectView!
    private var content: ContentView!
    private var headerLabel: NSTextField!
    private var headerCounts: NSTextField!
    private var footerLabel: NSTextField!
    private var rowsStack: NSStackView!
    private var timer: Timer?
    private let dataSource = DataSource()

    private var rowViews: [String: RowView] = [:]
    private var paused = false
    private var lastReachable = true
    private var lastSessions: [Session] = []

    private let panelWidth: CGFloat = 280

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Panel construction

    private func buildPanel() {
        let initialRect = NSRect(x: 0, y: 0, width: panelWidth, height: 120)
        panel = NSPanel(contentRect: initialRect,
                        styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
                        backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        effectView = NSVisualEffectView(frame: initialRect)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]

        content = ContentView(frame: initialRect)
        content.controller = self
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)

        headerLabel = NSTextField(labelWithString: "")
        headerLabel.attributedStringValue = NSAttributedString(
            string: "SESSIONS",
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .heavy),
                .kern: 1.5,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ])
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        headerCounts = NSTextField(labelWithString: "")
        headerCounts.alignment = .right
        headerCounts.translatesAutoresizingMaskIntoConstraints = false

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 3
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footerLabel = NSTextField(labelWithString: "")
        footerLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        footerLabel.textColor = .systemOrange
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.isHidden = true

        content.addSubview(headerLabel)
        content.addSubview(headerCounts)
        content.addSubview(rowsStack)
        content.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),

            headerCounts.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -15),
            headerCounts.firstBaselineAnchor.constraint(equalTo: headerLabel.firstBaselineAnchor),
            headerCounts.leadingAnchor.constraint(greaterThanOrEqualTo: headerLabel.trailingAnchor, constant: 8),

            rowsStack.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            rowsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),

            footerLabel.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 6),
            footerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footerLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -8),
        ])

        panel.contentView = effectView
        panel.setFrameAutosaveName("ClaudeSessionsPanel")
        if panel.frame.origin == .zero {
            positionTopRight()
        }
        panel.orderFrontRegardless()
    }

    private func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.maxX - panelWidth - 20
        let y = vf.maxY - 400
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Refresh

    private func refresh() {
        if paused { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = self.dataSource.fetch()
            DispatchQueue.main.async {
                self.apply(result)
            }
        }
    }

    private func apply(_ result: DataSource.Result) {
        lastReachable = result.reachable
        if result.reachable {
            lastSessions = result.sessions
            footerLabel.isHidden = true
        } else {
            // Keep last rows; show footer.
            footerLabel.stringValue = "daemon unreachable"
            footerLabel.isHidden = false
        }
        render(sessions: lastSessions)
    }

    private func statusOrder(_ s: SessionStatus) -> Int { s.rawValue }

    private func render(sessions: [Session]) {
        // Two-level ordering: top-level sessions by status, each followed
        // inline by its subagent children (also by status). A child whose
        // parent vanished is promoted to top level.
        let byStatus: (Session, Session) -> Bool = { a, b in
            if a.status.rawValue != b.status.rawValue { return a.status.rawValue < b.status.rawValue }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let ids = Set(sessions.map { $0.sessionId })
        let topLevel = sessions.filter { $0.parentId == nil || !ids.contains($0.parentId!) }
        let childrenOf = Dictionary(grouping: sessions.filter { $0.parentId != nil && ids.contains($0.parentId!) },
                                    by: { $0.parentId! })
        var sorted: [Session] = []
        for parent in topLevel.sorted(by: byStatus) {
            sorted.append(parent)
            sorted.append(contentsOf: (childrenOf[parent.sessionId] ?? []).sorted(by: byStatus))
        }

        // Diff rows by sessionId to preserve pulse animation continuity.
        let liveIds = Set(sorted.map { $0.sessionId })
        for (sid, view) in rowViews where !liveIds.contains(sid) {
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
            rowViews.removeValue(forKey: sid)
        }

        var ordered: [RowView] = []
        for s in sorted {
            let row: RowView
            if let existing = rowViews[s.sessionId] {
                existing.update(session: s)
                row = existing
            } else {
                let v = RowView(session: s)
                v.onClick = { [weak self] r in self?.handleClick(r) }
                v.translatesAutoresizingMaskIntoConstraints = false
                rowViews[s.sessionId] = v
                row = v
            }
            ordered.append(row)
        }

        // Re-order stack to match sort.
        for v in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(v) }
        for v in ordered {
            rowsStack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        // Header counts real sessions only (synthetic children excluded):
        // colored "● n" pairs, one per active status, quiet text when idle.
        let real = sorted.filter { $0.childGlyph == nil }
        let counts: [(Int, SessionStatus)] = [
            (real.filter { $0.status == .error }.count, .error),
            (real.filter { $0.status == .waiting }.count, .waiting),
            (real.filter { $0.status == .working }.count, .working),
            (real.filter { $0.status == .doneUnseen }.count, .doneUnseen),
        ]
        let summary = NSMutableAttributedString()
        for (n, status) in counts where n > 0 {
            if summary.length > 0 {
                summary.append(NSAttributedString(string: "  "))
            }
            summary.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 8),
                .foregroundColor: status.color,
                .baselineOffset: 0.5,
            ]))
            summary.append(NSAttributedString(string: " \(n)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        if summary.length == 0 {
            summary.append(NSAttributedString(string: "all idle", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        headerCounts.attributedStringValue = summary

        resizePanel(rows: sorted)

        // All-idle → dim.
        let anyActive = sorted.contains { $0.status != .idle }
        let target: CGFloat = anyActive ? 1.0 : 0.3
        if abs(panel.alphaValue - target) > 0.01 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = target
            }
        }
    }

    private func resizePanel(rows: [Session]) {
        let headerH: CGFloat = 12 + 14 + 8
        let rowsH = rows.reduce(CGFloat(0)) { $0 + ($1.parentId != nil ? 36 : 46) }
            + CGFloat(max(rows.count - 1, 0)) * 3
        let footerH: CGFloat = footerLabel.isHidden ? 0 : 18
        let bottomPad: CGFloat = 10
        let height = max(64, headerH + rowsH + footerH + bottomPad)

        var frame = panel.frame
        let delta = height - frame.height
        frame.size.height = height
        frame.origin.y -= delta // keep top edge fixed
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: Click to focus

    private func handleClick(_ row: RowView) {
        let session = row.session
        let host = HostResolver.shared.host(forPid: session.pid)
        dbg("click session=\(session.name) pid=\(session.pid) host=\(host) hostPid=\(String(describing: HostResolver.shared.hostPid(forPid: session.pid)))")
        focus(host: host, session: session)

        if session.status == .doneUnseen {
            markSeen(session)
        }
    }

    private func markSeen(_ session: Session) {
        let dir = Env.statusDir
        let path = (dir as NSString).appendingPathComponent("\(session.sessionId).json")
        let obj: [String: Any] = [
            "session_id": session.sessionId,
            "status": "idle",
            "cwd": session.cwd,
            "updated_at": Int(Date().timeIntervalSince1970),
            "event": "seen",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        // Reflect immediately.
        if let idx = lastSessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            let s = lastSessions[idx]
            lastSessions[idx] = Session(sessionId: s.sessionId, name: s.name, cwd: s.cwd,
                                        pid: s.pid, status: .idle, fromFile: true,
                                        parentId: s.parentId)
            render(sessions: lastSessions)
        }
    }

    // Focus must NEVER create windows/tabs/projects. Strategy per host:
    // 1. Raise the existing window whose title matches the project (System
    //    Events AXRaise — precise, needs one-time Accessibility grant).
    // 2. Fallback: activate the host app process we found via ancestry —
    //    activation alone can't open anything.
    private func focus(host: HostApp, session: Session) {
        switch host {
        case .iterm:
            focusITerm(session: session)
        case .terminal:
            focusTerminal(session: session)
        case .vscode:
            raiseWindowOrActivate(processName: "Code", bundlePrefix: "com.microsoft.VSCode",
                                  titleNeedle: (session.cwd as NSString).lastPathComponent,
                                  fallbackPid: HostResolver.shared.hostPid(forPid: session.pid))
        case .pycharm:
            raiseWindowOrActivate(processName: "PyCharm", bundlePrefix: "com.jetbrains.pycharm",
                                  titleNeedle: (session.cwd as NSString).lastPathComponent,
                                  fallbackPid: HostResolver.shared.hostPid(forPid: session.pid))
        case .unknown:
            activate(pid: HostResolver.shared.hostPid(forPid: session.pid))
        }
    }

    /// Try to AXRaise the host-app window whose title contains the project
    /// folder name; regardless of outcome, activate the app. Neither step can
    /// spawn a new window/tab/project.
    private func raiseWindowOrActivate(processName: String, bundlePrefix: String,
                                       titleNeedle: String, fallbackPid: Int?) {
        // Activate via LaunchServices (`open -b`, no arguments) — Dock-click
        // semantics: brings the app forward AND switches to its Space, opens
        // nothing when the app already has windows. NSRunningApplication
        // .activate() from a background app makes the app frontmost without
        // pulling the user to its Space (cooperative activation).
        var launched = false
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.bundleIdentifier?.hasPrefix(bundlePrefix) == true {
            let r = runProcess("/usr/bin/open", ["-b", app.bundleIdentifier!])
            launched = (r?.code == 0)
            dbg("open -b \(app.bundleIdentifier!) -> \(String(describing: r?.code))")
            break
        }
        if !launched {
            let ok = activate(pid: fallbackPid)
            dbg("pid-activate fallback \(String(describing: fallbackPid)) -> \(ok)")
        }
        let script = """
        tell application "System Events"
            if exists process "\(escapeAS(processName))" then
                tell process "\(escapeAS(processName))"
                    repeat with w in windows
                        if name of w contains "\(escapeAS(titleNeedle))" then
                            perform action "AXRaise" of w
                            exit repeat
                        end if
                    end repeat
                end tell
            end if
        end tell
        """
        runAppleScript(script)
    }

    @discardableResult
    private func activate(pid: Int?) -> Bool {
        // The ancestry walk can land on an Electron/JetBrains helper process;
        // hop from that pid to its .regular app via bundle URL ownership.
        guard let pid = pid,
              let proc = NSRunningApplication(processIdentifier: pid_t(pid)) else { return false }
        if proc.activationPolicy == .regular { return proc.activate() }
        if let bid = proc.bundleIdentifier {
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.bundleIdentifier == bid {
                return app.activate()
            }
        }
        return false
    }

    private func focusITerm(session: Session) {
        // Match the session by its tty — reliable without iTerm2 shell
        // integration. ps gives e.g. "ttys012"; iTerm reports "/dev/ttys012".
        guard let r = runProcess("/bin/ps", ["-o", "tty=", "-p", "\(session.pid)"]),
              case let tty = r.out.trimmingCharacters(in: .whitespacesAndNewlines),
              !tty.isEmpty, tty != "??" else {
            dbg("iterm: no tty for pid \(session.pid); activating only")
            _ = runProcess("/usr/bin/open", ["-b", "com.googlecode.iterm2"])
            return
        }
        let script = """
        tell application "iTerm2"
            set matched to false
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s ends with "\(escapeAS(tty))" then
                            select w
                            select t
                            select s
                            set matched to true
                            exit repeat
                        end if
                    end repeat
                    if matched then exit repeat
                end repeat
                if matched then exit repeat
            end repeat
            activate
            return matched
        end tell
        """
        runAppleScript(script)
    }

    private func focusTerminal(session: Session) {
        let name = session.name
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (custom title of t contains "\(escapeAS(name))") then
                            set selected of t to true
                            set index of w to 1
                            return
                        end if
                    end try
                end repeat
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    private func escapeAS(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            if let script = NSAppleScript(source: source) {
                let result = script.executeAndReturnError(&err)
                if let err = err {
                    dbg("applescript error: \(err)")
                } else {
                    dbg("applescript ok result=\(result.stringValue ?? result.description)")
                }
            }
        }
    }

    // MARK: Context menu

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()

        let pauseItem = NSMenuItem(title: paused ? "Resume updates" : "Pause updates",
                                   action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLoginEnabled() ? .on : .off
        if !launchAtLoginAvailable() { loginItem.isEnabled = false }
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func togglePause() {
        paused.toggle()
        if !paused { refresh() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Launch at login

    private func launchAtLoginAvailable() -> Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    private func launchAtLoginEnabled() -> Bool {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        #endif
        return false
    }

    @objc private func toggleLogin() {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                NSSound.beep()
            }
        }
        #endif
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.run()
