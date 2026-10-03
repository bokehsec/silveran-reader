#if os(iOS) || os(macOS)
import Foundation
import Testing

@testable import SilveranAppleKit
@testable import SilveranKit

/// BF-075: SwiftUI runs `EbookPlayerView.init` again whenever the library behind the reader
/// re-renders, and each run builds an `EbookPlayerViewModel` it then discards. The book's
/// `InkSession` is shared, so a discarded model must not take its callbacks from the reader
/// on screen.
@Suite("Reader view model and the shared ink session")
@MainActor
struct EbookPlayerInkWiringTests {
    private func bookData() -> PlayerBookData {
        let metadata = BookMetadata(
            bookID: BookID(sourceID: "test-source", uuid: UUID().uuidString),
            title: "Book",
            subtitle: nil,
            description: nil,
            language: nil,
            createdAt: nil,
            updatedAt: nil,
            publicationDate: nil,
            authors: nil,
            narrators: nil,
            creators: nil,
            series: nil,
            tags: nil,
            collections: nil,
            ebook: nil,
            audiobook: nil,
            readaloud: nil,
            status: nil,
            position: nil,
            rating: nil,
        )
        return PlayerBookData(metadata: metadata, localMediaPath: nil, category: .ebook)
    }

    @Test("A note icon tap reaches the reader on screen after the view is rebuilt")
    func discardedModelDoesNotTakeNoteTaps() {
        let data = bookData()
        let shown = EbookPlayerViewModel(bookData: data)
        shown.attachInkSession()
        // The library re-renders after a page turn: SwiftUI builds a model it never shows.
        let discarded = EbookPlayerViewModel(bookData: data)
        #expect(shown.inkSession === discarded.inkSession, "both models share the book's ink")

        shown.inkSession.onMarginNotesTapped?("OEBPS/ch1.xhtml", ["note"])

        #expect(shown.presentedMarginNote?.noteID == "note")
        #expect(discarded.presentedMarginNote == nil)
    }
}
#endif
