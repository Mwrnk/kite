import Foundation
import Testing
@testable import Markdown

/// Which files a Markdown image or link may name: relative paths inside the project only, so
/// previewing someone else's file never reaches the network (e.g. /net/host/… mounts on access).
@Suite struct MarkdownPathsTests {
    private let root = URL(fileURLWithPath: "/work/proj")
    private let docs = URL(fileURLWithPath: "/work/proj/docs")

    private func local(_ source: String, folder: URL? = nil) -> String? {
        MarkdownPaths.localFile(source, folder: folder ?? docs, root: root)?.path
    }

    @Test func relativePathsInsideTheProject() {
        #expect(local("img/a.png") == "/work/proj/docs/img/a.png")
        #expect(local("../assets/a.png") == "/work/proj/assets/a.png")
        #expect(local("./a.png") == "/work/proj/docs/a.png")
    }

    @Test func decodesAndDropsFragments() {
        #expect(local("my%20pic.png") == "/work/proj/docs/my pic.png")
        #expect(local("other.md#part") == "/work/proj/docs/other.md")
        #expect(local("other.md?raw=1") == "/work/proj/docs/other.md")
    }

    @Test func nothingOutsideTheProject() {
        #expect(local("../../etc/passwd") == nil)
        #expect(local("../../proj2/x.png") == nil)   // a sibling whose name starts the same
    }

    @Test func noAbsolutePathsOrURLs() {
        #expect(local("/net/host/share/x.png") == nil)
        #expect(local("/Volumes/x/a.png") == nil)
        #expect(local("~/a.png") == nil)
        #expect(local("file:///work/proj/a.png") == nil)
        #expect(local("file://host/share/a.png") == nil)
        #expect(local("smb://host/share/a.png") == nil)
        #expect(local("https://example.com/a.png") == nil)
        #expect(local("") == nil)
        #expect(local("#heading") == nil)
    }
}
