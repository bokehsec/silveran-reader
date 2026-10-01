#if os(iOS) || os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct AnnotationVisualPreview: View {
    let data: Data
    let type: UTType
    let quote: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                type == .png
                    ? "Flattened PNG image. Keep a backup for editable handwriting."
                    : "Vector SVG image. Keep a backup for editable handwriting."
            )
            .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            if let quote { Text("Near “\(quote)”").font(.subheadline).padding(.horizontal) }
            if type == .svg {
                SVGPreviewSurface(data: data).accessibilityLabel(
                    "Vector handwriting export preview"
                )
            } else {
                ScrollView(.vertical) {
                    #if os(iOS)
                    if let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                            .accessibilityLabel("Handwriting image with quotation and book details")
                    }
                    #else
                    if let image = NSImage(data: data) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity)
                            .accessibilityLabel("Handwriting image with quotation and book details")
                    }
                    #endif
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 580, minHeight: 640)
        #endif
    }
}

#if os(iOS)
struct SVGPreviewSurface: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> WKWebView { makeSVGPreview(data) }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
struct SVGPreviewSurface: NSViewRepresentable {
    let data: Data
    func makeNSView(context: Context) -> WKWebView { makeSVGPreview(data) }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

@MainActor
private func makeSVGPreview(_ data: Data) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let view = WKWebView(frame: .zero, configuration: configuration)
    #if os(macOS)
    view.allowsMagnification = true
    #endif
    let svg = String(decoding: data, as: UTF8.self)
    view.loadHTMLString(
        "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0;background:white}body>svg{max-width:100%;height:auto}</style></head><body>\(svg)</body></html>",
        baseURL: nil
    )
    return view
}
#endif
