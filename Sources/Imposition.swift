import AppKit
import PDFKit

struct PrintSettings {
    var pagesPerSheet = 3
    var paperIndex = 0
    var landscape = false
    var arrangement = 1 // 0 automatic, 1 one column (default), 2 one row
    var margin: CGFloat = 28.3464567
    var showsBorders = false
    var pageIndices: [Int] = []

    var paperName: String { ["A4", "A3", "Letter"][paperIndex] }
    var portraitSize: CGSize {
        [CGSize(width: 595.2756, height: 841.8898),
         CGSize(width: 841.8898, height: 1190.5512),
         CGSize(width: 612, height: 792)][paperIndex]
    }
    var paperSize: CGSize {
        let size = portraitSize
        return landscape ? CGSize(width: size.height, height: size.width) : size
    }
}

enum LayoutError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

struct ImpositionResult {
    let data: Data
    let columns: Int
    let rows: Int
    let sheetCount: Int
}

enum Imposition {
    static func pageIndices(_ input: String, count: Int) throws -> [Int] {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "全部" { return Array(0..<count) }
        var pages: [Int] = []
        var seen = Set<Int>()
        let normalized = text.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "－", with: "-")
        for part in normalized.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count), let first = Int(bounds[0]),
                  first >= 1, first <= count else {
                throw LayoutError.message("页码应在 1–\(count) 之间，例如：1-6, 8。")
            }
            let last: Int
            if bounds.count == 2 {
                guard let end = Int(bounds[1]), end >= first, end <= count else {
                    throw LayoutError.message("请填写有效的页码范围，例如：1-6, 8。")
                }
                last = end
            } else { last = first }
            for page in first...last where seen.insert(page - 1).inserted { pages.append(page - 1) }
        }
        return pages
    }

    static func displaySize(_ page: PDFPage) -> CGSize {
        let size = page.bounds(for: .cropBox).size
        return abs(page.rotation % 180) == 90 ? CGSize(width: size.height, height: size.width) : size
    }

    static func grid(document: PDFDocument, settings: PrintSettings) -> (Int, Int) {
        let n = settings.pagesPerSheet
        if settings.arrangement == 1 { return (1, n) }
        if settings.arrangement == 2 { return (n, 1) }
        let gap: CGFloat = 8.503937 // 3 mm
        let width = settings.paperSize.width - 2 * settings.margin
        let height = settings.paperSize.height - 2 * settings.margin
        let sample = settings.pageIndices.prefix(32).compactMap { document.page(at: $0) }.map(displaySize)
        var best = (1, n)
        var bestScore: CGFloat = -1
        // Compare readable page area, allowing an unused cell for odd page counts.
        // The explicit vertical/horizontal choices still use exactly one column/row.
        for columns in 1...n {
            let rows = (n + columns - 1) / columns
            let w = (width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let h = (height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            guard w > 0, h > 0 else { continue }
            let score = sample.reduce(CGFloat(0)) { total, size in
                guard size.width > 0, size.height > 0 else { return total }
                let scale = min(w / size.width, h / size.height)
                return total + size.width * size.height * scale * scale
            }
            let adjustedScore = score * (1 - 0.01 * CGFloat(columns * rows - n) / CGFloat(n))
            if adjustedScore > bestScore { best = (columns, rows); bestScore = adjustedScore }
        }
        return best
    }

    static func compose(source: Data, password: String?, settings: PrintSettings,
                        cancelled: () -> Bool) throws -> ImpositionResult? {
        guard let document = PDFDocument(data: source) else { throw LayoutError.message("无法读取 PDF。") }
        if document.isLocked, !document.unlock(withPassword: password ?? "") {
            throw LayoutError.message("PDF 密码不正确。")
        }
        guard document.allowsPrinting else { throw LayoutError.message("此 PDF 的权限不允许打印。") }
        let (columns, rows) = grid(document: document, settings: settings)
        let gap: CGFloat = 8.503937
        let paper = settings.paperSize
        let cellW = (paper.width - 2 * settings.margin - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let cellH = (paper.height - 2 * settings.margin - CGFloat(rows - 1) * gap) / CGFloat(rows)
        guard cellW > 0, cellH > 0 else { throw LayoutError.message("当前排版过密，请减少每面页数或缩小边距。") }
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox,
                                      [kCGPDFContextCreator: "PDF拼印"] as CFDictionary) else {
            throw LayoutError.message("无法创建打印页面。")
        }
        let sheetCount = (settings.pageIndices.count + settings.pagesPerSheet - 1) / settings.pagesPerSheet
        for sheet in 0..<sheetCount {
            if cancelled() { context.closePDF(); return nil }
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            for slot in 0..<settings.pagesPerSheet {
                if cancelled() { context.endPDFPage(); context.closePDF(); return nil }
                let offset = sheet * settings.pagesPerSheet + slot
                if offset >= settings.pageIndices.count { break }
                guard let page = document.page(at: settings.pageIndices[offset]) else {
                    throw LayoutError.message("无法读取第 \(settings.pageIndices[offset] + 1) 页。")
                }
                let size = displaySize(page)
                guard size.width > 0, size.height > 0 else {
                    throw LayoutError.message("第 \(settings.pageIndices[offset] + 1) 页尺寸无效。")
                }
                let column = slot % columns
                let row = slot / columns
                let cell = CGRect(x: settings.margin + CGFloat(column) * (cellW + gap),
                                  y: paper.height - settings.margin - CGFloat(row + 1) * cellH - CGFloat(row) * gap,
                                  width: cellW, height: cellH)
                let scale = min(cellW / size.width, cellH / size.height)
                let origin = CGPoint(x: cell.midX - size.width * scale / 2,
                                     y: cell.midY - size.height * scale / 2)
                context.saveGState()
                context.clip(to: cell)
                context.translateBy(x: origin.x, y: origin.y)
                context.scaleBy(x: scale, y: scale)
                // PDFKit applies intrinsic page rotation and crop-box offsets, and draws annotations.
                page.draw(with: .cropBox, to: context)
                context.restoreGState()
                if settings.showsBorders {
                    // Draw in paper coordinates so the line stays 0.5 pt at every page scale.
                    let pageRect = CGRect(origin: origin, size: CGSize(width: size.width * scale,
                                                                       height: size.height * scale))
                    context.saveGState()
                    context.setStrokeColor(CGColor(gray: 0.25, alpha: 1))
                    context.setLineWidth(0.5)
                    context.stroke(pageRect.insetBy(dx: 0.25, dy: 0.25))
                    context.restoreGState()
                }
            }
            context.endPDFPage()
        }
        context.closePDF()
        return ImpositionResult(data: data as Data, columns: columns, rows: rows, sheetCount: sheetCount)
    }
}
