import AppKit
import CoreText
import UniformTypeIdentifiers

/// Converts supported local documents to PDF data before they enter the queue.
/// The rest of the app can therefore keep one PDF based preview and imposition path.
enum DocumentImport {
    static let supportedExtensions: Set<String> = [
        "pdf", "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp",
        "docx", "doc", "rtf", "rtfd", "txt"
    ]

    static let allowedContentTypes: [UTType] = [
        .pdf, .image, .plainText, .rtf, .rtfd,
        UTType(filenameExtension: "docx")!,
        UTType(filenameExtension: "doc")!
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func supportedURLs(from urls: [URL]) -> [URL] {
        urls.filter { $0.isFileURL && isSupported($0) }
    }

    static func pdfData(for url: URL) throws -> Data {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try Data(contentsOf: url, options: .mappedIfSafe)
        case "png", "jpg", "jpeg", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp":
            guard let image = NSImage(contentsOf: url) else {
                throw LayoutError.message(L10n.format("error.read_document", url.lastPathComponent))
            }
            return try imagePDFData(image)
        case "docx":
            return try textPDFData(from: attributedString(for: url, documentType: .officeOpenXML))
        case "doc":
            return try textPDFData(from: attributedString(for: url, documentType: .docFormat))
        case "rtf":
            return try textPDFData(from: attributedString(for: url, documentType: .rtf))
        case "rtfd":
            return try textPDFData(from: attributedString(for: url, documentType: .rtfd))
        case "txt":
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(decoding: data, as: UTF8.self)
            return try textPDFData(from: NSAttributedString(string: text))
        default:
            throw LayoutError.message(L10n.format("error.unsupported_document", url.lastPathComponent))
        }
    }

    private static func attributedString(for url: URL,
                                        documentType: NSAttributedString.DocumentType) throws -> NSAttributedString {
        do {
            return try NSAttributedString(url: url,
                                          options: [.documentType: documentType],
                                          documentAttributes: nil)
        } catch {
            throw LayoutError.message(L10n.format("error.convert_document", url.lastPathComponent))
        }
    }

    private static func imagePDFData(_ image: NSImage) throws -> Data {
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil),
              cgImage.width > 0, cgImage.height > 0 else {
            throw LayoutError.message(L10n.string("error.image_conversion"))
        }

        let pageSize = CGSize(width: 595.2756, height: 841.8898)
        let margin: CGFloat = 28.3464567
        let content = CGRect(origin: CGPoint(x: margin, y: margin),
                             size: CGSize(width: pageSize.width - margin * 2,
                                          height: pageSize.height - margin * 2))
        let scale = min(content.width / CGFloat(cgImage.width), content.height / CGFloat(cgImage.height))
        let drawSize = CGSize(width: CGFloat(cgImage.width) * scale,
                              height: CGFloat(cgImage.height) * scale)
        let drawRect = CGRect(x: content.midX - drawSize.width / 2,
                              y: content.midY - drawSize.height / 2,
                              width: drawSize.width,
                              height: drawSize.height)

        return try makePDF(pageSize: pageSize) { context in
            context.draw(cgImage, in: drawRect)
        }
    }

    private static func textPDFData(from attributedString: NSAttributedString) throws -> Data {
        let content = attributedString.length == 0 ? NSAttributedString(string: " ") : attributedString
        let pageSize = CGSize(width: 595.2756, height: 841.8898)
        let margin: CGFloat = 54
        let contentRect = CGRect(x: margin, y: margin,
                                 width: pageSize.width - margin * 2,
                                 height: pageSize.height - margin * 2)
        let framesetter = CTFramesetterCreateWithAttributedString(content as CFAttributedString)
        var location = 0
        var pages: [(CGRect, CTFrame)] = []

        while location < content.length {
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter,
                                                  CFRange(location: location, length: 0),
                                                  path, nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            guard visibleRange.length > 0 else { break }
            pages.append((contentRect, frame))
            location += visibleRange.length
        }
        if pages.isEmpty {
            let path = CGPath(rect: contentRect, transform: nil)
            pages.append((contentRect, CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)))
        }

        return try makePDF(pageSize: pageSize, pageCount: pages.count) { context, pageIndex in
            CTFrameDraw(pages[pageIndex].1, context)
        }
    }

    private static func makePDF(pageSize: CGSize,
                                pageCount: Int = 1,
                                draw: (CGContext) -> Void) throws -> Data {
        try makePDF(pageSize: pageSize, pageCount: pageCount) { context, _ in draw(context) }
    }

    private static func makePDF(pageSize: CGSize,
                                pageCount: Int,
                                draw: (CGContext, Int) -> Void) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw LayoutError.message(L10n.string("error.create_page"))
        }
        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            draw(context, pageIndex)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
