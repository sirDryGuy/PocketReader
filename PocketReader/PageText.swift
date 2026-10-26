import Foundation
import NaturalLanguage
import PDFKit
import UIKit
import Vision

/// One line of text in reading order. `breakBefore` marks a paragraph break.
struct TextLine {
    var text: String
    var breakBefore: Bool
}

/// A line found by Vision, with its box in normalized image coordinates (origin top-left).
struct OCRLine {
    var text: String
    var minX: CGFloat
    var maxX: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var height: CGFloat { bottom - top }
    var width: CGFloat { maxX - minX }
}

enum PageText {

    // MARK: - Getting a page's text

    /// Text of a PDF page. Uses the PDF's own text when it has one, otherwise reads the page image.
    @MainActor
    static func extract(page: PDFPage?) async -> String {
        guard let page else { return "" }
        let raw = page.string ?? ""
        if raw.filter({ $0.isLetter }).count >= 40 {
            return assemble(dropPageFurniture(plainLines(raw)))
        }
        guard let image = page.thumbnail(of: CGSize(width: 2400, height: 2400), for: .mediaBox).cgImage else {
            return assemble(plainLines(raw))
        }
        let lines = (try? await recognizeLines(image)) ?? []
        let ocr = assemble(order(lines))
        return ocr.count >= raw.count ? ocr : assemble(plainLines(raw))
    }

    static func plainLines(_ raw: String) -> [TextLine] {
        var out: [TextLine] = []
        var pendingBreak = false
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { pendingBreak = true; continue }
            out.append(TextLine(text: t, breakBefore: pendingBreak))
            pendingBreak = false
        }
        return out
    }

    /// Drops a bare page number or a "12  THE REPUBLIC" style running header at the top or bottom.
    static func dropPageFurniture(_ lines: [TextLine]) -> [TextLine] {
        var lines = lines
        if let first = lines.first, isFurniture(first.text) { lines.removeFirst() }
        if let last = lines.last, isFurniture(last.text) { lines.removeLast() }
        return lines
    }

    static func isFurniture(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.range(of: #"^[\divxlcIVXLC\s\-–—.]{1,10}$"#, options: .regularExpression) != nil { return true }
        guard t.count < 70 else { return false }
        let letters = t.filter { $0.isLetter }
        let shouting = !letters.isEmpty && letters == letters.uppercased()
        let numbered = t.range(of: #"^\d{1,4}\s+\S|\S\s+\d{1,4}$"#, options: .regularExpression) != nil
        return shouting && numbered
    }

    // MARK: - Vision OCR

    static func recognizeLines(_ image: CGImage) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                    let lines: [OCRLine] = (request.results ?? []).compactMap { obs in
                        guard let text = obs.topCandidates(1).first?.string else { return nil }
                        let b = obs.boundingBox
                        return OCRLine(text: text, minX: b.minX, maxX: b.maxX, top: 1 - b.maxY, bottom: 1 - b.minY)
                    }
                    cont.resume(returning: lines)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Puts OCR lines in reading order: finds a two-column gutter if there is one, reads the left
    /// column then the right, and marks paragraph breaks from vertical gaps.
    static func order(_ input: [OCRLine]) -> [TextLine] {
        guard !input.isEmpty else { return [] }
        let heights = input.map(\.height).sorted()
        let lineH = max(heights[heights.count / 2], 0.005)

        var items = input
        // Running header and page number, judged by position and the gap that sets them apart.
        let byTop = items.sorted { $0.top < $1.top }
        if byTop.count > 3, let head = byTop.first, head.top < 0.08,
           byTop[1].top - head.bottom > lineH * 1.8, head.text.count < 70,
           head.text.contains(where: \.isNumber) || head.text == head.text.uppercased() {
            items.removeAll { $0.top == head.top && $0.text == head.text }
        }
        if let foot = byTop.last, foot.bottom > 0.92, isFurniture(foot.text) {
            items.removeAll { $0.top == foot.top && $0.text == foot.text }
        }

        var groups: [[OCRLine]] = [items]
        let narrow = items.filter { $0.width < 0.48 }
        if narrow.count >= 6, let gutter = findGutter(items) {
            let left = items.filter { $0.width < 0.6 && $0.maxX <= gutter + 0.01 }
            let right = items.filter { $0.width < 0.6 && $0.minX >= gutter - 0.01 }
            if left.count >= 3 && right.count >= 3 {
                let colTop = (left + right).map(\.top).min() ?? 0
                let spanning = items.filter { line in
                    !left.contains { $0.top == line.top && $0.minX == line.minX } &&
                    !right.contains { $0.top == line.top && $0.minX == line.minX }
                }
                let above = spanning.filter { $0.top < colTop }
                let below = spanning.filter { $0.top >= colTop }
                groups = [above, left, right, below].filter { !$0.isEmpty }
            }
        }

        var out: [TextLine] = []
        for (gi, group) in groups.enumerated() {
            var prevBottom: CGFloat?
            for (ri, row) in rows(group, lineH: lineH).enumerated() {
                let text = row.map(\.text).joined(separator: " ")
                var brk = false
                if ri == 0 { brk = gi > 0 && isEndOfThought(out.last?.text) }
                else if let pb = prevBottom, row[0].top - pb > lineH * 0.9 { brk = true }
                out.append(TextLine(text: text, breakBefore: brk))
                prevBottom = row.map(\.bottom).max()
            }
        }
        return out
    }

    private static func isEndOfThought(_ s: String?) -> Bool {
        guard let last = s?.trimmingCharacters(in: .whitespaces).last else { return true }
        return ".!?:\"”’)".contains(last)
    }

    /// Lines sorted top to bottom; boxes Vision split from the same printed line are joined left to right.
    private static func rows(_ lines: [OCRLine], lineH: CGFloat) -> [[OCRLine]] {
        var result: [[OCRLine]] = []
        for line in lines.sorted(by: { $0.top < $1.top }) {
            let mid = (line.top + line.bottom) / 2
            if var last = result.last, let ref = last.first,
               abs((ref.top + ref.bottom) / 2 - mid) < lineH * 0.5 {
                last.append(line)
                result[result.count - 1] = last.sorted { $0.minX < $1.minX }
            } else {
                result.append([line])
            }
        }
        return result
    }

    private static func findGutter(_ items: [OCRLine]) -> CGFloat? {
        let candidates = items.filter { $0.width < 0.6 }
        var best: (x: CGFloat, cover: Int)?
        var x: CGFloat = 0.3
        while x <= 0.7 {
            let cover = candidates.filter { $0.minX < x && $0.maxX > x }.count
            if best == nil || cover < best!.cover { best = (x, cover) }
            x += 0.01
        }
        guard let best, best.cover <= max(1, candidates.count / 25) else { return nil }
        return best.x
    }

    // MARK: - Lines → paragraphs

    /// Joins lines into paragraphs separated by blank lines, re-joining words hyphenated across lines.
    static func assemble(_ lines: [TextLine]) -> String {
        let lengths = lines.map { $0.text.count }.sorted()
        let typical = lengths.isEmpty ? 0 : lengths[(lengths.count * 3) / 4]
        var paragraphs: [String] = []
        var current = ""
        func flush() {
            let p = current.trimmingCharacters(in: .whitespaces)
            if !p.isEmpty { paragraphs.append(p) }
            current = ""
        }
        for (i, line) in lines.enumerated() {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); continue }
            if line.breakBefore { flush() }
            if current.isEmpty {
                current = t
            } else if current.hasSuffix("-"), let f = t.first, f.isLowercase {
                current.removeLast()
                current += t
            } else {
                current += " " + t
            }
            // A short line that ends a sentence, or a heading, closes its paragraph.
            let short = typical > 20 && Double(t.count) < Double(typical) * 0.6
            let nextUpper = i + 1 < lines.count && (lines[i + 1].text.first?.isUppercase ?? false)
            if short && !t.hasSuffix("-") && (isEndOfThought(t) || nextUpper) { flush() }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }
}

