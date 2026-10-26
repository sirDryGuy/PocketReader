import PhotosUI
import SwiftUI
import VisionKit

/// Apple's page scanner: finds the page edges, straightens it, and hands back one image per page.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([ScanPage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([ScanPage]) -> Void
        init(onFinish: @escaping ([ScanPage]) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var pages: [ScanPage] = []
            for i in 0..<scan.pageCount {
                if let page = autoreleasepool(invoking: { ScanPage.make(from: scan.imageOfPage(at: i)) }) {
                    pages.append(page)
                }
            }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish([])
        }
    }
}

/// Review scanned pages (reorder, rotate, remove, add more), name the book, and turn it into a PDF.
struct ComposeView: View {
    var onCreated: (UUID) -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var pages: [ScanPage]
    @State private var title: String
    @State private var scanning = false
    @State private var scannedMore: [ScanPage]?
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var progress: Int?

    init(pages: [ScanPage], onCreated: @escaping (UUID) -> Void) {
        self.onCreated = onCreated
        _pages = State(initialValue: pages)
        _title = State(initialValue: "Scan " + Date().formatted(date: .abbreviated, time: .shortened))
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Title") {
                    TextField("Book title", text: $title)
                }
                Section {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        HStack(spacing: 14) {
                            Image(uiImage: page.thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 64, height: 84)
                                .background(Color(.tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text("Page \(index + 1)")
                            Spacer()
                            Button {
                                if let r = page.rotatedClockwise() { pages[index] = r }
                            } label: {
                                Image(systemName: "rotate.right")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Rotate page \(index + 1)")
                        }
                    }
                    .onMove { pages.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { pages.remove(atOffsets: $0) }
                } header: {
                    Text("\(pages.count) page\(pages.count == 1 ? "" : "s")")
                } footer: {
                    Text("Drag to reorder. The text on each page is recognized on this phone when you make the PDF.")
                }
                Section {
                    Button { scanning = true } label: { Label("Scan more pages", systemImage: "doc.viewfinder") }
                        .disabled(!VNDocumentCameraViewController.isSupported)
                    Button { pickingPhotos = true } label: { Label("Add photos", systemImage: "photo.on.rectangle.angled") }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("New PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Make PDF") { Task { await make() } }
                        .disabled(pages.isEmpty || progress != nil)
                }
            }
            .overlay {
                if let progress {
                    VStack(spacing: 14) {
                        ProgressView(value: Double(progress), total: Double(max(pages.count, 1)))
                        Text(progress < pages.count ? "Reading page \(progress + 1) of \(pages.count)…" : "Saving the PDF…")
                            .font(.callout)
                    }
                    .padding(24)
                    .frame(maxWidth: 300)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .interactiveDismissDisabled(progress != nil)
        }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            pages.append(contentsOf: scannedMore ?? [])
            scannedMore = nil
        }) {
            DocumentScanner { new in
                scannedMore = new
                scanning = false
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, maxSelectionCount: nil,
                      selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data),
                       let page = ScanPage.make(from: image) {
                        pages.append(page)
                    }
                }
            }
        }
    }

    private func make() async {
        progress = 0
        UIApplication.shared.isIdleTimerDisabled = true
        let result = await PDFMaker.make(pages: pages) { i in progress = i }
        UIApplication.shared.isIdleTimerDisabled = false
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let book = library.addPDF(data: result.pdf, title: name.isEmpty ? "Scanned pages" : name, pageTexts: result.texts) {
            onCreated(book.id)
        }
        progress = nil
        dismiss()
    }
}
