#if os(iOS) || os(macOS)
import SwiftUI

/// Library-wide placement review; quotations preview each proposed target before confirmation.
struct LibraryAnnotationRepairView: View {
    let book: AnnotationBookSummary
    let title: String
    let category: LocalMediaCategory
    let onReviewed: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: AnnotationPlacementReview?
    @State private var inspector = AnnotationBookInspector()
    @State private var issues: [AnnotationPlacementIssue] = []
    @State private var checking = true
    @State private var checked = 0
    @State private var total = 0
    @State private var errorMessage: String?
    @State private var saving: String?
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            Group {
                if checking {
                    VStack(spacing: 16) {
                        ProgressView(
                            total > 0
                                ? "Checking chapters \(checked) of \(total)…" : "Preparing book…"
                        )
                        Text("Your reading position and annotations stay unchanged while checking.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(
                                .center
                            )
                    }.padding()
                } else if issues.isEmpty && errorMessage == nil {
                    ContentUnavailableView(
                        "All Annotations Are Placed",
                        systemImage: "checkmark.circle",
                        description: Text("Checked every annotated chapter in \(title).")
                    )
                } else {
                    List {
                        Section {
                            Text(
                                "Review each passage before attaching. Annotations with no suggested place stay kept for later."
                            )
                            .font(.subheadline).foregroundStyle(.secondary)
                        }
                        ForEach(issues) { issue in
                            Section {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(
                                        issue.kind == "note"
                                            ? "Handwritten note"
                                            : issue.kind == "mark"
                                                ? "Ink mark" : "Highlight or bookmark"
                                    )
                                    .font(.headline)
                                    if issue.verificationRequired == true {
                                        Text(
                                            "This older annotation has no verified edition. Confirm its passage to preserve verified placement for future editions."
                                        )
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    if let original = book.entries.first(where: {
                                        $0.id == issue.id || $0.id.hasSuffix(issue.id)
                                    }) {
                                        if !original.strokes.isEmpty {
                                            StrokeThumbnail(strokes: original.strokes)
                                                .frame(maxWidth: .infinity).frame(height: 90)
                                                .accessibilityLabel("Original handwriting")
                                        }
                                        if let quote = original.quote, !quote.isEmpty {
                                            Text("Original: \(quote)").font(.subheadline)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let note = original.note, !note.isEmpty {
                                            Text(note).font(.subheadline)
                                        }
                                    }
                                    if let excerpt = issue.excerpt {
                                        Text("Suggested passage").font(.caption).foregroundStyle(
                                            .secondary
                                        )
                                        (Text(excerpt.before) + Text(excerpt.match).bold()
                                            + Text(excerpt.after))
                                            .textSelection(.enabled)
                                        if issue.candidates > 1 {
                                            Label(
                                                "This passage occurs \(issue.candidates) times. Verify the surrounding words.",
                                                systemImage: "exclamationmark.triangle"
                                            )
                                            .font(.subheadline).foregroundStyle(.orange)
                                        }
                                        Button(
                                            issue.verificationRequired == true
                                                ? "Confirm This Passage" : "Attach to This Passage"
                                        ) {
                                            Task { await accept(issue) }
                                        }
                                        .disabled(saving != nil)
                                    } else {
                                        Text(
                                            issue.missingChapter == true
                                                ? "This chapter isn't in the downloaded edition. The annotation is kept."
                                                : "No reliable suggestion found. The annotation is kept; open the book to choose a passage manually."
                                        )
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    if saving == issue.id { ProgressView("Saving repair…") }
                                }.padding(.vertical, 4)
                            } header: {
                                Text(issue.href.removingPercentEncoding ?? issue.href)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Check & Repair")
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    VStack(spacing: 8) {
                        Text(errorMessage).font(.subheadline).foregroundStyle(.red)
                        HStack {
                            Button("Check Again") { generation += 1 }
                                .disabled(saving != nil)
                            if review?.pendingRepairID != nil {
                                Button("Retry Save") { Task { await retrySave() } }
                                    .disabled(saving != nil)
                            }
                        }
                    }.padding().background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(checking ? "Cancel" : "Done") { dismiss() }
                        .disabled(saving != nil)
                }
            }
            .task(id: generation) { await check() }
            .onDisappear {
                inspector.close()
                review?.close()
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 520)
        #endif
    }

    private func check() async {
        checking = true
        checked = 0
        total = 0
        errorMessage = nil
        issues = []
        let owner = review ?? AnnotationPlacementReview(bookID: book.bookID, category: category)
        review = owner
        do {
            try await owner.prepare()
            let chapters = try await inspector.open(bookID: book.bookID, category: category)
            let order = Dictionary(uniqueKeysWithValues: chapters.map { ($0.href, $0.index) })
            let hrefs = owner.hrefs.sorted {
                (order[$0] ?? Int.max, $0) < (order[$1] ?? Int.max, $1)
            }
            total = hrefs.count
            var found: [AnnotationPlacementIssue] = []
            for href in hrefs {
                try Task.checkCancellation()
                let answer = try await inspector.inspect(
                    href: href,
                    ink: owner.ink.sections[href] ?? SectionInk(),
                    highlights: owner.highlights.filter { $0.locator.href == href }
                )
                found += answer.missing ? owner.missingChapter(href) : answer.items
                checked += 1
            }
            try Task.checkCancellation()
            issues = found
            onReviewed(found.count)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        inspector.close()
        checking = false
    }

    private func accept(_ issue: AnnotationPlacementIssue) async {
        guard let review else { return }
        saving = issue.id
        defer { saving = nil }
        do {
            try await review.accept(issue)
            issues.removeAll { $0.id == issue.id }
            errorMessage = nil
            onReviewed(issues.count)
        } catch { errorMessage = error.localizedDescription }
    }

    private func retrySave() async {
        guard let review, let id = review.pendingRepairID else { return }
        saving = id
        defer { saving = nil }
        if await review.retrySave() {
            issues.removeAll { $0.id == id }
            errorMessage = nil
            onReviewed(issues.count)
        }
    }
}
#endif
