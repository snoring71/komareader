# Comic Reader

A native comic and manga reader for iPad (iPadOS 26+, Liquid Glass), built in SwiftUI.

- Your library is any iCloud Drive folder you pick (for example `iCloud Drive/Booklover`). Books
  show up whether or not they are downloaded, and you can download or remove each one from the
  device without touching the file in iCloud.
- Reads CBZ, CBR, CB7, CBT (via the system libarchive), PDF and folders of images, with fit to
  screen, width or height, page thumbnails on the scrubber, and an offer to jump ahead when
  another device has read further.
- Reader settings per book, with defaults for every book in Settings › Book Defaults: reading
  direction, single or two pages in portrait and in landscape, fit, background (black, gray,
  white, a colour you pick, or matched to the page), a binding shadow between two pages, splitting
  images that hold two pages, and a crop for the whole book (or one for odd and one for even pages)
  to trim wide margins.
- Browse by folder, series (worked out from file names until metadata editing arrives), status,
  Favorites and Bookmarked, with a letter index and pinch to resize the grid.
- Edit any book's cover (pick a page, crop, rotate) from Book Info. Covers for books that are only
  in iCloud are made in the background, one book at a time, and pause on Low Data Mode, Low Power
  Mode, a low battery or off Wi-Fi (see Settings).
- A Quick Look extension shows comic covers in the Files app.
- App data (covers, reading progress, settings) is stored as plain JSON and JPEG files in
  `iCloud Drive/Comic Reader/`, in an open format documented in [docs/SCHEMA.md](docs/SCHEMA.md),
  so other apps (such as a future Windows version) can share it.

## Layout

| Path | What |
| --- | --- |
| `App/` | SwiftUI app: library sidebar and grid, reader, glass controls |
| `Packages/ComicKit/` | Swift package: `ComicCore` (data format, merge rules), `ArchiveKit` (book formats, image decoding), `LibraryKit` (iCloud scanning, local GRDB index, covers) |
| `ThumbnailExtension/` | Quick Look thumbnail extension for comic archives in Files |
| `UITests/` | UI test that runs the app on a demo library and saves screenshots |
| `project.yml` | XcodeGen definition of the Xcode project |

## Building

On a Mac with Xcode 26:

```sh
brew install xcodegen
xcodegen generate
open ComicReader.xcodeproj
```

To run on a real iPad with a free Apple ID (no paid developer account), generate with
`FREE_ACCOUNT=1 xcodegen generate`. That leaves out iCloud, which free accounts cannot sign, so the
app keeps its data on the device instead of syncing it; picking a comics folder in iCloud Drive
still works. Free-account builds expire after 7 days. Run plain `xcodegen generate` to turn iCloud
back on.

Package tests run with `swift test` in `Packages/ComicKit`. Launch the app with the `-demo`
argument to use a generated sample library; add `-demoCount 10000` for 10,000 extra small books
to test the grid at scale (Product › Scheme › Edit Scheme › Arguments).

## CI

- **CI** (`.github/workflows/ci.yml`) runs on every push and pull request on a GitHub macOS runner:
  package tests, then the app's UI test on an iPad simulator. Screenshots are attached to the run
  as the `screenshots` artifact.
- **TestFlight** (`.github/workflows/testflight.yml`) archives, signs and uploads a build on every
  push to `main` once the App Store Connect secrets are set (see the comments in the workflow).
