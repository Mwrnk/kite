import AppKit
import Darwin

/// The output panel under the editor: the running command, its output, and a line to type input.
@MainActor
final class RunPanel: ChromeView, NSTextViewDelegate, NSTextFieldDelegate {
    /// Opens `file` at a 1-based line and column (from a clicked `file:line` in the output).
    var openLocation: ((URL, Int, Int) -> Void)?

    private let header = Chrome.label()
    private let stopButton = Chrome.textButton("stop", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let output = NSTextView(usingTextLayoutManager: false)
    private let input = NSTextField()
    private var process: Process?
    private var master: Int32 = -1
    private var reader: DispatchSourceRead?
    private var directory = URL(fileURLWithPath: NSHomeDirectory())
    /// Where the line being written started, so file:line links are found on whole lines.
    private var lineStart = 0

    var isRunning: Bool { process?.isRunning == true }
    /// For the dev-tools check: what the panel shows.
    var shownText: String { header.stringValue + "\n" + output.string }

    /// For the dev-tools check: sends a line as if typed in the input field.
    func sendForTesting(_ line: String) {
        input.stringValue = line
        _ = control(input, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        hairlines = [.minY]

        stopButton.target = self
        stopButton.action = #selector(stop)
        stopButton.isHidden = true
        output.isEditable = false
        output.isSelectable = true
        output.drawsBackground = false
        output.textContainerInset = NSSize(width: 14, height: 6)
        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.textColor = Chrome.text
        output.isVerticallyResizable = true
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        output.delegate = self
        output.linkTextAttributes = [.foregroundColor: Chrome.text, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                     .cursor: NSCursor.pointingHand]
        scroll.documentView = output
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        input.placeholderString = "type input here, Return sends it"
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.textColor = Chrome.text
        input.delegate = self

        for v in [header, stopButton, scroll, input] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stopButton.leadingAnchor.constraint(equalTo: header.trailingAnchor, constant: 16),
            stopButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -4),
            input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            input.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Running

    /// Runs `task` in a pseudo-terminal, so programs show output as they go and can read input.
    func run(_ task: RunTask) {
        stop()
        output.string = ""
        lineStart = 0
        directory = task.directory
        header.stringValue = "\(task.command)    in \(task.directory.lastPathComponent)/"
        header.textColor = Chrome.text

        var m: Int32 = -1, s: Int32 = -1
        var size = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &size) == 0 else { append("Couldn't start a terminal for the command.\n"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        p.arguments = ["-l", "-c", task.command]   // a login shell, so PATH matches your terminal
        p.currentDirectoryURL = task.directory
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"; env["NO_COLOR"] = "1"; env["CLICOLOR"] = "0"
        env.removeValue(forKey: "KITE_SESSION_DIR")
        p.environment = env
        let slave = FileHandle(fileDescriptor: s, closeOnDealloc: true)
        p.standardInput = slave
        p.standardOutput = slave
        p.standardError = slave
        let started = Date()
        p.terminationHandler = Self.onExit { [weak self] code in
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(code: code, seconds: seconds) }
            }
        }
        do { try p.run() } catch {
            append("Couldn't run it: \(error.localizedDescription)\n")
            close(m)
            return
        }
        try? slave.close()   // the child has its own copy
        process = p
        master = m
        stopButton.isHidden = false

        reader = Self.read(m) { @Sendable [weak self] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.received(data) }
            }
        }
        window?.makeFirstResponder(input)
    }

    /// Reads the terminal on a background queue (not the main actor) and hands each chunk to `deliver`.
    nonisolated private static func read(_ fd: Int32, deliver: @escaping @Sendable (Data) -> Void) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { source.cancel(); return }   // the program closed the terminal
            deliver(Data(buffer[0..<n]))
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    nonisolated private static func onExit(_ done: @escaping @Sendable (Int32) -> Void) -> @Sendable (Process) -> Void {
        { proc in done(proc.terminationStatus) }
    }

    @objc func stop() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGINT)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
    }

    private func finished(code: Int32, seconds: TimeInterval) {
        stopButton.isHidden = true
        let time = String(format: "%.1f s", seconds)
        header.stringValue += code == 0 ? "    done in \(time)" : "    exit \(code) after \(time)"
        header.textColor = code == 0 ? Chrome.dim : Chrome.error
        process = nil
        master = -1
    }

    private func received(_ data: Data) {
        var text = String(decoding: data, as: UTF8.self)
        // Color and cursor codes some tools send anyway, and the terminal's \r before each \n.
        text = text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        append(text)
    }

    private func append(_ text: String) {
        guard let storage = output.textStorage else { return }
        let atBottom = scroll.contentView.bounds.maxY >= output.bounds.height - 4
        storage.append(NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: Chrome.text,
        ]))
        linkLocations(from: lineStart)
        if let lastNewline = storage.string.lastIndex(of: "\n") {
            lineStart = storage.string.utf16.distance(from: storage.string.startIndex, to: lastNewline) + 1
        }
        if atBottom { output.scrollToEndOfDocument(nil) }
    }

    // MARK: Clickable file:line

    private static let patterns: [NSRegularExpression] = [
        // path/file.ext:12 or :12:5 (compilers, linters, Node)
        try! NSRegularExpression(pattern: #"((?:[~./\w-]+/)*[\w.-]+\.[A-Za-z]\w*):(\d+)(?::(\d+))?"#),
        // Python: File "path/file.py", line 12
        try! NSRegularExpression(pattern: #"File "([^"]+)", line (\d+)()"#),
    ]

    private func linkLocations(from start: Int) {
        guard let storage = output.textStorage else { return }
        let text = storage.string as NSString
        let range = NSRange(location: start, length: text.length - start)
        for pattern in Self.patterns {
            for m in pattern.matches(in: storage.string, range: range) {
                let path = text.substring(with: m.range(at: 1))
                let line = Int(text.substring(with: m.range(at: 2))) ?? 1
                let column = m.range(at: 3).length > 0 ? Int(text.substring(with: m.range(at: 3))) ?? 1 : 1
                let file = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                    : path.hasPrefix("~") ? URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                    : directory.appendingPathComponent(path)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                var link = URLComponents()
                link.scheme = "kite-open"
                link.path = file.path
                link.queryItems = [URLQueryItem(name: "line", value: "\(line)"), URLQueryItem(name: "column", value: "\(column)")]
                if let url = link.url { storage.addAttribute(.link, value: url, range: m.range) }
            }
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "kite-open",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let line = parts.queryItems?.first { $0.name == "line" }?.value.flatMap(Int.init) ?? 1
        let column = parts.queryItems?.first { $0.name == "column" }?.value.flatMap(Int.init) ?? 1
        openLocation?(URL(fileURLWithPath: parts.path), line, column)
        return true
    }

    // MARK: Input

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        guard master >= 0, isRunning else { NSSound.beep(); return true }
        let line = Array((input.stringValue + "\n").utf8)
        _ = line.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }   // the terminal echoes it into the output
        input.stringValue = ""
        return true
    }
}
