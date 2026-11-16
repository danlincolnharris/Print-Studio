import Foundation
import AppKit
import CoreGraphics

// MARK: - Multi-page PDF support
//
// A PDF (a magazine, a book, a portfolio) is printed page by page. Each page is drawn at 360 ppi
// into an Adobe RGB working image, so photos and text come out at full print resolution, and then
// goes through the same paper-profile conversion a photo does. Pages are sent to the printer in
// small batches so a 200-page file never turns into one multi-gigabyte print job.

/// Which pages of the range to print. Odd and even make manual two-sided printing possible.
enum PageFilter: String, CaseIterable, Identifiable {
    case all, odd, even
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All"
        case .odd: return "Odd only"
        case .even: return "Even only"
        }
    }
}

enum PageSelection {
    /// Turns "1-12, 15, 20-" into page numbers. Empty or "all" means every page.
    static func pages(text: String, count: Int, filter: PageFilter, reverse: Bool) -> (pages: [Int]?, error: String?) {
        guard count > 0 else { return (nil, "This PDF has no pages.") }
        var out: [Int] = []
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased() == "all" {
            out = Array(1...count)
        } else {
            for rawPart in t.split(whereSeparator: { $0 == "," || $0 == ";" }) {
                let part = rawPart.trimmingCharacters(in: .whitespaces)
                if part.isEmpty { continue }
                let ends = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if ends.count == 1 {
                    guard let n = Int(ends[0]) else { return (nil, "Could not read \"\(part)\" in the page range.") }
                    out.append(n)
                } else {
                    let a: Int? = ends[0].isEmpty ? 1 : Int(ends[0])
                    let b: Int? = ends[1].isEmpty ? count : Int(ends[1])
                    guard let lo = a, let hi = b, lo <= hi else {
                        return (nil, "Could not read \"\(part)\" in the page range.")
                    }
                    out.append(contentsOf: lo...hi)
                }
            }
            if let bad = out.first(where: { $0 < 1 || $0 > count }) {
                return (nil, "Page \(bad) is outside this PDF (it has pages 1–\(count)).")
            }
        }
        var seen = Set<Int>()
        out = out.filter { seen.insert($0).inserted }
        switch filter {
        case .all: break
        case .odd: out = out.filter { $0 % 2 == 1 }
        case .even: out = out.filter { $0 % 2 == 0 }
        }
        if reverse { out.reverse() }
        return (out, out.isEmpty ? "No pages match that range." : nil)
    }
}

