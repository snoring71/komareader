# Comic Reader

A native comic and manga reader for iPad (iPadOS 26+, Liquid Glass), built in SwiftUI.

- Your library is any iCloud Drive folder you pick (for example `iCloud Drive/Booklover`). Books
  show up whether or not they are downloaded, and you can download or remove each one from the
  device without touching the file in iCloud.
- Reads CBZ, CBR, CB7, CBT (via the system libarchive), PDF and folders of images.
- App data (covers, reading progress, settings) is stored as plain JSON and JPEG files in
  `iCloud Drive/Comic Reader/`, in an open format documented in [docs/SCHEMA.md](docs/SCHEMA.md),
  so other apps (such as a future Windows version) can share it.

## Layout

| Path | What |
| --- | --- |
| `App/` | SwiftUI app: library sidebar and grid, reader, glass controls |
| `Packages/ComicKit/` | Swift package: `ComicCore` (data format, merge rules), `ArchiveKit` (book formats, image decoding), `LibraryKit` (iCloud scanning, local GRDB index, covers) |
| `UITests/` | UI test that runs the app on a demo library and saves screenshots |
| `project.yml` | XcodeGen definition of the Xcode project |

## Building

On a Mac with Xcode 26:

```sh
brew install xcodegen
xcodegen generate
open ComicReader.xcodeproj
```

Package tests run with `swift test` in `Packages/ComicKit`. Launch the app with the `-demo`
argument to use a generated sample library.

## CI

- **CI** (`.github/workflows/ci.yml`) runs on every push and pull request on a GitHub macOS runner:
  package tests, then the app's UI test on an iPad simulator. Screenshots are attached to the run
  as the `screenshots` artifact.
- **TestFlight** (`.github/workflows/testflight.yml`) archives, signs and uploads a build on every
  push to `main` once the App Store Connect secrets are set (see the comments in the workflow).
