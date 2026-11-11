import UIKit
import XCTest

/// Drives the app with a generated demo library and saves screenshots.
/// CI sets TEST_RUNNER_SCREENSHOT_DIR so the PNGs land on the build machine and are uploaded.
final class ScreenshotTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testLibraryAndReader() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        let firstBook = app.buttons["book-Starfall 1"]
        XCTAssertTrue(firstBook.waitForExistence(timeout: 30), "Demo library did not appear")
        sleep(3) // let covers render
        save(app, "01-library-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        save(app, "02-library-landscape")

        firstBook.tap()
        let page = app.otherElements["reader-page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "Reader did not open")
        sleep(2)
        save(app, "03-reader-cover-with-controls")

        // Turn to the first two-page spread with the right tap zone.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        sleep(2)
        save(app, "04-reader-spread")

        // Hide the controls with a tap in the middle.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        save(app, "05-reader-spread-no-controls")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        save(app, "06-reader-portrait")

        app.buttons["reader-close"].tap()
        XCTAssertTrue(firstBook.waitForExistence(timeout: 10))
        sleep(2)
        save(app, "07-library-continue-reading")
    }

    /// Book Info, the cover editor, the Series view and the hand-off prompt. Runs after
    /// testLibraryAndReader (tests run in name order).
    func testMoreScreens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let book = app.buttons["book-Night Market 2"]
        XCTAssertTrue(book.waitForExistence(timeout: 30), "Demo library did not appear")
        sleep(2)

        // Book Info from the context menu.
        book.press(forDuration: 1.2)
        let infoItem = app.buttons["Book Info"]
        XCTAssertTrue(infoItem.waitForExistence(timeout: 5), "No Book Info in the context menu")
        infoItem.tap()
        let editCover = app.buttons["info-edit-cover"]
        XCTAssertTrue(editCover.waitForExistence(timeout: 10), "Book Info did not open")
        let favorite = app.switches["info-favorite"]
        if favorite.waitForExistence(timeout: 2) { favorite.tap() }
        sleep(1)
        save(app, "08-book-info")

        // The cover editor: switch to 2:3, drag a corner, save.
        editCover.tap()
        let saveButton = app.buttons["cover-save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 15), "Cover editor did not open")
        sleep(2)
        save(app, "09-cover-editor")
        let comic = app.buttons["Comic 2:3"]
        if comic.waitForExistence(timeout: 2) { comic.tap() }
        let corner = app.otherElements["cover-handle-1-1"].firstMatch
        if corner.waitForExistence(timeout: 2) {
            corner.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.3, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        }
        sleep(1)
        save(app, "10-cover-editor-cropped")
        saveButton.tap()
        XCTAssertTrue(editCover.waitForExistence(timeout: 15), "Did not return to Book Info")
        sleep(2)
        save(app, "11-book-info-edited-cover")
        app.buttons["info-done"].tap()
        XCTAssertTrue(editCover.waitForNonExistence(timeout: 10), "Book Info did not close")
        sleep(1)

        // The Series view.
        let seriesRow = app.descendants(matching: .any)["sidebar-Series"].firstMatch
        if seriesRow.waitForExistence(timeout: 5) {
            // The row's label, not its icon, is the reliable tap target.
            let label = app.staticTexts["Series"].firstMatch
            (label.isHittable ? label : seriesRow).tap()
            sleep(2)
            save(app, "12-series")
            let starfall = app.buttons["series-Starfall"]
            if starfall.waitForExistence(timeout: 5) {
                starfall.tap()
                sleep(2)
                save(app, "13-series-starfall")
            }
        }

        // Another device read further: the reader offers to jump there.
        let allBooks = app.descendants(matching: .any)["sidebar-All Books"].firstMatch
        if allBooks.waitForExistence(timeout: 5) {
            let label = app.staticTexts["All Books"].firstMatch
            (label.isHittable ? label : allBooks).tap()
        }
        let harbor = app.buttons["book-Harbor Lights 1"]
        XCTAssertTrue(harbor.waitForExistence(timeout: 10))
        harbor.tap()
        let jump = app.buttons["handoff-jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 15), "No hand-off prompt")
        sleep(1)
        save(app, "14-reader-handoff")
        jump.tap()
        sleep(1)
        let settings = app.buttons["reader-settings"]
        if settings.waitForExistence(timeout: 3) {
            settings.tap()
            sleep(1)
            save(app, "15-reader-settings-menu")
        }
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        // The screen-level capture keeps landscape shots the right way up.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            // Landscape captures carry their rotation as image orientation metadata, which
            // pngData() drops; redrawing bakes the rotation into the pixels.
            let image = upright(screenshot.image)
            try? image.pngData()?.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    private func upright(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
