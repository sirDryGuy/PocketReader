# Pocket Reader

An iPhone app that reads books out loud.

- **Open PDF**: pick a PDF from Files, or share one to Pocket Reader from another app.
- **Scan pages**: the camera finds the page edges and straightens each page. You can reorder, rotate or remove pages, then tap **Make PDF**. The words on each page are recognized on the phone (Apple Vision), and the PDF gets an invisible text layer, so it's searchable in other apps too.
- **Photos**: turns pictures already in your camera roll into a PDF the same way.
- **Reading**: the sentence being read is highlighted, and you can tap any sentence to jump to it. It has speed control from 0.75× to 3×, a sleep timer, and a "stop after page" option. It shows the time left, keeps reading with the screen locked, and has lock-screen and headphone controls. Each book remembers its place.
- Scanned PDFs that have no text layer get read with OCR automatically, one page at a time.

It uses only Apple's built-in frameworks: SwiftUI, PDFKit, VisionKit, Vision, AVFoundation and NaturalLanguage.

## How it gets built

You can't compile iPhone apps on Windows, so GitHub builds it on a Mac in the cloud. Every push to `main` runs `.github/workflows/build.yml`. That workflow generates the Xcode project from `project.yml` with XcodeGen, builds an unsigned app, and attaches `PocketReader.ipa` to a new release on the repo's **Releases** page.

## Installing on your iPhone (free Apple ID)

One-time setup on the PC:

1. Install **Sideloadly** from sideloadly.io. It also needs Apple's **iTunes** and **iCloud** from apple.com (the website versions, not the Microsoft Store ones) for the USB driver.
2. On the iPhone, turn on **Settings › Privacy & Security › Developer Mode** and restart when it asks. The option only shows up after Sideloadly has installed an app once, so do step 3 first and come back here if needed.

Each install:

3. Download `PocketReader.ipa` from the latest release. Plug the iPhone into the PC and tap **Trust** on the phone.
4. Open Sideloadly, drag in the `.ipa`, type your Apple ID, and press **Start**. It signs the app with your Apple ID and installs it.
5. The first time only: on the iPhone go to **Settings › General › VPN & Device Management**, tap your Apple ID and tap **Trust**.

With a free Apple ID, the app stops opening after **7 days**. To renew it, plug in and run Sideloadly again. Your books are kept. With a paid Apple Developer account ($99/year) it lasts a year.

## Better voices

The default iPhone voices sound robotic. For a natural one, open **Settings › Accessibility › Spoken Content › Voices › English**, then download an **Enhanced** or **Premium** voice (for example "Ava (Premium)"). Pick it in Pocket Reader's **⋯ › Voice…** menu.

## Files

| File | What it does |
| --- | --- |
| `PocketReader/PageText.swift` | Gets a page's text (PDF text layer or Vision OCR), puts two-column pages in reading order, drops page numbers and running headers, and splits text into sentences |
| `PocketReader/ReaderEngine.swift` | Speech playback, position saving, sleep timer, time-left estimate, lock-screen controls |
| `PocketReader/PDFMaker.swift` | Scanned pages → searchable PDF |
| `PocketReader/LibraryStore.swift` | Book list, PDF files, cached page text (stored in Application Support) |
| `PocketReader/*View.swift` | Screens |
| `project.yml` | XcodeGen project definition (bundle id, Info.plist keys, background audio) |
