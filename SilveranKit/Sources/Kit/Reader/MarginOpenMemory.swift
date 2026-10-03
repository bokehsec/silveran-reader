import Foundation

/// Whether the wide margin was left open in each book, on this device only (owner decision,
/// 2026-10-03): a book annotated in the margin reopens with its margin notes showing as
/// handwriting instead of icons. Reader view state, like the sidebar choices: it is not
/// synchronized between devices and is not part of the configuration backup. Only books left
/// open are recorded; a missing or unreadable record means closed, the earlier behavior.
public struct MarginOpenMemory: Sendable {
    public var isOpen: @Sendable (BookID) -> Bool
    public var setOpen: @Sendable (BookID, Bool) -> Void

    public init(
        isOpen: @escaping @Sendable (BookID) -> Bool,
        setOpen: @escaping @Sendable (BookID, Bool) -> Void
    ) {
        self.isOpen = isOpen
        self.setOpen = setOpen
    }

    /// Remembers nothing: every book opens with the margin closed.
    public static let none = MarginOpenMemory(isOpen: { _ in false }, setOpen: { _, _ in })

    static let defaultsKey = "SilveranInkMarginOpenBooks"

    /// The record key: the book's source and its ID there, so books from different sources never share it.
    static func key(_ book: BookID) -> String { "\(book.sourceID)/\(book.uuid)" }

    /// Kept in the app's user defaults under one key: the books whose margin was left open.
    public static let userDefaults = MarginOpenMemory(
        isOpen: { book in
            let open = UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? []
            return open.contains(key(book))
        },
        setOpen: { book, open in
            var books = UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? []
            books.removeAll { $0 == key(book) }
            if open { books.append(key(book)) }
            UserDefaults.standard.set(books, forKey: defaultsKey)
        }
    )
}