enum PDFPages {
    /// The working space PDF pages are drawn into before the paper conversion.
    static var workingSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.adobeRGB1998) }

    static func open(_ url: URL) -> CGPDFDocument? {
        guard let d = CGPDFDocument(url as CFURL), d.isUnlocked, d.numberOfPages > 0 else { return nil }
        return d
    }

    static func rotation(_ page: CGPDFPage) -> Int {
        ((Int(page.rotationAngle) % 360) + 360) % 360
    }

    /// The page as it is meant to be seen (crop box, with the page's rotation applied), in points.
    static func pageSize(_ page: CGPDFPage) -> CGSize {
        let b = page.getBoxRect(.cropBox)
        let r = rotation(page)
        return (r == 90 || r == 270) ? CGSize(width: b.height, height: b.width) : b.size
    }

    /// Draws the page to fill a width x height pixel context, on white. Scales up as well as down,
    /// which CGPDFPage's own drawing transform will not do.
    static func draw(_ page: CGPDFPage, in ctx: CGContext, width: Int, height: Int) {
        let box = page.getBoxRect(.cropBox)
        let size = pageSize(page)
        guard size.width > 0, size.height > 0 else { return }
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        switch rotation(page) {
        case 90:
            ctx.translateBy(x: 0, y: box.width)
            ctx.rotate(by: -.pi / 2)
        case 180:
            ctx.translateBy(x: box.width, y: box.height)
            ctx.rotate(by: .pi)
        case 270:
            ctx.translateBy(x: box.height, y: 0)
            ctx.rotate(by: .pi / 2)
        default:
            break
        }
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.clip(to: box)
        ctx.interpolationQuality = .high
        ctx.setShouldAntialias(true)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    /// A small Adobe RGB picture of the page for the preview, soft proof and gamut check.
    static func renderPreview(_ page: CGPDFPage, maxSide: Int) -> CGImage? {
        let size = pageSize(page)
        guard size.width > 0, size.height > 0, let cs = workingSpace else { return nil }
        let scale = Double(maxSide) / Double(max(size.width, size.height))
        let w = max(1, Int((Double(size.width) * scale).rounded()))
        let h = max(1, Int((Double(size.height) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        draw(page, in: ctx, width: w, height: h)
        return ctx.makeImage()
    }
}

/// The layout controls, captured once so every page of a PDF is laid out the same way.
struct LayoutSettings {
    var mode: LayoutMode
    var orientation: PaperOrientation
    var border: Double
    var customScale: Double
    var hAlign: HAlign
    var vAlign: VAlign
    var half: HalfPosition
    var cropMarks: Bool

    func layout(sheet: SheetSize, pixels: CGSize, dpi: Double) -> LayoutResult {
        LayoutEngine.compute(sheet: sheet, mode: mode, orientation: orientation,
                             pixels: pixels, dpi: dpi,
                             borderInches: border, customScale: customScale,
                             hAlign: hAlign, vAlign: vAlign, half: half,
                             cropMarks: cropMarks)
    }
}

/// Thread-safe "please stop" switch, set from the Stop button and read by the background job.
final class StopFlag {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Several converted pages in one PDF file, for one batch sent to the printer.
final class MultiPagePDF {
    let url: URL
    private let ctx: CGContext
    private(set) var count = 0

    init(title: String) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("P900Print", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: "/", with: "-")
        url = dir.appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8)).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let c = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw PipelineError.failed("Could not create the PDF.")
        }
        ctx = c
    }

    func add(image: CGImage, layout: LayoutResult) {
        var box = CGRect(x: 0, y: 0, width: layout.canvasW, height: layout.canvasH)
        let boxData = NSData(bytes: &box, length: MemoryLayout<CGRect>.size)
        let info = [kCGPDFContextMediaBox as String: boxData] as CFDictionary
        ctx.beginPDFPage(info)
        PDFWriter.drawPage(ctx: ctx, image: image, layout: layout)
        ctx.endPDFPage()
        count += 1
    }

    func finish() -> URL {
        ctx.closePDF()
        return url
    }
}

struct PDFPrintJob {
    /// Pages per print job sent to the printer. Small enough that the spool file stays modest.
    static let pagesPerBatch = 6
    /// Preview PDF renders only this many pages of the range.
    static let previewPages = 4

    let url: URL
    let pages: [Int]
    let settings: LayoutSettings
    let sheet: SheetSize
    let paper: PaperPreset
    let intent: Intent
    let blackPoint: Bool
    let tagWithPaperProfile: Bool
    let queue: String
    let copies: Int
    let frontFeed: Bool
    let overcoat: Bool
    let glossSmooth: Bool
    let bottomEdge: Bool
    let highSpeed: Bool
    let tone: Tone

    struct Outcome {
        var text: String
        var pagesSent: Int
        var firstLayout: LayoutResult?
        var jobIDs: [String]
    }

