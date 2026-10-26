import AVFoundation
import MediaPlayer
import PDFKit
import UIKit

/// Reads a book aloud one sentence at a time, keeping its place, and keeps going with the screen locked.
@MainActor
final class ReaderEngine: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var book: Book
    @Published private(set) var pageIndex: Int
    @Published private(set) var content: PageContent = .empty
    @Published private(set) var sentenceIndex = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoadingPage = false
    @Published private(set) var message: String?
    @Published private(set) var sleepEnd: Date?

    @Published var speed: Double {
        didSet { UserDefaults.standard.set(speed, forKey: "speed"); settingsChanged() }
    }
    @Published var voiceID: String? {
        didSet { UserDefaults.standard.set(voiceID, forKey: "voiceID"); settingsChanged() }
    }

    let document: PDFDocument
    var pageCount: Int { document.pageCount }

    private let library: LibraryStore
    private let synth = AVSpeechSynthesizer()
    private var texts: [Int: String]
    private var inflight: [Int: Task<String, Never>] = [:]
    private var loadToken = 0
    private var current: AVSpeechUtterance?
    private var utteranceStart = Date()
    private var charsPerSecond: Double?
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    init(book: Book, document: PDFDocument, library: LibraryStore) {
        self.book = book
        self.document = document
        self.library = library
        self.texts = library.loadTexts(for: book.id)
        self.pageIndex = min(book.page, max(document.pageCount - 1, 0))
        let savedSpeed = UserDefaults.standard.double(forKey: "speed")
        self.speed = savedSpeed > 0 ? savedSpeed : 1.0
        self.voiceID = UserDefaults.standard.string(forKey: "voiceID")
        super.init()
        synth.delegate = self
        var b = book
        b.lastOpened = Date()
        self.book = b
        library.update(b)
        let start = book.sentence
        Task {
            await self.load(page: self.pageIndex, sentence: start)
            self.speakCurrent()
        }
        observeAudioSession()
        setUpRemoteCommands()
    }

    func shutdown() {
        pause()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        commandTargets.forEach { $0.0.removeTarget($0.1) }
        commandTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard !isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        if book.stopAfterPage.map({ pageIndex + 1 > $0 }) ?? false { setStopPage(nil) }
        message = nil
        isPlaying = true
        speakCurrent()
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        stopSpeech()
        updateNowPlaying()
    }

    func nextSentence() {
        if sentenceIndex + 1 < content.sentences.count {
            jump(toSentence: sentenceIndex + 1)
        } else if pageIndex + 1 < pageCount {
            goTo(page: pageIndex + 1)
        }
    }

    func previousSentence() {
        if sentenceIndex > 0 {
            jump(toSentence: sentenceIndex - 1)
        } else if pageIndex > 0 {
            goTo(page: pageIndex - 1, sentence: Int.max)
        }
    }

    func jump(toSentence i: Int) {
        guard content.sentences.indices.contains(i) else { return }
        stopSpeech()
        sentenceIndex = i
        savePosition()
        if isPlaying { speakCurrent() }
    }

    func goTo(page: Int, sentence: Int = 0) {
        let p = min(max(page, 0), max(pageCount - 1, 0))
        stopSpeech()
        Task {
            await load(page: p, sentence: sentence)
            if isPlaying { speakCurrent() }
        }
    }

    func setStopPage(_ page: Int?) {
        book.stopAfterPage = page
        library.update(book)
    }

    func setSleepTimer(minutes: Int?) {
        sleepEnd = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) }
    }

    // MARK: - Estimates

    /// Seconds of listening left, to the stop page if one is set, otherwise to the end of the book.
    var secondsLeft: Double {
        let endPage = min(book.stopAfterPage ?? pageCount, pageCount)
        let restOfPage = Double(content.characters(from: sentenceIndex))
        let known = texts.values.map { Double($0.count) }
        let perPage = known.isEmpty ? 1800 : known.reduce(0, +) / Double(known.count)
        let pagesAfter = Double(max(endPage - pageIndex - 1, 0))
        return (restOfPage + perPage * pagesAfter) / (charsPerSecond ?? 15 * speed)
    }

    // MARK: - Pages

    private func load(page: Int, sentence: Int) async {
        loadToken += 1
        let token = loadToken
        pageIndex = page
        if texts[page] == nil { isLoadingPage = true }
        let text = await text(for: page)
        guard token == loadToken else { return }
        content = PageContent(text: text)
        sentenceIndex = min(max(sentence, 0), max(content.sentences.count - 1, 0))
        isLoadingPage = false
        savePosition()
        updateNowPlaying()
        if page + 1 < pageCount { Task { _ = await self.text(for: page + 1) } }
    }

    private func text(for page: Int) async -> String {
        if let t = texts[page] { return t }
        if let running = inflight[page] { return await running.value }
        let task = Task { @MainActor [document] in await PageText.extract(page: document.page(at: page)) }
        inflight[page] = task
        let t = await task.value
        inflight[page] = nil
        texts[page] = t
        library.saveTexts(texts, for: book.id)
        return t
    }

    private func advancePage() {
        if let stop = book.stopAfterPage, pageIndex + 1 >= stop {
            pause()
            message = "Stopped after page \(stop)."
            setStopPage(nil)
            return
        }
        guard pageIndex + 1 < pageCount else {
            pause()
            message = "That's the end of the book."
            return
        }
        Task {
            await load(page: pageIndex + 1, sentence: 0)
            speakCurrent()
        }
    }

    // MARK: - Speech

    private func speakCurrent() {
        guard isPlaying, !isLoadingPage, current == nil else { return }
        guard sentenceIndex < content.sentences.count else { advancePage(); return }
        let u = AVSpeechUtterance(string: content.sentence(sentenceIndex))
        u.rate = Self.rate(for: speed)
        u.voice = voice
        u.postUtteranceDelay = content.paragraphEnds.contains(sentenceIndex) ? 0.35 : 0.05
        current = u
        utteranceStart = Date()
        synth.speak(u)
        savePosition()
    }

    private func stopSpeech() {
        current = nil
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
    }

    private func finished(_ u: AVSpeechUtterance) {
        guard u === current, isPlaying else { return }
        let elapsed = Date().timeIntervalSince(utteranceStart) - u.postUtteranceDelay
        let chars = Double(u.speechString.count)
        if chars > 25, elapsed > 0.5 {
            let measured = chars / elapsed
            charsPerSecond = charsPerSecond.map { $0 * 0.8 + measured * 0.2 } ?? measured
        }
        if let end = sleepEnd, Date() >= end {
            sleepEnd = nil
            sentenceIndex += 1
            pause()
            savePosition()
            message = "Sleep timer ended. Tap play to keep going."
            return
        }
        current = nil
        sentenceIndex += 1
        speakCurrent()
    }

    private func settingsChanged() {
        charsPerSecond = nil
        guard isPlaying else { return }
        stopSpeech()
        speakCurrent()
    }

    private var voice: AVSpeechSynthesisVoice? {
        if let id = voiceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return Self.availableVoices.first
    }

    /// Voices for the phone's language (plus English), best quality first.
    static var availableVoices: [AVSpeechSynthesisVoice] {
        let lang = String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) || $0.language.hasPrefix("en") }
            .filter { v in
                if #available(iOS 17.0, *) { return !v.voiceTraits.contains(.isNoveltyVoice) }
                return true
            }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                if $0.language.hasPrefix(lang) != $1.language.hasPrefix(lang) { return $0.language.hasPrefix(lang) }
                return $0.name < $1.name
            }
    }

    /// Maps a 0.5×–3× speed onto AVSpeech's 0–1 rate, where 0.5 is normal speech.
    static func rate(for speed: Double) -> Float {
        let base = Double(AVSpeechUtteranceDefaultSpeechRate)
        let r = speed <= 1 ? base - (1 - speed) * 0.4 : base + (speed - 1) * 0.25
        return Float(min(max(r, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    // MARK: - Position, lock screen, interruptions

    private func savePosition() {
        book.page = pageIndex
        book.sentence = sentenceIndex
        library.update(book)
    }

    private func updateNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: book.title,
            MPMediaItemPropertyArtist: "Page \(pageIndex + 1) of \(pageCount)",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        let actions: [(MPRemoteCommand, @MainActor (ReaderEngine) -> Void)] = [
            (center.playCommand, { $0.play() }),
            (center.pauseCommand, { $0.pause() }),
            (center.togglePlayPauseCommand, { $0.togglePlay() }),
            (center.nextTrackCommand, { $0.nextSentence() }),
            (center.previousTrackCommand, { $0.previousSentence() }),
        ]
        for (command, action) in actions {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
            commandTargets.append((command, token))
        }
    }

    private func observeAudioSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else { return }
            Task { @MainActor in self?.pause() }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            // Headphones unplugged: stop instead of switching to the speaker.
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            guard raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.pause() }
        })
    }
}