/// A page's text with the sentence ranges the reader speaks one at a time.
struct PageContent: Equatable {
    let id: UUID
    let text: String
    let sentences: [NSRange]
    let paragraphEnds: Set<Int>

    static let empty = PageContent(text: "")

    init(text: String) {
        id = UUID()
        self.text = text
        let ns = text as NSString
        var ranges: [NSRange] = []
        var ends = Set<Int>()
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, pRange, _, _ in
            guard let r = Range(pRange, in: text) else { return }
            var added = false
            for tok in tokenizer.tokens(for: r) {
                let trimmed = PageContent.trim(NSRange(tok, in: text), in: ns)
                guard trimmed.length > 0,
                      ns.substring(with: trimmed).rangeOfCharacter(from: .alphanumerics) != nil else { continue }
                ranges.append(contentsOf: PageContent.split(trimmed, in: ns))
                added = true
            }
            if added { ends.insert(ranges.count - 1) }
        }
        sentences = ranges
        paragraphEnds = ends
    }

    static func == (a: PageContent, b: PageContent) -> Bool { a.id == b.id }

    func sentence(_ i: Int) -> String {
        guard sentences.indices.contains(i) else { return "" }
        return (text as NSString).substring(with: sentences[i])
    }

    /// Characters from sentence `i` to the end of the page.
    func characters(from i: Int) -> Int {
        guard i < sentences.count else { return 0 }
        return sentences[i...].reduce(0) { $0 + $1.length }
    }

    private static func trim(_ r: NSRange, in ns: NSString) -> NSRange {
        var start = r.location, end = r.location + r.length
        let ws = CharacterSet.whitespacesAndNewlines
        while start < end, let u = UnicodeScalar(ns.character(at: start)), ws.contains(u) { start += 1 }
        while end > start, let u = UnicodeScalar(ns.character(at: end - 1)), ws.contains(u) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Splits very long sentences at a comma or semicolon near the middle so each spoken chunk stays short.
    private static func split(_ r: NSRange, in ns: NSString) -> [NSRange] {
        guard r.length > 280 else { return [r] }
        let mid = r.location + r.length / 2
        var best: Int?
        for i in (r.location + 60)..<(r.location + r.length - 60) {
            let c = ns.character(at: i)
            guard c == 44 || c == 59 || c == 58 else { continue } // , ; :
            guard i + 1 < ns.length, ns.character(at: i + 1) == 32 else { continue }
            if best == nil || abs(i - mid) < abs(best! - mid) { best = i }
        }
        guard let cut = best else { return [r] }
        let a = NSRange(location: r.location, length: cut + 1 - r.location)
        let b = trim(NSRange(location: cut + 1, length: r.location + r.length - cut - 1), in: ns)
        return split(a, in: ns) + split(b, in: ns)
    }
}
