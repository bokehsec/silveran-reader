#if os(iOS) || os(macOS)
import SilveranKit
import SwiftUI
import UniformTypeIdentifiers

/// Every highlight, bookmark, typed note and handwritten note across the library (plan P5.1),
/// including books that are no longer in the library. Search, filter, jump to the passage and
/// export a readable summary.
struct AnnotationsBrowserView: View {
    @Environment(MediaViewModel.self) private var mediaViewModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var books: [AnnotationBookSummary] = []
    @State private var loading = true
    @State private var query = ""
    @State private var kinds = Set(AnnotationEntry.Kind.allCases)
    @State private var colors: Set<HighlightColor>? = nil
    @State private var export: NotesExportDocument?
    @State private var exportName = ""
    @State private var preparingPDF = false
    @State private var pdfTask: Task<Void, Never>?
    @State private var pdfPreview: PreparedPDF?
    @State private var visualPreview: PreparedVisual?
    @State private var visualToSave: PreparedVisual?
    @State private var pdfToSave: PreparedPDF?
    @State private var classificationEntry: AnnotationEntry?
    @State private var repairBook: AnnotationBookSummary?
    @State private var placementCounts: [BookID: Int] = [:]
    @State private var chapter: ChapterChoice?

    private struct ChapterChoice: Hashable {
        let bookID: BookID
        let href: String
        let title: String
    }
    private struct PreparedPDF: Identifiable {
        let id = UUID()
        let data: Data
        let filename: String
    }
    private struct PreparedVisual: Identifiable {
        let id = UUID()
        let data: Data
        let type: UTType
        let filename: String
        let quote: String?
    }
    @State private var message: String?
    @State private var settings = SettingsViewModel()
    @State private var keptCount = 0

