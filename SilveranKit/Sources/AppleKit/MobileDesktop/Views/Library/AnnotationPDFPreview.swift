#if os(iOS) || os(macOS)
import PDFKit
import SwiftUI

/// Native, selectable/zoomable preview of the exact bytes that will be saved.
struct AnnotationPDFPreview: View {
    let data: Data

    var body: some View {
        PDFPreviewSurface(data: data)
            .accessibilityLabel("Annotation PDF preview")
            #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
            #endif
    }
}

#if os(iOS)
private struct PDFPreviewSurface: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { makePDFView(data) }
    func updateUIView(_ view: PDFView, context: Context) {}
}
#else
private struct PDFPreviewSurface: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> PDFView { makePDFView(data) }
    func updateNSView(_ view: PDFView, context: Context) {}
}
#endif

@MainActor
private func makePDFView(_ data: Data) -> PDFView {
    let view = PDFView()
    view.document = PDFDocument(data: data)
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.autoScales = true
    return view
}
#endif
