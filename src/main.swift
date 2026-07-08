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
    case waiting = 0
    case working = 1
    case doneUnseen = 2
    case idle = 3

    init(fileString s: String) {
        switch s {
        case "working": self = .working
        case "waiting": self = .waiting
        case "done_unseen": self = .doneUnseen
        default: self = .idle // "idle" or anything unexpected
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
    private var cache: [Int: HostApp] = [:]

    func host(forPid pid: Int) -> HostApp {
        if let cached = cache[pid] { return cached }
        var current = pid
        var result: HostApp = .unknown
        for _ in 0..<16 {
            guard current > 1, let info = procInfo(current) else { break }
            let comm = (info.comm as NSString).lastPathComponent.lowercased()
            if comm.contains("iterm") { result = .iterm; break }
            if comm.contains("pycharm") || comm.contains("jetbrains") { result = .pycharm; break }
            if comm.contains("code") || comm.contains("electron") { result = .vscode; break }
            if comm == "terminal" { result = .terminal; break }
            if info.ppid <= 1 { break }
            current = info.ppid
        }
        cache[pid] = result
        return result
    }

    func prune(livePids: Set<Int>) {
        cache = cache.filter { livePids.contains($0.key) }
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
            sessions.append(Session(sessionId: a.sessionId, name: a.name, cwd: a.cwd,
                                    pid: a.pid, status: effective, fromFile: fromFile))
        }
        return Result(sessions: sessions, reachable: true)
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

    private func loadAndReapStatusFiles(liveIds: Set<String>) -> [String: SessionStatus] {
        var overlay: [String: SessionStatus] = [:]
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
        }
        return overlay
    }
}

// MARK: - Status dot view (with pulse)

final class StatusDot: NSView {
    private let shape = CAShapeLayer()
    private let dim: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: dim, height: dim))
        wantsLayer = true
        layer?.addSublayer(shape)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: dim, height: dim) }

    func configure(_ status: SessionStatus) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = CGPath(ellipseIn: rect, transform: nil)
        shape.path = path
        shape.removeAnimation(forKey: "pulse")
        shape.opacity = 1
        switch status {
        case .working:
            shape.fillColor = NSColor.systemGreen.cgColor
            shape.strokeColor = NSColor.clear.cgColor
            shape.lineWidth = 0
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1.0
            a.toValue = 0.35
            a.duration = 0.9
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(a, forKey: "pulse")
        case .waiting:
            shape.fillColor = NSColor.systemYellow.cgColor
            shape.strokeColor = NSColor.clear.cgColor
            shape.lineWidth = 0
        case .doneUnseen:
            shape.fillColor = NSColor.clear.cgColor
            shape.strokeColor = NSColor.systemOrange.cgColor
            shape.lineWidth = 2
        case .idle:
            shape.fillColor = NSColor.systemGray.withAlphaComponent(0.6).cgColor
            shape.strokeColor = NSColor.clear.cgColor
            shape.lineWidth = 0
        }
    }

    override func layout() {
        super.layout()
        if let p = shape.path, p.boundingBox.width == 0 {
            shape.path = CGPath(ellipseIn: bounds.insetBy(dx: 1, dy: 1), transform: nil)
        }
    }
}

// MARK: - Row view

final class RowView: NSView {
    let sessionId: String
    private(set) var session: Session
    private let dot = StatusDot(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let projectLabel = NSTextField(labelWithString: "")
    private let glyph = NSImageView()
    var onClick: ((RowView) -> Void)?

    init(session: Session) {
        self.sessionId = session.sessionId
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        dot.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        projectLabel.translatesAutoresizingMaskIntoConstraints = false
        glyph.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        projectLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        projectLabel.textColor = .secondaryLabelColor
        projectLabel.lineBreakMode = .byTruncatingMiddle
        projectLabel.maximumNumberOfLines = 1
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)

        addSubview(dot)
        addSubview(nameLabel)
        addSubview(projectLabel)
        addSubview(glyph)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 38),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            glyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 16),
            glyph.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: glyph.leadingAnchor, constant: -6),

            projectLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            projectLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            projectLabel.trailingAnchor.constraint(lessThanOrEqualTo: glyph.leadingAnchor, constant: -6),
        ])

        update(session: session)
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(session: Session) {
        self.session = session
        dot.configure(session.status)
        nameLabel.stringValue = session.name
        let base = (session.cwd as NSString).lastPathComponent
        projectLabel.stringValue = base.isEmpty ? session.cwd : "— \(base)"
        let host = HostResolver.shared.host(forPid: session.pid)
        glyph.image = NSImage(systemSymbolName: host.glyphSymbol, accessibilityDescription: nil)

        if session.status == .waiting {
            layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.14).cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

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
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true
        effectView.autoresizingMask = [.width, .height]

        content = ContentView(frame: initialRect)
        content.controller = self
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)

        headerLabel = NSTextField(labelWithString: "")
        headerLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false

        rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.spacing = 2
        rowsStack.alignment = .leading
        rowsStack.distribution = .fill
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        footerLabel = NSTextField(labelWithString: "")
        footerLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        footerLabel.textColor = .systemOrange
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.isHidden = true

        content.addSubview(headerLabel)
        content.addSubview(rowsStack)
        content.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            headerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -12),

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
        let sorted = sessions.sorted { a, b in
            if a.status.rawValue != b.status.rawValue { return a.status.rawValue < b.status.rawValue }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
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

        // Header counts.
        let working = sorted.filter { $0.status == .working }.count
        let waiting = sorted.filter { $0.status == .waiting }.count
        let done = sorted.filter { $0.status == .doneUnseen }.count
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if done > 0 { parts.append("\(done) done") }
        headerLabel.stringValue = parts.isEmpty ? "\(sorted.count) idle" : parts.joined(separator: " · ")

        resizePanel(rowCount: sorted.count)

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

    private func resizePanel(rowCount: Int) {
        let headerH: CGFloat = 10 + 16 + 8
        let rowsH = CGFloat(max(rowCount, 0)) * 38 + CGFloat(max(rowCount - 1, 0)) * 2
        let footerH: CGFloat = footerLabel.isHidden ? 0 : 18
        let bottomPad: CGFloat = 10
        let height = max(60, headerH + rowsH + footerH + bottomPad)

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
                                        pid: s.pid, status: .idle, fromFile: true)
            render(sessions: lastSessions)
        }
    }

    private func focus(host: HostApp, session: Session) {
        switch host {
        case .iterm:
            focusITerm(session: session)
        case .terminal:
            focusTerminal(session: session)
        case .vscode:
            _ = runProcess("/usr/bin/open", ["-a", "Visual Studio Code", session.cwd])
        case .pycharm:
            _ = runProcess("/usr/bin/open", ["-a", "PyCharm", session.cwd])
        case .unknown:
            _ = runProcess("/usr/bin/open", ["-a", "iTerm", session.cwd]) // best-effort; falls through if absent
        }
    }

    private func focusITerm(session: Session) {
        let cwd = session.cwd
        let name = session.name
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set p to ""
                        try
                            set p to (variable s named "session.path")
                        end try
                        if p is equal to "\(escapeAS(cwd))" then
                            select w
                            select t
                            return
                        end if
                        try
                            if name of s contains "\(escapeAS(name))" then
                                select w
                                select t
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
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
                script.executeAndReturnError(&err)
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
