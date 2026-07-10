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

    // MARK: Codex sessions (process scan — Codex has no hook/status contract)

    /// Live Codex CLI sessions: interactive `codex` processes (ones with a
    /// controlling terminal), cwd via lsof. Status is a CPU heuristic — the
    /// TUI idles near 0% while waiting for input and burns CPU while working.
    func fetchCodex() -> Result {
        guard let r = runProcess("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,tty=,command="]), r.code == 0 else {
            return Result(sessions: [], reachable: false)
        }
        struct Proc { let pid: Int; let ppid: Int; let cpu: Double; let tty: String }
        var procs: [Proc] = []
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count == 5,
                  let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let cpu = Double(parts[2]) else { continue }
            let tty = String(parts[3])
            let cmd = String(parts[4])
            guard tty != "??" else { continue }  // interactive sessions only
            let bin = cmd.split(separator: " ").first.map { ($0 as NSString).lastPathComponent } ?? ""
            let isCodex = bin == "codex" || (bin == "node" && cmd.contains("/codex"))
            guard isCodex else { continue }
            procs.append(Proc(pid: pid, ppid: ppid, cpu: cpu, tty: tty))
        }
        // Drop children of other codex processes (exec/sandbox subprocesses).
        let pids = Set(procs.map { $0.pid })
        procs.removeAll { pids.contains($0.ppid) }

        TitleResolver.shared.refresh(pids: procs.map { $0.pid })
        var sessions: [Session] = []
        for p in procs {
            let cwd = cwdOf(pid: p.pid)
            let folder = (cwd as NSString).lastPathComponent
            sessions.append(Session(sessionId: "codex-\(p.pid)",
                                    name: folder.isEmpty ? "codex" : folder,
                                    cwd: cwd,
                                    pid: p.pid,
                                    status: p.cpu > 8 ? .working : .idle,
                                    fromFile: false))
        }
        return Result(sessions: sessions, reachable: true)
    }

    private func cwdOf(pid: Int) -> String {
        guard let r = runProcess("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]),
              r.code == 0 else { return "" }
        for line in r.out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return ""
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

// MARK: - Claude theme

enum Theme {
    /// Claude coral — the brand accent.
    static let coral = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // #D97757
    /// Warm dark surface (Claude dark mode) / warm cream (light mode).
    static var surfaceTint: NSColor {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(srgbRed: 0.149, green: 0.149, blue: 0.141, alpha: 0.55)          // #262624
            : NSColor(srgbRed: 0.941, green: 0.933, blue: 0.902, alpha: 0.45)          // #F0EEE6
    }
    /// Anthropic faces when installed; graceful system fallback otherwise.
    static func display(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let styreneName = weight.rawValue >= NSFont.Weight.semibold.rawValue
            ? "Styrene A Medium" : "Styrene A Regular"
        return NSFont(name: styreneName, size: size)
            ?? NSFont(name: "StyreneA-Medium", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
}

// MARK: - Claude starburst mark (drawn, no assets)

final class ClaudeMark: NSView {
    private let rays = CAShapeLayer()

    // Dimmed when Claude is the inactive side of the source toggle.
    var active = true {
        didSet {
            rays.strokeColor = (active ? Theme.coral : NSColor.tertiaryLabelColor).cgColor
        }
    }

    var spinning = false {
        didSet {
            guard spinning != oldValue else { return }
            rays.removeAnimation(forKey: "spin")
            if spinning {
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = -2 * Double.pi
                a.duration = 3.5
                a.repeatCount = .infinity
                rays.add(a, forKey: "spin")
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(rays)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        rebuild()
    }

    private func rebuild() {
        guard bounds.width > 0 else { return }
        let R = min(bounds.width, bounds.height) / 2
        let path = CGMutablePath()
        let c = CGPoint(x: 0, y: 0) // rays layer is positioned at view center
        // Claude's mark: a hand-drawn starburst — 12 rays of varied length.
        let lengths: [CGFloat] = [1.0, 0.72, 0.9, 0.68, 0.97, 0.7, 1.0, 0.72, 0.9, 0.68, 0.97, 0.7]
        for i in 0..<12 {
            let angle = CGFloat(i) * .pi / 6 + .pi / 12
            let r = R * lengths[i]
            path.move(to: c)
            path.addLine(to: CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r))
        }
        rays.path = path
        rays.strokeColor = (active ? Theme.coral : NSColor.tertiaryLabelColor).cgColor
        rays.fillColor = nil
        rays.lineWidth = max(1.6, R * 0.16)
        rays.lineCap = .round
        // Zero-sized bounds centered on the view: rotation spins in place.
        rays.bounds = .zero
        rays.position = CGPoint(x: bounds.midX, y: bounds.midY)
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
    // Pins the row to the stack width; created once and reactivated on
    // re-add instead of leaking a fresh duplicate every refresh.
    var widthConstraint: NSLayoutConstraint?
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
        // Titles truncate rather than dictate the window's minimum width.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        projectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        nameLabel.font = Theme.display(isChild ? 11 : 13, isChild ? .medium : .semibold)
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
    override func mouseUp(with event: NSEvent) {
        controller?.contentClicked()
    }
}

// MARK: - App controller

final class AppController: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    // Plain layer-backed root — NEVER NSVisualEffectView: vibrancy blends
    // subview colors with the desktop behind, so "black" renders as gray and
    // can't match the true-black hardware notch.
    private var effectView: NSView!
    private var tintView: NSView!
    // While a slide animation is in flight, periodic refresh must not stomp
    // the frame with a non-animated setFrame.
    private var transitionUntil = Date.distantPast
    // Expanded panel dragged off the notch → free-floating card.
    private var isDetached = false
    // Lets applyExpandedLayout pre-build rows without triggering positioning.
    private var suppressPositioning = false
    private var content: ContentView!
    private var headerMark: ClaudeMark!
    // The CLAUDE / CODEX source toggle: real buttons (labels + gesture
    // recognizers lose clicks to the window-background drag), each with its
    // brand logo — the starburst headerMark doubles as the Claude icon.
    private var claudeBtn: NSButton!
    private var codexBtn: NSButton!
    private var codexIcon: NSImageView!
    private var codexLogo: NSImage?
    private var headerCounts: NSTextField!
    private var collapseButton: NSButton!
    // Island-only widgets: mark in the left notch wing, counts in the right.
    private var islandMark: ClaudeMark!
    private var islandCounts: NSTextField!
    private var islandMarkX: NSLayoutConstraint!
    private var islandCountsX: NSLayoutConstraint!
    private var headerTop: NSLayoutConstraint!
    private var footerLabel: NSTextField!
    private var rowsStack: NSStackView!
    private var timer: Timer?
    private let dataSource = DataSource()

    private var rowViews: [String: RowView] = [:]
    private var paused = false
    private var lastReachable = true
    private var lastSessions: [Session] = []
    private var hadFirstData = false

    // Which CLI's sessions the panel shows.
    private enum SessionSource: Int { case claude = 0, codex = 1 }
    private var source = SessionSource(
        rawValue: UserDefaults.standard.integer(forKey: "SessionSource")) ?? .claude

    // Island (collapsed) mode — a small capsule docked beside the notch.
    private(set) var isCollapsed = UserDefaults.standard.bool(forKey: "IslandCollapsed")
    // Constraints that only apply expanded (they force a tall minimum height).
    private var expandedConstraints: [NSLayoutConstraint] = []
    // Hardware-notch shape mask applied to the island.
    private let islandMask = CAShapeLayer()

    private let panelWidth: CGFloat = 280
    private let islandHeight: CGFloat = 34

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildPanel()
        headerMark.spinning = true  // loading until first data arrives
        if isCollapsed { applyIslandLayout() } else { applyExpandedLayout() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Island (collapse) mode

    @objc func toggleIsland() {
        isCollapsed.toggle()
        UserDefaults.standard.set(isCollapsed, forKey: "IslandCollapsed")
        if isCollapsed {
            applyIslandLayout(animate: true)
        } else {
            applyExpandedLayout(animate: true)
        }
    }

    func contentClicked() {
        if isCollapsed { toggleIsland() }
    }

    // MARK: Source toggle (CLAUDE / CODEX)

    @objc private func selectClaude() { setSource(.claude) }
    @objc private func selectCodex() { setSource(.codex) }

    private func setSource(_ s: SessionSource) {
        guard s != source else { return }
        source = s
        UserDefaults.standard.set(s.rawValue, forKey: "SessionSource")
        updateSourceHeader()
        // Clear the other CLI's rows right away; the mark spins until the
        // first fetch for the new source lands.
        lastSessions = []
        hadFirstData = false
        headerMark.spinning = true
        render(sessions: [])
        refresh()
    }

    private func headerWord(_ s: String, active: Bool) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: Theme.display(9, .heavy),
            .kern: 1.5,
            .foregroundColor: active
                ? Theme.coral.withAlphaComponent(0.9)
                : NSColor.tertiaryLabelColor,
        ])
    }

    private func updateSourceHeader() {
        claudeBtn.attributedTitle = headerWord("CLAUDE", active: source == .claude)
        codexBtn.attributedTitle = headerWord("CODEX", active: source == .codex)
        headerMark.active = source == .claude
        // Tint is baked into a raster copy — template tinting doesn't apply
        // reliably to SVG-backed NSImages.
        if let logo = codexLogo {
            let color: NSColor = source == .codex ? .white : .tertiaryLabelColor
            codexIcon.image = tinted(logo, color: color, size: NSSize(width: 24, height: 24))
        }
    }

    private func tinted(_ image: NSImage, color: NSColor, size: NSSize) -> NSImage {
        let out = NSImage(size: size)
        out.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// The built-in notched display; NSScreen.main follows keyboard focus and
    /// wanders across monitors.
    private var notchScreen: NSScreen? {
        let notched = NSScreen.screens.first { screen in
            if #available(macOS 12.0, *) { return screen.safeAreaInsets.top > 0 }
            return false
        }
        return notched ?? NSScreen.main
    }

    /// Physical notch metrics (with a sensible fake on non-notched displays).
    private func notchMetrics(on screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        if #available(macOS 12.0, *), screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            return (screen.frame.width - left.width - right.width, screen.safeAreaInsets.top)
        }
        return (180, 30)
    }

    private func applyIslandLayout(animate: Bool = false) {
        rowsStack.isHidden = true
        footerLabel.isHidden = true
        collapseButton.isHidden = true
        headerMark.isHidden = true
        headerCounts.isHidden = true
        claudeBtn.isHidden = true
        codexBtn.isHidden = true
        codexIcon.isHidden = true
        isDetached = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.isMovableByWindowBackground = false
        NSLayoutConstraint.deactivate(expandedConstraints)
        // Guard BEFORE the render below so it can't snap frame/mask mid-slide.
        if animate { transitionUntil = Date().addingTimeInterval(0.5) }
        render(sessions: lastSessions)  // strips rows so the small frame can apply
        // Slide up into the notch, then reveal the wing content.
        islandMark.isHidden = true
        islandCounts.isHidden = true
        positionIsland(animate: animate)
        // Wings appear only after the window has snapped to the island frame
        // (0.46) so their edge-relative constraints resolve correctly.
        DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 0.5 : 0)) { [weak self] in
            guard let self = self, self.isCollapsed else { return }
            self.islandMark.isHidden = false
            self.islandCounts.isHidden = false
        }
    }

    private func positionIsland(animate: Bool = false) {
        guard let screen = notchScreen else { return }
        let notch = notchMetrics(on: screen)
        // Wings flank the physical notch: mark on the left, counts on the right.
        let wing = max(islandCounts.intrinsicContentSize.width, 14) + 26
        let w = notch.width + wing * 2
        let h = notch.height + 8   // small lip below the notch
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        islandMarkX.constant = wing / 2
        islandCountsX.constant = -wing / 2
        setFrameKeepingMask(NSRect(x: x, y: y, width: w, height: h),
                            animate: animate, bottomRadius: 13)
    }

    /// The expanded panel hangs from the notch: flush to the top edge,
    /// centered on the notch, same silhouette — part of the notch UI.
    /// Once dragged off (isDetached), it's a free-floating card: it keeps the
    /// user's position and only its height follows the row count.
    private func positionExpanded(rows: [Session], animate: Bool = false) {
        guard let screen = notchScreen else { return }
        let notch = notchMetrics(on: screen)
        let topInset: CGFloat = isDetached ? 12 : notch.height + 6
        headerTop.constant = topInset
        // Ask Auto Layout for the exact minimum height — a hand-computed
        // number that undershoots gets silently clamped by constraints while
        // the mask uses the smaller value, leaving a transparent strip.
        content.layoutSubtreeIfNeeded()
        let h = max(content.fittingSize.height, isDetached ? 64 : notch.height + 44)
        if isDetached {
            // Keep the user's placement; grow/shrink from the top edge.
            let f = panel.frame
            setFrameKeepingMask(NSRect(x: f.minX, y: f.maxY - h, width: f.width, height: h),
                                animate: animate, bottomRadius: 14)
            return
        }
        let w = max(panelWidth + 60, notch.width + 60)
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        setFrameKeepingMask(NSRect(x: x, y: y, width: w, height: h),
                            animate: animate, bottomRadius: 20)
    }

    // Generation counter so a newer transition cancels an older one's snap.
    private var shapeGeneration = 0

    /// Move/resize the black shape. Animated transitions NEVER resize the
    /// window per-frame (that forces a backing-store realloc + Auto Layout
    /// pass every frame — visibly laggy). Instead the window jumps once to
    /// the union of old and new frames (the extra area is transparent) and a
    /// single GPU-side Core Animation path morph does the visible slide; the
    /// window snaps to the exact target after the morph lands.
    private func setFrameKeepingMask(_ target: NSRect, animate: Bool, bottomRadius: CGFloat) {
        let changed = abs(panel.frame.minX - target.minX) > 0.5 || abs(panel.frame.minY - target.minY) > 0.5
            || abs(panel.frame.width - target.width) > 0.5 || abs(panel.frame.height - target.height) > 0.5
        if !animate {
            if changed {
                if Date() < transitionUntil { return }  // never stomp a slide
                panel.setFrame(target, display: true)
            }
            applyMask(rect: NSRect(origin: .zero, size: target.size),
                      bottomRadius: bottomRadius, animated: false)
            return
        }

        shapeGeneration += 1
        let gen = shapeGeneration
        transitionUntil = Date().addingTimeInterval(0.55)
        let old = panel.frame
        let union = old.union(target)
        panel.setFrame(union, display: true)  // one instant, invisible resize
        // Both shapes expressed in the union window's layer coordinates.
        let oldLocal = NSRect(x: old.minX - union.minX, y: old.minY - union.minY,
                              width: old.width, height: old.height)
        let newLocal = NSRect(x: target.minX - union.minX, y: target.minY - union.minY,
                              width: target.width, height: target.height)
        applyMask(rect: oldLocal, bottomRadius: shapeRadius, animated: false)
        applyMask(rect: newLocal, bottomRadius: bottomRadius, animated: true)
        shapeRadius = bottomRadius
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.46) { [weak self] in
            guard let self = self, self.shapeGeneration == gen else { return }
            self.panel.setFrame(target, display: true)
            self.applyMask(rect: NSRect(origin: .zero, size: target.size),
                           bottomRadius: bottomRadius, animated: false)
        }
    }

    private var shapeRadius: CGFloat = 13

    /// Apple's notch silhouette in layer coordinates: straight top corners
    /// flush with the screen edge, convex bottom corners. Detached floating
    /// cards get a plain rounded rectangle.
    private func applyMask(rect: NSRect, bottomRadius: CGFloat, animated: Bool) {
        let x0 = rect.minX, y0 = rect.minY, w = rect.width, h = rect.height
        let p = CGMutablePath()
        if isDetached && !isCollapsed {
            p.addRoundedRect(in: CGRect(x: x0, y: y0, width: w, height: h),
                             cornerWidth: 14, cornerHeight: 14)
        } else {
            let br: CGFloat = bottomRadius
            p.move(to: CGPoint(x: x0, y: y0 + h))
            p.addLine(to: CGPoint(x: x0, y: y0 + br))
            p.addQuadCurve(to: CGPoint(x: x0 + br, y: y0), control: CGPoint(x: x0, y: y0))
            p.addLine(to: CGPoint(x: x0 + w - br, y: y0))
            p.addQuadCurve(to: CGPoint(x: x0 + w, y: y0 + br), control: CGPoint(x: x0 + w, y: y0))
            p.addLine(to: CGPoint(x: x0 + w, y: y0 + h))
            p.closeSubpath()
        }
        islandMask.removeAnimation(forKey: "morph")
        if animated, let old = islandMask.path {
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = old
            a.toValue = p
            a.duration = 0.42
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            islandMask.add(a, forKey: "morph")
        }
        islandMask.path = p
        // Oversized so the mask layer itself never clips mid-animation.
        islandMask.frame = CGRect(x: 0, y: 0, width: 4000, height: 4000)
        effectView.layer?.mask = islandMask
    }

    private func applyExpandedLayout(animate: Bool = false) {
        isDetached = false
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.isMovableByWindowBackground = true   // drag off the notch to detach
        islandMark.isHidden = true
        islandCounts.isHidden = true
        // Build the FULL content first (invisible behind alpha 0) so the
        // animation target height is correct from the start — computing it
        // before the rows exist animates to a stub and jumps later.
        content.alphaValue = animate ? 0 : 1
        NSLayoutConstraint.activate(expandedConstraints)
        rowsStack.isHidden = false
        collapseButton.isHidden = false
        footerLabel.isHidden = lastReachable
        headerMark.isHidden = false
        headerCounts.isHidden = false
        claudeBtn.isHidden = false
        codexBtn.isHidden = false
        codexIcon.isHidden = false
        updateSourceHeader()
        suppressPositioning = true
        render(sessions: lastSessions)
        suppressPositioning = false
        positionExpanded(rows: sortedForDisplay(lastSessions), animate: animate)
        if animate {
            // Fade the content in once the slide lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) { [weak self] in
                guard let self = self, !self.isCollapsed else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    self.content.animator().alphaValue = 1
                }
            }
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

        // Shape comes solely from the mask — no layer corner rounding, so the
        // top corners stay square and flush with the screen edge.
        effectView = NSView(frame: initialRect)
        effectView.wantsLayer = true
        effectView.autoresizingMask = [.width, .height]

        // True black, matching the hardware notch exactly.
        tintView = NSView(frame: initialRect)
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.black.cgColor
        tintView.autoresizingMask = [.width, .height]
        effectView.addSubview(tintView)

        content = ContentView(frame: initialRect)
        content.controller = self
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)

        headerMark = ClaudeMark(frame: .zero)
        headerMark.translatesAutoresizingMaskIntoConstraints = false

        claudeBtn = NSButton(title: "", target: self, action: #selector(selectClaude))
        claudeBtn.isBordered = false
        claudeBtn.translatesAutoresizingMaskIntoConstraints = false

        codexBtn = NSButton(title: "", target: self, action: #selector(selectCodex))
        codexBtn.isBordered = false
        codexBtn.translatesAutoresizingMaskIntoConstraints = false

        codexIcon = NSImageView()
        codexIcon.translatesAutoresizingMaskIntoConstraints = false
        codexIcon.imageScaling = .scaleProportionallyUpOrDown
        if let p = Bundle.main.path(forResource: "codex-logo", ofType: "svg") {
            codexLogo = NSImage(contentsOfFile: p)
        }
        codexIcon.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(selectCodex)))

        // The starburst mark is the Claude side's logo — clicking it selects.
        headerMark.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(selectClaude)))

        updateSourceHeader()

        headerCounts = NSTextField(labelWithString: "")
        headerCounts.alignment = .right
        headerCounts.translatesAutoresizingMaskIntoConstraints = false

        collapseButton = NSButton(image: NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left",
                                                 accessibilityDescription: "Collapse")!,
                                  target: self, action: #selector(toggleIsland))
        collapseButton.isBordered = false
        collapseButton.contentTintColor = .tertiaryLabelColor
        collapseButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        collapseButton.translatesAutoresizingMaskIntoConstraints = false

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

        islandMark = ClaudeMark(frame: .zero)
        islandMark.translatesAutoresizingMaskIntoConstraints = false
        islandMark.isHidden = true
        islandCounts = NSTextField(labelWithString: "")
        islandCounts.translatesAutoresizingMaskIntoConstraints = false
        islandCounts.isHidden = true

        content.addSubview(headerMark)
        content.addSubview(claudeBtn)
        content.addSubview(codexIcon)
        content.addSubview(codexBtn)
        content.addSubview(headerCounts)
        content.addSubview(collapseButton)
        content.addSubview(rowsStack)
        content.addSubview(footerLabel)
        content.addSubview(islandMark)
        content.addSubview(islandCounts)

        // Expanded content starts BELOW the physical notch (dead pixels).
        headerTop = claudeBtn.topAnchor.constraint(equalTo: content.topAnchor, constant: 44)
        NSLayoutConstraint.activate([
            headerTop,
            headerMark.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            headerMark.centerYAnchor.constraint(equalTo: claudeBtn.centerYAnchor),
            headerMark.widthAnchor.constraint(equalToConstant: 13),
            headerMark.heightAnchor.constraint(equalToConstant: 13),

            claudeBtn.leadingAnchor.constraint(equalTo: headerMark.trailingAnchor, constant: 5),

            codexIcon.leadingAnchor.constraint(equalTo: claudeBtn.trailingAnchor, constant: 12),
            codexIcon.centerYAnchor.constraint(equalTo: claudeBtn.centerYAnchor),
            codexIcon.widthAnchor.constraint(equalToConstant: 12),
            codexIcon.heightAnchor.constraint(equalToConstant: 12),

            codexBtn.leadingAnchor.constraint(equalTo: codexIcon.trailingAnchor, constant: 5),
            codexBtn.firstBaselineAnchor.constraint(equalTo: claudeBtn.firstBaselineAnchor),

            collapseButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -13),
            collapseButton.centerYAnchor.constraint(equalTo: claudeBtn.centerYAnchor),

            headerCounts.trailingAnchor.constraint(equalTo: collapseButton.leadingAnchor, constant: -8),
            headerCounts.firstBaselineAnchor.constraint(equalTo: claudeBtn.firstBaselineAnchor),
            headerCounts.leadingAnchor.constraint(greaterThanOrEqualTo: codexBtn.trailingAnchor, constant: 8),

            rowsStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            rowsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),

            footerLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
        ])

        // These force a tall minimum window height — deactivated in island mode.
        expandedConstraints = [
            rowsStack.topAnchor.constraint(equalTo: claudeBtn.bottomAnchor, constant: 8),
            footerLabel.topAnchor.constraint(equalTo: rowsStack.bottomAnchor, constant: 6),
            footerLabel.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -8),
        ]
        if !isCollapsed { NSLayoutConstraint.activate(expandedConstraints) }

        // Island widgets sit in the wings beside the physical notch; their
        // x-centers are updated in positionIsland() as wing width changes.
        islandMarkX = islandMark.centerXAnchor.constraint(equalTo: content.leadingAnchor, constant: 30)
        islandCountsX = islandCounts.centerXAnchor.constraint(equalTo: content.trailingAnchor, constant: -30)
        NSLayoutConstraint.activate([
            islandMarkX,
            islandMark.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            islandMark.widthAnchor.constraint(equalToConstant: 14),
            islandMark.heightAnchor.constraint(equalToConstant: 14),
            islandCountsX,
            islandCounts.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])

        // The panel is part of the notch UI in both modes: pure black, no
        // shadow, above everything, pinned through Space transitions.
        panel.appearance = NSAppearance(named: .darkAqua)
        tintView.layer?.backgroundColor = NSColor.black.cgColor
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false

        // Dragging the expanded panel detaches it from the notch.
        NotificationCenter.default.addObserver(self, selector: #selector(panelDidMove),
                                               name: NSWindow.didMoveNotification, object: panel)

        panel.contentView = effectView
        panel.orderFrontRegardless()
    }

    /// User drags the expanded panel: detach it into a floating card. If it's
    /// later dropped onto the notch, swallow it back.
    @objc private func panelDidMove(_ note: Notification) {
        guard !isCollapsed, Date() >= transitionUntil else { return }
        guard NSEvent.pressedMouseButtons != 0 else { return }
        if !isDetached {
            isDetached = true
            panel.hasShadow = true
            panel.level = .floating
            applyMask(rect: NSRect(origin: .zero, size: panel.frame.size),
                      bottomRadius: 14, animated: false)
            // Re-layout NOW: the card would otherwise keep the notch-mode top
            // inset (a big blank strip above the header) until the next poll,
            // then visibly snap.
            positionExpanded(rows: sortedForDisplay(lastSessions), animate: false)
        }
        scheduleDropCheck()
    }

    private func scheduleDropCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self, self.isDetached, !self.isCollapsed else { return }
            if NSEvent.pressedMouseButtons != 0 {
                self.scheduleDropCheck()
                return
            }
            // Dropped — on the notch? Swallow it back.
            if let screen = self.notchScreen,
               self.panel.frame.maxY >= screen.visibleFrame.maxY - 6,
               abs(self.panel.frame.midX - screen.frame.midX) < self.notchMetrics(on: screen).width {
                self.isCollapsed = true
                UserDefaults.standard.set(true, forKey: "IslandCollapsed")
                self.applyIslandLayout(animate: true)
            }
        }
    }

    // MARK: Refresh

    private func refresh() {
        if paused { return }
        let src = source
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let result = src == .codex ? self.dataSource.fetchCodex() : self.dataSource.fetch()
            DispatchQueue.main.async {
                // A slow fetch from before a source switch must not paint the
                // other CLI's sessions.
                guard self.source == src else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: DataSource.Result) {
        lastReachable = result.reachable
        if result.reachable {
            hadFirstData = true
            lastSessions = result.sessions
            footerLabel.isHidden = true
        } else {
            // Keep last rows; show footer.
            footerLabel.stringValue = "daemon unreachable"
            footerLabel.isHidden = isCollapsed
        }
        // The mark spins while loading or when the daemon is unreachable.
        headerMark.spinning = !hadFirstData || !result.reachable
        islandMark.spinning = headerMark.spinning
        render(sessions: lastSessions)
    }

    private func statusOrder(_ s: SessionStatus) -> Int { s.rawValue }

    /// Two-level ordering: top-level sessions by status, each followed inline
    /// by its subagent children (also by status). A child whose parent
    /// vanished is promoted to top level.
    private func sortedForDisplay(_ sessions: [Session]) -> [Session] {
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
        return sorted
    }

    private func render(sessions: [Session]) {
        let sorted = sortedForDisplay(sessions)

        // Island mode: no rows in the hierarchy at all — their (even hidden)
        // constraints would force a minimum window size and block the small
        // island frame. Counts still update below via the header summary.
        if isCollapsed {
            // Sweep SUBVIEWS, not arrangedSubviews — an orphaned row (subview
            // the stack no longer arranges) would otherwise survive here,
            // outlive rowViews.removeAll(), and paint stale content over live
            // rows on the next expand. removeFromSuperview alone suffices:
            // the stack drops removed subviews from its arrangement.
            for v in rowsStack.subviews.compactMap({ $0 as? RowView }) {
                v.removeFromSuperview()
            }
            rowViews.removeAll()
            updateHeaderCounts(sorted: sorted)
            positionIsland()
            return
        }

        // Duplicate session ids (e.g. one session listed twice by the daemon)
        // would put the same RowView into the stack twice and corrupt its
        // constraint chain — rows then pile up at the same y.
        var seenIds = Set<String>()
        let unique = sorted.filter { seenIds.insert($0.sessionId).inserted }
        if unique.count != sorted.count {
            dbg("render: dropped \(sorted.count - unique.count) duplicate session row(s)")
        }

        // Diff rows by sessionId to preserve pulse animation continuity.
        let liveIds = Set(unique.map { $0.sessionId })
        for (sid, view) in rowViews where !liveIds.contains(sid) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: sid)
        }

        var ordered: [RowView] = []
        for s in unique {
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
            if v.widthConstraint == nil {
                v.widthConstraint = v.widthAnchor.constraint(equalTo: rowsStack.widthAnchor)
            }
            v.widthConstraint?.isActive = true
        }
        // Heal orphans: any row subview the stack no longer arranges keeps a
        // stale frame and overlaps live rows. Log it — it's a bug upstream.
        let keep = Set(ordered.map { ObjectIdentifier($0) })
        for v in rowsStack.subviews.compactMap({ $0 as? RowView }) where !keep.contains(ObjectIdentifier(v)) {
            dbg("render: healed orphaned row \(v.sessionId.prefix(12)) (\(v.session.name.prefix(24)))")
            v.removeFromSuperview()
        }

        updateHeaderCounts(sorted: sorted)

        if !suppressPositioning {
            positionExpanded(rows: sorted, animate: false)
        }
    }

    private func updateHeaderCounts(sorted: [Session]) {
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
        islandCounts.attributedStringValue = summary
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

        let islandItem = NSMenuItem(title: isCollapsed ? "Expand panel" : "Collapse to island",
                                    action: #selector(toggleIsland), keyEquivalent: "")
        islandItem.target = self
        menu.addItem(islandItem)

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
