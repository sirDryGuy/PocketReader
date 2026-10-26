import ImageIO
import UIKit
import Vision

/// One photographed page, kept as JPEG data so a long scan doesn't fill the phone's memory.
struct ScanPage: Identifiable {
    let id = UUID()
    var jpeg: Data
    var thumbnail: UIImage

    /// Shrinks to at most `maxSide` pixels, bakes in the camera's orientation, and compresses.
    static func make(from image: UIImage, maxSide: CGFloat = 2400) -> ScanPage? {
        autoreleasepool { () -> ScanPage? in
            let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            guard px.width > 0, px.height > 0 else { return nil }
            let scale = min(1, maxSide / max(px.width, px.height))
            let full = draw(image, size: CGSize(width: (px.width * scale).rounded(), height: (px.height * scale).rounded()))
            guard let data = full.jpegData(compressionQuality: 0.72) else { return nil }
            let t = 260 / max(px.width, px.height)
            let thumb = draw(image, size: CGSize(width: (px.width * t).rounded(), height: (px.height * t).rounded()))
            return ScanPage(jpeg: data, thumbnail: thumb)
        }
    }

    func rotatedClockwise() -> ScanPage? {
        guard let img = UIImage(data: jpeg) else { return nil }
        let rotated = UIImage(cgImage: img.cgImage!, scale: 1, orientation: .right)
        return ScanPage.make(from: rotated)
    }

    private static func draw(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

enum PDFMaker {
    /// Reads every photo with Vision, then writes a PDF whose pages are the photos with the
    /// recognized words laid invisibly on top, so the PDF is searchable in other apps too.
    static func make(pages: [ScanPage], progress: @escaping @MainActor (Int) -> Void) async -> (pdf: Data, texts: [Int: String]) {
        var texts: [Int: String] = [:]
        var allLines: [[OCRLine]] = []
        for (i, page) in pages.enumerated() {
            await progress(i)
            var lines: [OCRLine] = []
            if let src = CGImageSourceCreateWithData(page.jpeg as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                lines = (try? await PageText.recognizeLines(cg)) ?? []
            }
            allLines.append(lines)
            texts[i] = PageText.assemble(PageText.order(lines))
        }
        await progress(pages.count)

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            for (i, page) in pages.enumerated() {
                autoreleasepool {
                    guard let provider = CGDataProvider(data: page.jpeg as CFData),
                          let cg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
                    else { return }
                    // Letter width; height follows the photo.
                    let w: CGFloat = 612
                    let h = w * CGFloat(cg.height) / CGFloat(cg.width)
                    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
                    ctx.beginPage(withBounds: bounds, pageInfo: [:])
                    UIImage(cgImage: cg).draw(in: bounds)
                    for line in allLines[i] {
                        let box = CGRect(x: line.minX * w, y: line.top * h, width: line.width * w, height: line.height * h)
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: max(box.height * 0.8, 1)),
                            .foregroundColor: UIColor.clear,
                        ]
                        NSAttributedString(string: line.text, attributes: attrs).draw(at: box.origin)
                    }
                }
            }
        }
        return (data, texts)
    }
}
