import UIKit

/// A short guide added to the library on first launch, so there's something to press play on.
enum WelcomeBook {
    static let pages = [
        """
        Welcome to Pocket Reader

        Pocket Reader reads books out loud. Press the big play button at the bottom of the screen and it starts reading from where you left off. The sentence it is reading lights up, so you can follow along.

        Tap any sentence to jump there. The arrows next to the play button skip back or ahead one sentence, and the slider moves through the pages.

        The button on the left sets the speed. The moon on the right is a sleep timer: reading stops at the end of the sentence when time runs out.
        """,
        """
        Reading a real book

        Go back to your library and tap Scan pages. Hold the phone over the book and the camera finds the page edges by itself. Scan as many pages as you like, then tap Save. You can reorder or rotate pages before you tap Make PDF.

        Pocket Reader recognizes the words on each page right on your phone. The finished PDF is saved in your library, and you can share it or save it to Files from the menu.

        Already have a PDF? Tap Open PDF, or share a PDF to Pocket Reader from another app.

        Reading keeps going when the screen locks, and you can pause it from the lock screen. For a more natural voice, download an Enhanced or Premium voice in Settings, under Accessibility, Spoken Content, Voices. Then pick it from the Voice menu here.
        """,
    ]

    static func makePDF() -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let body = UIFont.systemFont(ofSize: 15)
        let serif = body.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 15) } ?? body
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5
        para.paragraphSpacing = 12
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for text in pages {
                ctx.beginPage()
                let parts = text.components(separatedBy: "\n\n")
                let out = NSMutableAttributedString()
                out.append(NSAttributedString(string: parts[0] + "\n\n", attributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold), .paragraphStyle: para,
                ]))
                out.append(NSAttributedString(string: parts.dropFirst().joined(separator: "\n\n"), attributes: [
                    .font: serif, .paragraphStyle: para,
                ]))
                out.draw(in: bounds.insetBy(dx: 72, dy: 72))
            }
        }
        return data.isEmpty ? nil : data
    }
}