    var body: some View {
        content
            .navigationTitle("Annotations")
            .task { await reload() }
            .refreshable { await reload() }
            .onDisappear { pdfTask?.cancel() }
            .sheet(item: $classificationEntry, onDismiss: { Task { await reload() } }) { entry in
                InkClassificationView(entry: entry)
            }
            .sheet(item: $repairBook, onDismiss: { Task { await reload() } }) { book in
                LibraryAnnotationRepairView(
                    book: book,
                    title: title(for: book.bookID),
                    category: readableCategory(for: book.bookID) ?? .ebook
                ) { count in
                    placementCounts[book.bookID] = count
                }
            }
            .sheet(item: $visualPreview, onDismiss: savePreparedVisual) { prepared in
                NavigationStack {
                    AnnotationVisualPreview(
                        data: prepared.data,
                        type: prepared.type,
                        quote: prepared.quote
                    )
                    .navigationTitle("Handwriting Export")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { visualPreview = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save \(prepared.type == .png ? "PNG" : "SVG")") {
                                visualToSave = prepared
                                visualPreview = nil
                            }
                        }
                    }
                }
            }
            .sheet(item: $pdfPreview, onDismiss: savePreparedPDF) { prepared in
                NavigationStack {
                    AnnotationPDFPreview(data: prepared.data)
                        .navigationTitle("Notes PDF")
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { pdfPreview = nil }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save PDF") {
                                    pdfToSave = prepared
                                    pdfPreview = nil
                                }
                            }
                        }
                }
            }
            .fileExporter(
                isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                document: export,
                contentType: export?.contentType ?? .plainText,
                defaultFilename: exportName
            ) { result in
                if case .failure(let error) = result { message = error.localizedDescription }
                export = nil
            }
            .alert(
                "Annotations",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
            ) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
    }

    @ViewBuilder private var content: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if books.isEmpty && keptCount == 0 {
            ContentUnavailableView(
                "No Annotations Yet",
                systemImage: "highlighter",
                description: Text(
                    "Highlights, bookmarks and handwriting from every book appear here."
                )
            )
        } else {
            let visible = filteredBooks
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    TextField("Search books, quotes and notes", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search annotations")
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }.accessibilityLabel("Clear search")
                    }
                    filterMenu
                }
                .padding(.horizontal).padding(.vertical, 10)
                if preparingPDF {
                    HStack {
                        ProgressView("Preparing export…")
                        Spacer()
                        Button("Cancel") { pdfTask?.cancel() }
                            .accessibilityLabel("Cancel export preparation")
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                if hasFilters {
                    HStack {
                        Text(filterDescription)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Filters") { resetFilters() }
                    }.padding(.horizontal).padding(.vertical, 8)
                }
                List {
                    if keptCount > 0 {
                        Section {
                            NavigationLink {
                                KeptVersionsView(title: title(for:)) { await reload() }
                            } label: {
                                Label(
                                    "\(keptCount) version(s) kept by iCloud sync",
                                    systemImage: "clock.arrow.circlepath"
                                )
                            }
                        } footer: {
                            Text(
                                "When an annotation was changed on two devices, the latest change was used and the other kept here."
                            )
                        }
                    }
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label(
                                "No Matching Annotations",
                                systemImage: "line.3.horizontal.decrease.circle"
                            )
                        } description: {
                            Text("Try another search or reset your filters.")
                        } actions: {
                            Button("Show All Annotations") {
                                query = ""
                                resetFilters()
                            }
                        }
                    }
                    ForEach(visible, id: \.book.id) { item in
                        Section {
                            ForEach(item.entries) { entry in
                                Button {
                                    show(entry)
                                } label: {
                                    AnnotationRow(entry: entry, colorHex: hex(for:))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Show this annotation in its book")
                                .contextMenu {
                                    if !entry.strokes.isEmpty {
                                        Button("Share Handwriting as SVG") {
                                            exportVisual(entry, png: false)
                                        }
                                        .disabled(preparingPDF)
                                        Button("Share Handwriting as PNG Image") {
                                            exportVisual(entry, png: true)
                                        }
                                        .disabled(preparingPDF)
                                    }
                                    if entry.kind == .inkMark {
                                        Button(
                                            "Correct Handwriting Type",
                                            systemImage: "pencil.and.outline"
                                        ) {
                                            classificationEntry = entry
                                        }
                                    }
                                    Button("Show in Book") { show(entry) }
                                        .disabled(metadata(for: entry.bookID) == nil)
                                }
                            }
                        } header: {
                            header(item.book)
                        }
                    }
                }
            }
        }
    }

    private var hasFilters: Bool {
        kinds != Set(AnnotationEntry.Kind.allCases) || colors != nil || chapter != nil
    }

    private var filterDescription: String {
        var parts: [String] = []
        if let colors {
            parts.append(
                "Highlight color: "
                    + colors.map { $0.rawValue.capitalized }.sorted().joined(separator: ", ")
            )
        }
        if let chapter { parts.append("Chapter: \(chapter.title)") }
        if kinds != Set(AnnotationEntry.Kind.allCases) {
            parts.append("\(kinds.count) annotation types selected")
        }
        return parts.joined(separator: " · ")
    }

    private func resetFilters() {
        kinds = Set(AnnotationEntry.Kind.allCases)
        colors = nil
        chapter = nil
    }

    private var filteredBooks: [(book: AnnotationBookSummary, entries: [AnnotationEntry])] {
        books.compactMap { book in
            if let chapter, chapter.bookID != book.bookID { return nil }
            let entries = AnnotationLibrary.filter(
                book.entries,
                query: query,
                kinds: kinds,
                colors: colors,
                chapters: chapter.map { Set([$0.href]) },
                bookTitle: title(for: book.bookID)
            )
            return entries.isEmpty && !(book.needsRecovery && query.isEmpty && !hasFilters)
                ? nil : (book, entries)
        }
    }

    private func header(_ book: AnnotationBookSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(for: book.bookID)).font(.headline).textCase(nil)
                if metadata(for: book.bookID) == nil {
                    Text("Not in your library — notes are kept")
                        .font(.caption).foregroundStyle(.secondary).textCase(nil)
                }
                if let count = placementCounts[book.bookID], count > 0 {
                    Label(
                        "Last check: \(count) annotation(s) need placement review",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange).textCase(nil)
                }
                if book.needsRecovery {
                    Label(
                        "Some annotations need recovery; open the book to fix them",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption).foregroundStyle(.orange).textCase(nil)
                }
            }
            Spacer()
            // Repair is not an export; it gets its own control so it can be found (and named
            // correctly by VoiceOver) instead of hiding in the share menu.
            Menu {
                Button("Check & Repair Placement", systemImage: "wrench.and.screwdriver") {
                    repairBook = book
                }
                .disabled(readableCategory(for: book.bookID) == nil)
                if readableCategory(for: book.bookID) == nil {
                    Text("Download the ebook or read-along edition to check placement.")
                }
            } label: {
                Label("Check & Repair", systemImage: "wrench.and.screwdriver")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Check and repair placement for \(title(for: book.bookID))")
            Menu {
                Button("PDF (with handwriting)") { exportPDF(book) }
                    .disabled(preparingPDF)
                Button("Web Page (with handwriting)") { exportNotes(book, asHTML: true) }
                    .disabled(preparingPDF)
                Button("Markdown Text") { exportNotes(book, asHTML: false) }
                    .disabled(preparingPDF)
                Text("Exports all notes in this book. Use a backup to keep editable data.")
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Export notes for \(title(for: book.bookID))")
        }
        .textCase(nil)
    }

    private var filterMenu: some View {
        Menu {
            Section("Show") {
                ForEach(AnnotationEntry.Kind.allCases, id: \.self) { kind in
                    Toggle(
                        label(kind),
                        isOn: Binding(
                            get: { kinds.contains(kind) },
                            set: { on in
                                if on { kinds.insert(kind) } else { kinds.remove(kind) }
                            }
                        )
                    )
                }
            }
            Section("Chapter") {
                Button("Any Chapter") { chapter = nil }
                ForEach(books) { book in
                    Menu(title(for: book.bookID)) {
                        ForEach(AnnotationLibrary.chapters(book.entries), id: \.href) { group in
                            let choice = ChapterChoice(
                                bookID: book.bookID,
                                href: group.href,
                                title: group.title
                            )
                            Button {
                                chapter = choice
                            } label: {
                                if chapter == choice {
                                    Label(group.title, systemImage: "checkmark")
                                } else {
                                    Text(group.title)
                                }
                            }
                        }
                    }
                }
            }
            if hasFilters {
                Button("Reset Filters") { resetFilters() }
            }
            Section("Highlight Color") {
                Button("Any Color") { colors = nil }
                ForEach(HighlightColor.allCases, id: \.self) { color in
                    Button {
                        colors = [color]
                    } label: {
                        if colors == [color] {
                            Label(color.rawValue.capitalized, systemImage: "checkmark")
                        } else {
                            Text(color.rawValue.capitalized)
                        }
                    }
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: hasFilters
                    ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
    }

    // MARK: Actions

    private func reload() async {
        if AppAnnotationSync.isAvailable {
            keptCount = await AppAnnotationSync.engine.recoveredVersions().count
        }
        // Library books by title; books no longer in the library last.
        books = await AnnotationLibrary.load().sorted { lhs, rhs in
            let left = metadata(for: lhs.bookID)?.title
            let right = metadata(for: rhs.bookID)?.title
            switch (left, right) {
                case (nil, nil): return false
                case (nil, _): return false
                case (_, nil): return true
                case (let l?, let r?): return l.localizedStandardCompare(r) == .orderedAscending
            }
        }
        loading = false
    }

    private func readableCategory(for bookID: BookID) -> LocalMediaCategory? {
        if mediaViewModel.localMediaPath(for: bookID, category: .ebook) != nil { return .ebook }
        if mediaViewModel.localMediaPath(for: bookID, category: .synced) != nil { return .synced }
        return nil
    }

    private func show(_ entry: AnnotationEntry) {
        guard let book = metadata(for: entry.bookID) else {
            message =
                "This book isn't in your library. Its annotations are kept and will reconnect if the book is added again."
            return
        }
        guard let category = readableCategory(for: book.id) else {
            message = "Download the ebook or read-along edition to see this annotation in place."
            return
        }
        ReaderOpenRequest.shared.request(book.id, at: entry.locator)
        let data = mediaViewModel.makePlayerBookData(for: book, category: category)
        #if os(iOS)
        PlayerPresenter.shared.present(data)
        #else
        openWindow(id: "EbookPlayer", value: data)
        #endif
    }

    private func exportPDF(_ book: AnnotationBookSummary) {
        guard !preparingPDF else { return }
        preparingPDF = true
        let title = title(for: book.bookID)
        let author = metadata(for: book.bookID)?.authors?.first?.name
        pdfTask = Task {
            do {
                let order = try await exportChapterOrder(book.bookID)
                let generator = Task.detached(priority: .userInitiated) {
                    try AnnotationPDFExport.data(
                        title: title,
                        author: author,
                        entries: book.entries,
                        chapterOrder: order
                    )
                }
                let data = try await withTaskCancellationHandler {
                    try await generator.value
                } onCancel: {
                    generator.cancel()
                }
                try Task.checkCancellation()
                pdfPreview = PreparedPDF(data: data, filename: "\(title) — Notes.pdf")
            } catch {
                if !Task.isCancelled {
                    message = "The PDF couldn't be prepared. \(error.localizedDescription)"
                }
            }
            preparingPDF = false
            pdfTask = nil
        }
    }

    // Present the system picker only after the preview sheet has finished dismissing.
    private func savePreparedPDF() {
        guard let prepared = pdfToSave else { return }
        pdfToSave = nil
        exportName = prepared.filename
        export = NotesExportDocument(data: prepared.data, contentType: .pdf)
    }

    private func exportVisual(_ entry: AnnotationEntry, png: Bool) {
        guard !preparingPDF else { return }
        preparingPDF = true
        let title = title(for: entry.bookID)
        let author = metadata(for: entry.bookID)?.authors?.first?.name
        pdfTask = Task {
            do {
                let generator = Task.detached(priority: .userInitiated) {
                    if png {
                        return try AnnotationImageExport.png(
                            title: title,
                            author: author,
                            entry: entry
                        )
                    }
                    return Data(
                        try InkVisualExport.svg(title: title, author: author, entry: entry).utf8
                    )
                }
                let data = try await withTaskCancellationHandler {
                    try await generator.value
                } onCancel: {
                    generator.cancel()
                }
                try Task.checkCancellation()
                visualPreview = PreparedVisual(
                    data: data,
                    type: png ? .png : .svg,
                    filename: "\(title) — Handwriting.\(png ? "png" : "svg")",
                    quote: entry.quote
                )
            } catch {
                if !Task.isCancelled {
                    message =
                        "The handwriting export couldn't be prepared. \(error.localizedDescription)"
                }
            }
            preparingPDF = false
            pdfTask = nil
        }
    }

    private func savePreparedVisual() {
        guard let prepared = visualToSave else { return }
        visualToSave = nil
        exportName = prepared.filename
        export = NotesExportDocument(data: prepared.data, contentType: prepared.type)
    }

    /// The detached inspector reads spine metadata without changing position or displaying pages.
    private func exportChapterOrder(_ bookID: BookID) async throws -> [String] {
        guard let category = readableCategory(for: bookID) else { return [] }
        let inspector = AnnotationBookInspector()
        defer { inspector.close() }
        let chapters = try await inspector.open(bookID: bookID, category: category)
        try Task.checkCancellation()
        return chapters.map(\.href)
    }

    private func exportNotes(_ book: AnnotationBookSummary, asHTML: Bool) {
        guard !preparingPDF else { return }
        preparingPDF = true
        let title = title(for: book.bookID)
        let author = metadata(for: book.bookID)?.authors?.first?.name
        pdfTask = Task {
            do {
                let order = try await exportChapterOrder(book.bookID)
                let generator = Task.detached(priority: .userInitiated) {
                    asHTML
                        ? AnnotationLibrary.html(
                            title: title,
                            author: author,
                            entries: book.entries,
                            chapterOrder: order
                        )
                        : AnnotationLibrary.markdown(
                            title: title,
                            author: author,
                            entries: book.entries,
                            chapterOrder: order
                        )
                }
                let text = await withTaskCancellationHandler {
                    await generator.value
                } onCancel: {
                    generator.cancel()
                }
                try Task.checkCancellation()
                exportName = "\(title) — Notes.\(asHTML ? "html" : "md")"
                export = NotesExportDocument(text: text, contentType: asHTML ? .html : .markdown)
            } catch {
                if !Task.isCancelled {
                    message = "The notes export couldn't be prepared. \(error.localizedDescription)"
                }
            }
            preparingPDF = false
            pdfTask = nil
        }
    }

    // MARK: Helpers

    private func metadata(for bookID: BookID) -> BookMetadata? {
        mediaViewModel.library.bookMetaData.first { $0.id == bookID }
    }

    private func title(for bookID: BookID) -> String {
        metadata(for: bookID)?.title ?? "Unknown book"
    }

    private func hex(for color: HighlightColor) -> Color {
        Color(hex: settings.hexColor(for: color)) ?? color.color
    }

    private func label(_ kind: AnnotationEntry.Kind) -> String {
        switch kind {
            case .highlight: "Highlights"
            case .bookmark: "Bookmarks"
            case .handwriting: "Handwritten Notes"
            case .inkMark: "Handwritten Marks"
        }
    }
}

/// Versions that iCloud sync replaced or deleted, with a way to bring one back.
private struct KeptVersionsView: View {
    let title: (BookID) -> String
    let changed: () async -> Void
    @State private var versions: [AnnotationRecoveredVersion] = []
    @State private var restoring: AnnotationRecoveredVersion?
    private struct PreparedVisual: Identifiable {
        let id = UUID()
        let data: Data
        let type: UTType
        let filename: String
        let quote: String?
    }
    @State private var message: String?

    var body: some View {
        List(versions, id: \.self) { version in
            VStack(alignment: .leading, spacing: 4) {
                Text(title(version.record.bookID)).font(.caption).foregroundStyle(.secondary)
                Text(summary(version.record)).lineLimit(3)
                Text(
                    "\(version.reason) · \(version.savedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.tertiary)
                if version.record.payload != nil {
                    Button("Use This Version") { restoring = version }
                        .font(.callout)
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if versions.isEmpty {
                ContentUnavailableView("Nothing Kept", systemImage: "clock.arrow.circlepath")
            }
        }
        .navigationTitle("Kept Versions")
        .task { versions = await AppAnnotationSync.engine.recoveredVersions() }
        .confirmationDialog(
            "Use this version?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible
        ) {
            Button("Use This Version") {
                guard let version = restoring else { return }
                Task {
                    let applied = await AppAnnotationSync.engine.restore(version)
                    message =
                        applied
                        ? "Restored. It will appear on your other devices shortly."
                        : "This version couldn't be restored because the book's annotations need recovery."
                    await changed()
                }
            }
        } message: {
            Text(
                "It replaces the current version on all your devices. The current one is kept here."
            )
        }
        .alert(
            "Kept Versions",
            isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })
        ) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func summary(_ record: AnnotationSyncRecord) -> String {
        guard let payload = record.payload else { return "Deleted annotation" }
        switch record.kind {
            case .highlight:
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                guard let highlight = try? decoder.decode(Highlight.self, from: payload) else {
                    return "Highlight"
                }
                let note = highlight.note.map { " — \($0)" } ?? ""
                return highlight.isBookmark
                    ? "Bookmark\(note)" : "“\(highlight.displayText)”\(note)"
            case .inkNote: return "Handwritten note"
            case .inkMark: return "Handwritten mark"
        }
    }
}

private struct AnnotationRow: View {
    let entry: AnnotationEntry
    let colorHex: (HighlightColor) -> Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 4) {
                if let quote = entry.quote {
                    Text(quote).lineLimit(3)
                } else {
                    Text(placeholder).foregroundStyle(.secondary)
                }
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
                Text(caption).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leading: some View {
        switch entry.kind {
            case .highlight:
                RoundedRectangle(cornerRadius: 3)
                    .fill(entry.color.map(colorHex) ?? .yellow)
                    .frame(width: 6)
                    .frame(minHeight: 36)
                    .accessibilityHidden(true)
            case .bookmark:
                Image(systemName: "bookmark.fill").foregroundStyle(.red).frame(width: 20)
            case .handwriting, .inkMark:
                StrokeThumbnail(strokes: entry.strokes)
                    .frame(width: 56, height: 40)
                    .accessibilityHidden(true)
        }
    }

    private var placeholder: String {
        switch entry.kind {
            case .bookmark: "Bookmark"
            case .handwriting: "Handwritten note"
            case .inkMark: "Handwritten mark"
            case .highlight: "Highlight"
        }
    }

    private var caption: String {
        let date = entry.createdAt.formatted(date: .abbreviated, time: .omitted)
        if let chapter = entry.chapterTitle, !chapter.isEmpty { return "\(chapter) · \(date)" }
        return date
    }
}

/// Draws handwritten strokes scaled to fit, for recognition at a glance.
struct StrokeThumbnail: View {
    let strokes: [InkStroke]

    var body: some View {
        Canvas { context, size in
            let shapes = strokes.compactMap { stroke -> (InkStroke, [[Double]])? in
                let points =
                    stroke.tool == .highlighter
                    ? stroke.points.map { Array($0.prefix(2)) } : stroke.points
                let outline = InkStrokeOutline.outline(points: points, size: stroke.width)
                return outline.isEmpty ? nil : (stroke, outline)
            }
            let all = shapes.flatMap { $0.1 }
            guard let minX = all.map({ $0[0] }).min(), let maxX = all.map({ $0[0] }).max(),
                let minY = all.map({ $0[1] }).min(), let maxY = all.map({ $0[1] }).max()
            else { return }
            let width = max(maxX - minX, 1)
            let height = max(maxY - minY, 1)
            let scale = max(0, min((size.width - 4) / width, (size.height - 4) / height))
            let offsetX = (size.width - width * scale) / 2
            let offsetY = (size.height - height * scale) / 2
            for (stroke, outline) in shapes {
                var path = Path()
                let highlighterLine = stroke.tool == .highlighter && stroke.points.count > 1
                let points = highlighterLine ? stroke.points : outline
                for (index, point) in points.enumerated() where point.count >= 2 {
                    let location = CGPoint(
                        x: offsetX + (point[0] - minX) * scale,
                        y: offsetY + (point[1] - minY) * scale
                    )
                    if index == 0 { path.move(to: location) } else { path.addLine(to: location) }
                }
                let color = (Color(hex: stroke.color) ?? .primary).opacity(
                    stroke.tool == .highlighter ? 0.35 : 1
                )
                if highlighterLine {
                    context.stroke(
                        path,
                        with: .color(color),
                        style: StrokeStyle(
                            lineWidth: stroke.width * scale,
                            lineCap: .butt,
                            lineJoin: .round
                        )
                    )
                } else {
                    path.closeSubpath()
                    context.fill(path, with: .color(color))
                }
            }
        }
        // Stored colors are canonical for a light page, including ink captured in dark mode.
        .background(Color.white, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.2), lineWidth: 1))
    }
}

struct NotesExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdown, .html, .plainText, .pdf, .svg, .png] }
    let data: Data
    let contentType: UTType
    init(text: String, contentType: UTType) {
        self.init(data: Data(text.utf8), contentType: contentType)
    }
    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
        contentType = configuration.contentType
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension UTType {
    static var markdown: UTType { UTType("net.daringfireball.markdown") ?? .plainText }
}
#endif
