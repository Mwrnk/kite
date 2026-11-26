import Foundation

/// What ⌘R runs: a shell command and the folder it runs in.
struct RunTask: Equatable {
    var command: String
    var directory: URL

    /// A command you set with Run Command…, remembered per project folder.
    static func savedCommand(for root: URL) -> String? {
        let saved = UserDefaults.standard.string(forKey: "runCommand:" + root.path)
        return saved?.isEmpty == false ? saved : nil
    }

    static func save(_ command: String, for root: URL) {
        UserDefaults.standard.set(command, forKey: "runCommand:" + root.path)
    }

    /// The nearest project file from the open file's folder up to the project root decides;
    /// with none, the open file itself is run by its type. Folders above the project you opened
    /// (or, with no project, above the file's own folder) are never looked at: a build file there
    /// isn't one you chose to run.
    static func detect(file: URL?, root: URL?) -> RunTask? {
        let start = (file?.deletingLastPathComponent() ?? root)?.standardizedFileURL
        let rootPath = root?.standardizedFileURL.path
        let fileInsideRoot = rootPath.map { start?.path == $0 || start?.path.hasPrefix($0 + "/") == true } ?? false
        let stop = fileInsideRoot ? rootPath : start?.path
        var folder = start
        let fm = FileManager.default
        while let dir = folder {
            func has(_ name: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }
            if has("Package.swift") { return RunTask(command: "swift run", directory: dir) }
            if has("Cargo.toml") { return RunTask(command: "cargo run", directory: dir) }
            if has("go.mod") { return RunTask(command: "go run .", directory: dir) }
            if has("package.json") { return RunTask(command: npmCommand(dir), directory: dir) }
            if has("Makefile") { return RunTask(command: "make", directory: dir) }
            if dir.path == stop || dir.path == "/" { break }
            folder = dir.deletingLastPathComponent()
        }
        guard let file else { return nil }
        let quoted = "'" + file.lastPathComponent.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let runner: String? = switch file.pathExtension.lowercased() {
        case "py": "python3 -u"
        case "js", "mjs", "cjs": "node"
        case "swift": "swift"
        case "sh": "sh"
        case "bash": "bash"
        case "zsh": "zsh"
        case "rb": "ruby"
        case "go": "go run"
        case "java": "java"
        default: nil
        }
        guard let runner else { return nil }
        return RunTask(command: runner + " " + quoted, directory: file.deletingLastPathComponent())
    }

    private static func npmCommand(_ dir: URL) -> String {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return "npm start" }
        if scripts["dev"] != nil { return "npm run dev" }
        if scripts["start"] != nil { return "npm start" }
        if scripts["test"] != nil { return "npm test" }
        return "npm start"
    }
}