    func run(dryRun: Bool, progress: (String) -> Void, shouldStop: () -> Bool) throws -> Outcome {
        guard let doc = PDFPages.open(url) else {
            throw PipelineError.failed("Could not open \(url.lastPathComponent) as a PDF. If it is password protected, save an unlocked copy first.")
        }
        let name = url.displayName
        var lines: [String] = []
        var sent = 0
        var firstLayout: LayoutResult?
        var ids: [String] = []
        let passes = dryRun ? 1 : max(1, copies)
        let list = dryRun ? Array(pages.prefix(Self.previewPages)) : pages
        let total = list.count * passes
        var done = 0
        var stopped = false

        outer: for pass in 1...passes {
            var i = 0
            while i < list.count {
                if shouldStop() { stopped = true; break outer }
                let chunk = Array(list[i..<min(i + Self.pagesPerBatch, list.count)])
                i += chunk.count
                let writer = try MultiPagePDF(title: "\(name) p\(chunk.first!)-\(chunk.last!)")
                var bleed = false
                var inBatch: [Int] = []

                for p in chunk {
                    if shouldStop() { stopped = true; break }
                    guard let page = doc.page(at: p) else {
                        lines.append("Page \(p) could not be read and was skipped.")
                        continue
                    }
                    let size = PDFPages.pageSize(page)
                    let px = CGSize(width: (Double(size.width) / 72 * P900.targetPPI).rounded(),
                                    height: (Double(size.height) / 72 * P900.targetPPI).rounded())
                    let lay = settings.layout(sheet: sheet, pixels: px, dpi: P900.targetPPI)
                    if firstLayout == nil { firstLayout = lay }
                    bleed = lay.bleed
                    let tw = max(16, Int((Double(lay.rect.width) / 72 * P900.targetPPI).rounded()))
                    let th = max(16, Int((Double(lay.rect.height) / 72 * P900.targetPPI).rounded()))
                    progress("Page \(p): converting (\(done + 1) of \(total))…")
                    let converted = try autoreleasepool {
                        try ColorPipeline.convertPDFPage(page, targetW: tw, targetH: th,
                                                         paperProfile: paper.url, intent: intent,
                                                         blackPoint: blackPoint,
                                                         tagWithPaperProfile: tagWithPaperProfile,
                                                         tone: tone)
                    }
                    autoreleasepool { writer.add(image: converted.image, layout: lay) }
                    inBatch.append(p)
                    done += 1
                }

                let pdf = writer.finish()
                if inBatch.isEmpty {
                    try? FileManager.default.removeItem(at: pdf)
                    if stopped { break outer }
                    continue
                }
                let label = inBatch.count == 1 ? "page \(inBatch[0])" : "pages \(inBatch.first!)–\(inBatch.last!)"

                if dryRun {
                    DispatchQueue.main.async { NSWorkspace.shared.open(pdf) }
                    lines.append("Preview of \(label) opened in Preview (nothing was sent to the printer). Preview shows the first \(Self.previewPages) pages of the range.")
                    break outer
                }

                // Keep at most one job waiting behind the one printing, so the spool never balloons.
                if !waitForRoom(progress: progress, shouldStop: shouldStop) {
                    try? FileManager.default.removeItem(at: pdf)
                    lines.append("Stopped before \(label) was sent.")
                    stopped = true
                    break outer
                }
                progress("Sending \(label) to the printer…")
                let r = try Spooler.submit(pdf: pdf, queue: queue, sheet: sheet, bleed: bleed,
                                           mediaCode: paper.mediaCode, copies: 1,
                                           frontFeed: frontFeed, overcoat: overcoat,
                                           glossSmooth: glossSmooth, bottomEdge: bottomEdge, highSpeed: highSpeed,
                                           title: "\(name) \(label)")
                // CUPS has its own copy of the file now.
                try? FileManager.default.removeItem(at: pdf)
                if let range = r.range(of: "request id is ") {
                    ids.append(String(r[range.upperBound...].prefix { !$0.isWhitespace }))
                }
                sent += inBatch.count
                let copyNote = passes > 1 ? " (copy \(pass) of \(passes))" : ""
                lines.append("Sent \(label)\(copyNote).")
                if stopped { break outer }
            }
        }

        if !dryRun {
            var summary = "Sent \(sent) of \(total) page\(total == 1 ? "" : "s") from \(name) to \(queue)"
            summary += ", converted to \(paper.name), \(intent.label)\(blackPoint ? ", black point compensation" : "")."
            lines.insert(summary, at: 0)
            if stopped {
                lines.append("Stopped. Pages already sent will still print; use Cancel all jobs to stop those too.")
            }
        }
        return Outcome(text: lines.joined(separator: "\n"), pagesSent: sent, firstLayout: firstLayout, jobIDs: ids)
    }

    /// Waits until at most one job is in the queue. Returns false if Stop was pressed while waiting.
    private func waitForRoom(progress: (String) -> Void, shouldStop: () -> Bool) -> Bool {
        while true {
            if shouldStop() { return false }
            let n = (InkReader.shell("/usr/bin/lpstat", ["-o", queue]) ?? "")
                .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            if n <= 1 { return true }
            progress("Next pages are ready; waiting for the printer (\(n) jobs in the queue)…")
            Thread.sleep(forTimeInterval: 5)
        }
    }
}
