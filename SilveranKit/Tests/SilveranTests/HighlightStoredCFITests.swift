import Foundation
import Testing

@testable import SilveranKit

/// BF-048: the reader's repair sheet must find the saved CFI wherever the renderer finds it.
@Suite("Highlight stored CFI lookup")
struct HighlightStoredCFITests {
    func highlight(partialCfi: String?, fragments: [String]?) -> Highlight {
        Highlight(
            bookID: BookID(sourceID: "fixture", uuid: "stored-cfi"),
            locator: BookLocator(
                href: "OEBPS/ch10.xhtml",
                type: "application/xhtml+xml",
                title: "The Ledger",
                locations: BookLocator.Locations(
                    fragments: fragments,
                    progression: nil,
                    position: nil,
                    totalProgression: nil,
                    cssSelector: nil,
                    partialCfi: partialCfi,
                    domRange: nil
                ),
                text: nil
            ),
            text: "Élodie keeps the ledger beside the window.",
            color: .yellow
        )
    }

    @Test func prefersPartialCFI() {
        let value = highlight(partialCfi: "epubcfi(/6/4!/4/2/1:0)", fragments: ["epubcfi(/6/8!/4)"])
        #expect(value.storedCFI == "epubcfi(/6/4!/4/2/1:0)")
    }

    @Test func fallsBackToEPUBCFIFragment() {
        // Readium-style locators keep the CFI only in fragments; the repair list dropped these.
        let value = highlight(partialCfi: nil, fragments: ["chapter-anchor", "epubcfi(/6/4!/4/2/1:0)"])
        #expect(value.storedCFI == "epubcfi(/6/4!/4/2/1:0)")
    }

    @Test func emptyPartialCFIFallsBack() {
        let value = highlight(partialCfi: "", fragments: ["epubcfi(/6/4!/4/2/1:0)"])
        #expect(value.storedCFI == "epubcfi(/6/4!/4/2/1:0)")
    }

    @Test func noCFIIsNil() {
        #expect(highlight(partialCfi: nil, fragments: ["chapter-anchor"]).storedCFI == nil)
        #expect(highlight(partialCfi: nil, fragments: nil).storedCFI == nil)
    }
}
