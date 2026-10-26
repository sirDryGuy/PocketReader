import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct ComposerDraft: Identifiable {
    let id = UUID()
    var pages: [ScanPage]
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var path: [UUID] = []
    @State private var importing = false
    @State private var scanning = false
    @State private var scanned: [ScanPage]?
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var draft: ComposerDraft?
    @State private var createdBook: UUID?
    @State private var renaming: Book?
    @State private var newTitle = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    HStack(spacing: 12) {
                        ActionTile(title: "Scan pages", subtitle: "Camera", symbol: "doc.viewfinder") { startScan() }
                        ActionTile(title: "Photos", subtitle: "Make a PDF", symbol: "photo.on.rectangle.angled") { pickingPhotos = true }
                        ActionTile(title: "Open PDF", subtitle: "From Files", symbol: "folder") { importing = true }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section("Your books") {
                    if library.books.isEmpty {
                        Text("Books you scan or open show up here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(library.sortedBooks) { book in
                        NavigationLink(value: book.id) { BookRow(book: book) }
                            .swipeActions {
                                Button(role: .destructive) { library.delete(book) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button { newTitle = book.title; renaming = book } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                ShareLink(item: library.exportable(book), preview: SharePreview(book.title)) {
                                    Label("Share or save PDF", systemImage: "square.and.arrow.up")
                                }
                                Button(role: .destructive) { library.delete(book) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .navigationTitle("Pocket Reader")
            .navigationDestination(for: UUID.self) { id in
                if let book = library.book(id) {
                    ReaderScreen(book: book)
                }
            }
            .overlay {
                if loadingPhotos {
                    ProgressView("Loading photos…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): errorText = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: nil,
                      selectionBehavior: .ordered, matching: .images,
                      preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            if let pages = scanned, !pages.isEmpty { draft = ComposerDraft(pages: pages) }
            scanned = nil
        }) {
            DocumentScanner { pages in
                scanned = pages
                scanning = false
            }
            .ignoresSafeArea()
        }
        .sheet(item: $draft, onDismiss: {
            if let id = createdBook { path = [id] }
            createdBook = nil
        }) { d in
            ComposeView(pages: d.pages) { id in createdBook = id }
                .environmentObject(library)
        }
        .alert("Rename book", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Save") { if let b = renaming { library.rename(b, to: newTitle) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't add that", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
        .onOpenURL { url in importFiles([url]) }
    }

    private func startScan() {
        if VNDocumentCameraViewController.isSupported {
            scanning = true
        } else {
            errorText = "This device has no camera scanner. Use Photos to pick pictures of pages instead."
        }
    }

    private func importFiles(_ urls: [URL]) {
        var last: Book?
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            do { last = try library.importPDF(from: url) } catch { errorText = error.localizedDescription }
        }
        if urls.count == 1, let last { path = [last.id] }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        loadingPhotos = true
        var pages: [ScanPage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data),
               let page = ScanPage.make(from: image) {
                pages.append(page)
            }
        }
        loadingPhotos = false
        if pages.isEmpty {
            errorText = "Those photos couldn't be opened."
        } else {
            draft = ComposerDraft(pages: pages)
        }
    }
}

private struct ActionTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15))
                Image(systemName: "book.closed.fill").foregroundStyle(Color.accentColor)
            }
            .frame(width: 40, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(.body.weight(.medium)).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(book.page + 1), total: Double(max(book.pageCount, 1)))
                    .tint(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let place = book.lastOpened == nil ? "\(book.pageCount) pages" : "Page \(book.page + 1) of \(book.pageCount)"
        guard let opened = book.lastOpened else { return place }
        return place + " · " + opened.formatted(.relative(presentation: .named))
    }
}

/// Opens the book's PDF, or explains why it couldn't.
struct ReaderScreen: View {
    let book: Book
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if let doc = library.document(for: book) {
            ReaderView(book: book, document: doc, library: library)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text("This book's PDF is missing or damaged. Delete it and add it again.")
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}
