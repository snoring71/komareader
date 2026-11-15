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
        // The first launch on a freshly booted CI simulator is slow (making the demo library and
        // its covers while the simulator settles), and UI queries made meanwhile can time out.
        // Give it time before the first query.
        sleep(20)

        let firstBook = app.buttons["book-Starfall 1"]
        XCTAssertTrue(firstBook.waitForExistence(timeout: 90), "Demo library did not appear")
        sleep(3) // let covers render
        save(app, "01-library-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        save(app, "02-library-landscape")

        firstBook.tap()
        let page = app.otherElements["reader-page"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 20), "Reader did not open")
        sleep(2)
        // A book opened for the first time waits on its cover until the reader moves on.
        let intro = app.descendants(matching: .any)["reader-cover-intro"].firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 5), "No cover intro on a first open")
        save(app, "03-reader-cover-intro")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(intro.waitForNonExistence(timeout: 5), "The cover intro did not give way to page 1")
        sleep(1)
        // Back from page 1 returns to the cover; forward leaves it again.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(intro.waitForExistence(timeout: 5), "Going back from page 1 did not show the cover")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(intro.waitForNonExistence(timeout: 5), "The cover did not give way to page 1 again")
        sleep(1)
        // The controls start hidden; a tap in the middle shows them.
        let menuBar = app.descendants(matching: .any)["reader-menu-bar"].firstMatch
        XCTAssertFalse(menuBar.exists, "Controls showed without a tap")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menuBar.waitForExistence(timeout: 3), "A tap in the middle did not show the controls")
        sleep(1)
        save(app, "03a-reader-cover-with-controls")

        // Select Text (Live Text), where the simulator supports it.
        let selectText = app.buttons["reader-select-text"]
        if selectText.exists {
            selectText.tap()
            // The first Live Text run on a fresh simulator loads its models, which can take a while.
            let copyAll = app.buttons["reader-copy-text"]
            for _ in 0..<30 where !(copyAll.exists && copyAll.isEnabled) { sleep(1) }
            sleep(1)
            save(app, "03b-reader-select-text")
            let done = app.buttons["reader-text-done"]
            if done.waitForExistence(timeout: 3) { done.tap() }
            sleep(1)
        }

        // Turn to the first two-page spread with the right tap zone; that puts the controls away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(menuBar.waitForNonExistence(timeout: 3), "Turning the page did not hide the controls")
        sleep(2)
        save(app, "04-reader-spread")

        // Show the controls again with a tap in the middle.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        save(app, "05-reader-spread-controls")

        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        save(app, "06-reader-portrait")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons["reader-close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
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
        XCTAssertTrue(book.waitForExistence(timeout: 90), "Demo library did not appear")
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
        sleep(3)
        save(app, "11b-library-edited-cover")
        XCTAssertTrue(editCover.waitForNonExistence(timeout: 10), "Book Info did not close")

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
            // The row's label, not its icon, is the reliable tap target (the page title here is "Starfall").
            let label = app.staticTexts["All Books"].firstMatch
            (label.isHittable ? label : allBooks).tap()
        }
        // It is in Continue Reading too (the seeded progress), so take the first.
        let harbor = app.buttons["book-Harbor Lights 1"].firstMatch
        XCTAssertTrue(harbor.waitForExistence(timeout: 10))
        harbor.tap()
        let jump = app.buttons["handoff-jump"]
        XCTAssertTrue(jump.waitForExistence(timeout: 15), "No hand-off prompt")
        sleep(1)
        save(app, "14-reader-handoff")
        jump.tap()
        sleep(1)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let bar = app.descendants(matching: .any)["reader-menu-bar"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "No menu bar in the reader")
        save(app, "15-reader-menu-bar")
        let layout = app.buttons["reader-bar-layout"]
        if layout.waitForExistence(timeout: 3) {
            layout.tap()
            sleep(1)
            save(app, "15b-reader-page-layout")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
            sleep(1)
        }
        let adjust = app.buttons["reader-bar-adjust"]
        if adjust.waitForExistence(timeout: 3) {
            adjust.tap()
            let contrast = app.sliders["adjust-contrast"]
            if contrast.waitForExistence(timeout: 3) { contrast.adjust(toNormalizedSliderPosition: 0.85) }
            let grain = app.sliders["adjust-grain"]
            if grain.waitForExistence(timeout: 3) { grain.adjust(toNormalizedSliderPosition: 0.7) }
            sleep(2)
            save(app, "16-reader-adjustments")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
            sleep(1)
        }
        let more = app.buttons["reader-bar-more"]
        if more.waitForExistence(timeout: 3) {
            more.tap()
            sleep(1)
            save(app, "17-reader-more")
            // Use as Defaults asks first.
            let useDefaults = app.buttons["reader-use-defaults"]
            if useDefaults.waitForExistence(timeout: 3) {
                useDefaults.tap()
                let cancel = app.buttons["reader-use-defaults-cancel"]
                XCTAssertTrue(cancel.waitForExistence(timeout: 3), "Use as Defaults did not ask first")
                sleep(1)
                save(app, "17b-reader-use-defaults-confirm")
                cancel.tap()
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
            sleep(1)
        }

        // The cover button in the page bar goes back to the cover; a tap forward returns.
        let showCover = app.buttons["reader-show-cover"]
        if showCover.waitForExistence(timeout: 3) {
            showCover.tap()
            sleep(1)
            save(app, "17c-reader-cover-from-page-bar")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            sleep(1)
        }

        // A swipe up on the page closes the book.
        let readerPage = app.otherElements["reader-page"].firstMatch
        readerPage.swipeUp(velocity: .fast)
        XCTAssertTrue(readerPage.waitForNonExistence(timeout: 10), "Swiping up did not close the book")
        XCTAssertTrue(harbor.waitForExistence(timeout: 10))
        sleep(1)
        save(app, "18-library-after-swipe-up")
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
