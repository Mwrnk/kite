import Foundation

/// Which local files a Markdown image or link may name.
///
/// Only relative paths that stay inside `root` (the project, or the file's folder) count. Absolute
/// paths and URLs never do: previewing a file someone else wrote must not reach the network, and on
/// macOS just looking at a path like /net/host/… connects to that host to mount it.
public enum MarkdownPaths {
    /// The file `source` names, resolved against `folder`, or nil if it isn't a relative path inside
    /// `root`. Works on the path text only; nothing on disk is touched.
    public static func localFile(_ source: String, folder: URL, root: URL) -> URL? {
        var path = source
        if let cut = path.firstIndex(where: { $0 == "#" || $0 == "?" }) { path = String(path[..<cut]) }
        guard !path.isEmpty else { return nil }
        // Anything with a scheme (file:, smb:, https:, data:, …) is not a relative path.
        if let url = URL(string: path), url.scheme != nil { return nil }
        path = path.removingPercentEncoding ?? path
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { return nil }

        let file = folder.appendingPathComponent(path).standardizedFileURL
        let inside = root.standardizedFileURL.path
        let prefix = inside.hasSuffix("/") ? inside : inside + "/"
        return file.path.hasPrefix(prefix) ? file : nil
    }
}
