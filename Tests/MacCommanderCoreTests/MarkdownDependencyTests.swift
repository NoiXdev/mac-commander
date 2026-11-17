import Testing
import Markdown

@Test func parsesGitHubTable() {
    let document = Document(parsing: "| a | b |\n|---|:-:|\n| 1 | 2 |")
    let table = document.children.compactMap { $0 as? Table }.first
    #expect(table != nil)
    #expect(table?.columnAlignments == [nil, .center])
}
