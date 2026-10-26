import AVFoundation
import PDFKit
import SwiftUI

struct ReaderView: View {
    @StateObject private var engine: ReaderEngine
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("fontSize") private var fontSize: Double = 21
    @State private var showPageImage = false
    @State private var scrubPage: Double = 0
    @State private var scrubbing = false
    @State private var askingPage = false
    @State private var pageField = ""
    @State private var askingStop = false
    @State private var stopField = ""
    @State private var choosingVoice = false

    init(book: Book, document: PDFDocument, library: LibraryStore) {
        _engine = StateObject(wrappedValue: ReaderEngine(book: book, document: document, library: library))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if showPageImage {
                    PDFPageView(document: engine.document, pageIndex: engine.pageIndex)
                } else {
                    ReaderTextView(content: engine.content,
                                   highlight: engine.content.sentences.isEmpty ? nil : engine.sentenceIndex,
                                   fontSize: CGFloat(fontSize)) { engine.jump(toSentence: $0) }
                }
                if engine.isLoadingPage {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading the page image…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                } else if engine.content.sentences.isEmpty && !showPageImage {
                    Text("No words found on this page.").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            controls
        }
        .navigationTitle(engine.book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarMenu }
        .onAppear { scrubPage = Double(engine.pageIndex) }
        .onChange(of: engine.pageIndex) { p in if !scrubbing { scrubPage = Double(p) } }
        .onDisappear { engine.shutdown() }
        .alert("Go to page", isPresented: $askingPage) {
            TextField("1–\(engine.pageCount)", text: $pageField).keyboardType(.numberPad)
            Button("Go") { if let n = Int(pageField) { engine.goTo(page: n - 1) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Stop after page", isPresented: $askingStop) {
            TextField("Page number", text: $stopField).keyboardType(.numberPad)
            Button("Set") { if let n = Int(stopField), n >= engine.pageIndex + 1 { engine.setStopPage(min(n, engine.pageCount)) } }
            if engine.book.stopAfterPage != nil {
                Button("Read to the end", role: .destructive) { engine.setStopPage(nil) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reading pauses when it finishes this page. You're on page \(engine.pageIndex + 1).")
        }
        .sheet(isPresented: $choosingVoice) {
            VoicePicker(selected: $engine.voiceID)
        }
    }

    // MARK: - Bottom controls

    private var controls: some View {
        VStack(spacing: 12) {
            if let message = engine.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Text("Page \(Int(scrubPage) + 1) of \(engine.pageCount)")
                    .monospacedDigit()
                Spacer()
                Text(timeLeftText).monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if engine.pageCount > 1 {
                Slider(value: $scrubPage, in: 0...Double(engine.pageCount - 1), step: 1, onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing, Int(scrubPage) != engine.pageIndex { engine.goTo(page: Int(scrubPage)) }
                })
            }

            HStack {
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { s in
                        Button { engine.speed = s } label: {
                            if s == engine.speed { Label(speedLabel(s), systemImage: "checkmark") } else { Text(speedLabel(s)) }
                        }
                    }
                } label: {
                    Text(speedLabel(engine.speed))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .frame(width: 58, height: 36)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel("Reading speed")

                Spacer()
                Button { engine.previousSentence() } label: { Image(systemName: "backward.fill").font(.title2) }
                    .accessibilityLabel("Previous sentence")
                Spacer()
                Button { engine.togglePlay() } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 62))
                }
                .accessibilityLabel(engine.isPlaying ? "Pause" : "Read aloud")
                Spacer()
                Button { engine.nextSentence() } label: { Image(systemName: "forward.fill").font(.title2) }
                    .accessibilityLabel("Next sentence")
                Spacer()

                Menu {
                    Button("Off") { engine.setSleepTimer(minutes: nil) }
                    ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in
                        Button("\(m) minutes") { engine.setSleepTimer(minutes: m) }
                    }
                } label: {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        sleepLabel(now: context.date)
                    }
                    .frame(width: 58, height: 36)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .accessibilityLabel("Sleep timer")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarMenu: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("View", selection: $showPageImage) {
                    Label("Text", systemImage: "text.alignleft").tag(false)
                    Label("Page image", systemImage: "doc.richtext").tag(true)
                }
                Button { pageField = ""; askingPage = true } label: { Label("Go to page…", systemImage: "arrow.right.doc.on.clipboard") }
                Button { stopField = engine.book.stopAfterPage.map { String($0) } ?? ""; askingStop = true } label: {
                    Label(engine.book.stopAfterPage.map { "Stop after page \($0)" } ?? "Stop after page…", systemImage: "flag.checkered")
                }
                Button { choosingVoice = true } label: { Label("Voice…", systemImage: "person.wave.2") }
                Section("Text size") {
                    Button { fontSize = min(fontSize + 2, 40) } label: { Label("Larger text", systemImage: "textformat.size.larger") }
                    Button { fontSize = max(fontSize - 2, 13) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                }
                ShareLink(item: library.exportable(engine.book), preview: SharePreview(engine.book.title)) {
                    Label("Share or save PDF", systemImage: "square.and.arrow.up")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func speedLabel(_ s: Double) -> String {
        (s == s.rounded() ? String(format: "%.0f", s) : String(format: "%g", s)) + "×"
    }

    @ViewBuilder
    private func sleepLabel(now: Date) -> some View {
        if let end = engine.sleepEnd, end > now {
            let left = Int(end.timeIntervalSince(now))
            Text(String(format: "%d:%02d", left / 60, left % 60))
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        } else {
            Image(systemName: "moon.zzz")
        }
    }

    private var timeLeftText: String {
        let s = engine.secondsLeft
        let target = engine.book.stopAfterPage.map { " to p. \($0)" } ?? " left"
        if s < 60 { return "Under a minute" + target }
        let m = Int(s / 60)
        return (m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min") + target
    }
}

/// Voices installed on the phone. Better ones download from iOS Settings.
private struct VoicePicker: View {
    @Binding var selected: String?
    @Environment(\.dismiss) private var dismiss
    @State private var preview = AVSpeechSynthesizer()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ReaderEngine.availableVoices, id: \.identifier) { v in
                        Button {
                            selected = v.identifier
                            preview.stopSpeaking(at: .immediate)
                            let u = AVSpeechUtterance(string: "This is how \(v.name) sounds reading your book.")
                            u.voice = v
                            preview.speak(u)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name).foregroundStyle(.primary)
                                    Text("\(quality(v)) · \(Locale.current.localizedString(forIdentifier: v.language) ?? v.language)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if v.identifier == (selected ?? ReaderEngine.availableVoices.first?.identifier) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                } footer: {
                    Text("For more natural voices, open Settings › Accessibility › Spoken Content › Voices, download an Enhanced or Premium voice, then come back here.")
                }
            }
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}

/// The page text, with the sentence being read highlighted and kept in view. Tap a sentence to read from there.
struct ReaderTextView: UIViewRepresentable {
    let content: PageContent
    let highlight: Int?
    let fontSize: CGFloat
    var onTapSentence: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = false
        tv.backgroundColor = .systemBackground
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 48, right: 20)
        tv.alwaysBounceVertical = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tv.addGestureRecognizer(tap)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        let c = context.coordinator
        c.content = content
        c.onTap = onTapSentence
        let newPage = c.shownID != content.id
        if newPage || c.shownSize != fontSize {
            let body = UIFont.systemFont(ofSize: fontSize)
            let serif = body.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: fontSize) } ?? body
            let para = NSMutableParagraphStyle()
            para.lineSpacing = fontSize * 0.35
            para.paragraphSpacing = fontSize * 0.8
            tv.attributedText = NSAttributedString(string: content.text, attributes: [
                .font: serif, .foregroundColor: UIColor.label, .paragraphStyle: para,
            ])
            c.shownID = content.id
            c.shownSize = fontSize
            c.shownHighlight = nil
            if newPage { tv.setContentOffset(CGPoint(x: 0, y: -tv.adjustedContentInset.top), animated: false) }
        }
        guard c.shownHighlight != highlight else { return }
        let storage = tv.textStorage
        let all = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: all)
        c.shownHighlight = highlight
        guard let h = highlight, content.sentences.indices.contains(h) else { return }
        let range = content.sentences[h]
        guard NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.backgroundColor, value: (UIColor(named: "AccentColor") ?? .systemTeal).withAlphaComponent(0.25), range: range)

        // Keep the spoken sentence in the upper part of the screen.
        let lm = tv.layoutManager
        lm.ensureLayout(for: tv.textContainer)
        let glyphs = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: tv.textContainer)
        rect.origin.y += tv.textContainerInset.top
        let visible = CGRect(origin: tv.contentOffset, size: tv.bounds.size).insetBy(dx: 0, dy: tv.bounds.height * 0.15)
        if tv.bounds.height > 0, !visible.contains(rect) {
            let maxY = max(tv.contentSize.height - tv.bounds.height + tv.adjustedContentInset.bottom, -tv.adjustedContentInset.top)
            let y = min(max(rect.minY - tv.bounds.height * 0.25, -tv.adjustedContentInset.top), maxY)
            tv.setContentOffset(CGPoint(x: 0, y: y), animated: true)
        }
    }

    final class Coordinator: NSObject {
        var content: PageContent = .empty
        var onTap: ((Int) -> Void)?
        var shownID: UUID?
        var shownSize: CGFloat = 0
        var shownHighlight: Int?

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let tv = g.view as? UITextView else { return }
            var p = g.location(in: tv)
            p.x -= tv.textContainerInset.left
            p.y -= tv.textContainerInset.top
            let i = tv.layoutManager.characterIndex(for: p, in: tv.textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
            if let s = content.sentences.firstIndex(where: { NSMaxRange($0) > i }) { onTap?(s) }
        }
    }
}

/// The original page, for photos and layouts where the picture matters.
struct PDFPageView: UIViewRepresentable {
    let document: PDFDocument
    let pageIndex: Int

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = document
        v.displayMode = .singlePage
        v.autoScales = true
        v.backgroundColor = .secondarySystemBackground
        if let page = document.page(at: pageIndex) { v.go(to: page) }
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if let page = document.page(at: pageIndex), v.currentPage != page { v.go(to: page) }
    }
}
