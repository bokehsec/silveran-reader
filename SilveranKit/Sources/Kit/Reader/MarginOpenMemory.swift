import Foundation

/// Obsolete local view-state adapter retained for source compatibility and rollback. ADR 016
/// retires expansion: InkSession never reads or writes this record. It stays excluded from
/// configuration sync and backup; existing preferences are left untouched.
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
