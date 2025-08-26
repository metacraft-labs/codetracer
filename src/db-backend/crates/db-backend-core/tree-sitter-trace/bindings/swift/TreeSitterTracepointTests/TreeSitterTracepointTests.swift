import XCTest
import SwiftTreeSitter
import TreeSitterTracepoint

final class TreeSitterTracepointTests: XCTestCase {
    func testCanLoadGrammar() throws {
        let parser = Parser()
        let language = Language(language: tree_sitter_tracepoint())
        XCTAssertNoThrow(try parser.setLanguage(language),
                         "Error loading Tracepoint grammar")
    }
}
