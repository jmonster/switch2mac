import Foundation

@main enum OutputSetupTests {
    static func main() {
        let paths = OutputSetupPath.allCases
        precondition(Set(paths.map(\.id)).count == 3)
        for path in paths {
            precondition(!path.title.isEmpty && !path.detail.isEmpty)
            precondition(path.guideURL.isFileURL)
            precondition(path.guideURL.path.hasSuffix("/Documentation/" + path.guidePath))
            precondition(FileManager.default.fileExists(atPath: path.guidePath), "Setup link has no checked-in guide")
        }
        // Keep each integration routed to its own maintained guide.
        precondition(OutputSetupPath.browser.guidePath == "browser/README.md")
        precondition(OutputSetupPath.retroarch.guidePath == "docs/retroarch-integration.md")
        precondition(OutputSetupPath.sdl.guidePath == "sdl/README.md")
        print("PASS output setup routes and checked-in instruction targets")
    }
}
