import CoreTransferable
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// A book's PDF for the share sheet. The copy named after the book is made only when someone shares it.
struct BookPDF: Transferable {
    let source: URL
    let title: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            SentTransferredFile(try item.namedCopy())
        }
    }

    func namedCopy() throws -> URL {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent((safe.isEmpty ? "Book" : safe) + ".pdf")
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }
}

struct Book: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var pageCount: Int
    var added: Date
    var lastOpened: Date?
    /// Where reading left off (0-based page, sentence on that page).
    var page: Int = 0
    var sentence: Int = 0
    /// Optional last page to read, 1-based as shown to the reader.
    var stopAfterPage: Int?
}

enum LibraryError: LocalizedError {
    case unreadable(String)
    case locked(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "\(name) isn't a PDF this phone can open."
        case .locked(let name): return "\(name) is password-protected. Remove the password and import it again."
        }
    }
}

/// Books live in Application Support: one PDF per book, a JSON index, and a cache of each book's page text.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var books: [Book] = []

    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init() {
        let fm = FileManager.default
        root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PocketReader", isDirectory: true)
        for dir in ["Books", "Text"] {
            try? fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([Book].self, from: data) {
            books = saved
        }
        if !UserDefaults.standard.bool(forKey: "welcomeAdded") {
            UserDefaults.standard.set(true, forKey: "welcomeAdded")
            if let data = WelcomeBook.makePDF() {
                _ = addPDF(data: data, title: "Welcome to Pocket Reader", pageTexts: [:])
            }
        }
    }

    var sortedBooks: [Book] {
        books.sorted { ($0.lastOpened ?? $0.added) > ($1.lastOpened ?? $1.added) }
    }

    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    func pdfURL(_ id: UUID) -> URL { root.appendingPathComponent("Books/\(id.uuidString).pdf") }
    private func textURL(_ id: UUID) -> URL { root.appendingPathComponent("Text/\(id.uuidString).json") }

    func document(for book: Book) -> PDFDocument? { PDFDocument(url: pdfURL(book.id)) }

    func exportable(_ book: Book) -> BookPDF { BookPDF(source: pdfURL(book.id), title: book.title) }

    @discardableResult
    func importPDF(from url: URL) throws -> Book {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        let id = UUID()
        let dest = pdfURL(id)
        try FileManager.default.copyItem(at: url, to: dest)
        guard let doc = PDFDocument(url: dest) else {
            try? FileManager.default.removeItem(at: dest)
            throw LibraryError.unreadable(name)
        }
        if doc.isLocked && !doc.unlock(withPassword: "") {
            try? FileManager.default.removeItem(at: dest)
            throw LibraryError.locked(name)
        }
        let book = Book(id: id, title: name, pageCount: doc.pageCount, added: Date())
        books.append(book)
        save()
        return book
    }

    @discardableResult
    func addPDF(data: Data, title: String, pageTexts: [Int: String]) -> Book? {
        let id = UUID()
        do { try data.write(to: pdfURL(id), options: .atomic) } catch { return nil }
        let count = PDFDocument(data: data)?.pageCount ?? 0
        let book = Book(id: id, title: title, pageCount: count, added: Date())
        books.append(book)
        if !pageTexts.isEmpty { saveTexts(pageTexts, for: id) }
        save()
        return book
    }

    func update(_ book: Book) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i] = book
        save()
    }

    func rename(_ book: Book, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, var b = self.book(book.id) else { return }
        b.title = t
        update(b)
    }

    func delete(_ book: Book) {
        books.removeAll { $0.id == book.id }
        try? FileManager.default.removeItem(at: pdfURL(book.id))
        try? FileManager.default.removeItem(at: textURL(book.id))
        save()
    }

    func loadTexts(for id: UUID) -> [Int: String] {
        guard let data = try? Data(contentsOf: textURL(id)),
              let texts = try? JSONDecoder().decode([Int: String].self, from: data) else { return [:] }
        return texts
    }

    func saveTexts(_ texts: [Int: String], for id: UUID) {
        if let data = try? JSONEncoder().encode(texts) {
            try? data.write(to: textURL(id), options: .atomic)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(books) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
