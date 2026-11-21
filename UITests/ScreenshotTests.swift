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

        // In landscape the All Books heading pushes this book's row to the bottom edge, where a
        // tap lands under the Resume button or off screen. Bring it up into view first.
        if !firstBook.isHittable || firstBook.frame.maxY > app.frame.maxY - 120 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.4)))
            sleep(1)
        }
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

    /// The sidebar floats over the library and starts hidden: open it with its toolbar button.
    private func openSidebar(_ app: XCUIApplication) {
        let toggle = app.buttons["sidebar-toggle"].firstMatch
        if toggle.waitForExistence(timeout: 5) {
            toggle.tap()
            sleep(1)
        }
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
        if !infoItem.waitForExistence(timeout: 5) {
            // Show what is on screen instead, to see why.
            save(app, "07a-no-book-menu")
            print(app.debugDescription)
        }
        XCTAssertTrue(infoItem.exists, "No Book Info in the context menu")
        sleep(1)
        // The icon row and cover lifted together, with no grey box around them (#71).
        save(app, "07b-book-long-press")
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
        openSidebar(app)
        save(app, "11c-sidebar")
        let seriesRow = app.descendants(matching: .any)["sidebar-Series"].firstMatch
        if seriesRow.waitForExistence(timeout: 5) {
            // The row's label, not its icon, is the reliable tap target.
            let label = app.staticTexts["Series"].firstMatch
            (label.isHittable ? label : seriesRow).tap()
            sleep(2)
            save(app, "12-series")
            let starfall = app.buttons["series-Starfall"]
            if starfall.waitForExistence(timeout: 5) {
                // Pin the series to the sidebar from its long-press menu (#72).
                starfall.press(forDuration: 1.2)
                let pin = app.buttons["Pin to Sidebar"]
                XCTAssertTrue(pin.waitForExistence(timeout: 5), "No Pin to Sidebar on a series")
                sleep(1)
                save(app, "12a-series-long-press")
                pin.tap()
                sleep(1)
                openSidebar(app)
                XCTAssertTrue(app.descendants(matching: .any)["sidebar-Starfall"].firstMatch.waitForExistence(timeout: 5),
                              "The pinned series is not in the sidebar")
                save(app, "12b-sidebar-pinned-series")
                let close = app.buttons["sidebar-close"].firstMatch
                if close.waitForExistence(timeout: 3) { close.tap() }
                sleep(1)
                starfall.tap()
                sleep(2)
                save(app, "13-series-starfall")
            }
        }

        // The folder browser, and one folder.
        openSidebar(app)
        let foldersRow = app.descendants(matching: .any)["sidebar-Folders"].firstMatch
        if foldersRow.waitForExistence(timeout: 5) {
            let label = app.staticTexts["Folders"].firstMatch
            (label.isHittable ? label : foldersRow).tap()
            sleep(2)
            save(app, "13b-folders")
            let folder = app.buttons["folder-Night Market"]
            if folder.waitForExistence(timeout: 5) {
                folder.tap()
                sleep(2)
                save(app, "13c-folder-night-market")
            }
        }

        // Another device read further: the reader offers to jump there.
        openSidebar(app)
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

        // Bookmark the page, then see it in the Bookmarks list (#54).
        let bookmark = app.buttons["reader-bar-bookmark"]
        if bookmark.waitForExistence(timeout: 3) {
            bookmark.tap()
            sleep(1)
            XCTAssertTrue(app.buttons["Page Bookmarked, on"].waitForExistence(timeout: 3), "The page was not bookmarked")
            let list = app.buttons["reader-bar-bookmarks"]
            if list.waitForExistence(timeout: 3) {
                list.tap()
                XCTAssertTrue(app.descendants(matching: .any)["reader-bookmarks-panel"].firstMatch.waitForExistence(timeout: 3), "No Bookmarks list")
                sleep(1)
                save(app, "17d-reader-bookmarks")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)).tap()
                sleep(1)
            }
        }

        // Share Page in the top bar (#60, #92): the share sheet, or the left/right question first.
        let share = app.buttons["reader-share-page"].firstMatch
        if share.waitForExistence(timeout: 3) {
            share.tap()
            sleep(2)
            let left = app.buttons["reader-share-left"].firstMatch
            if left.exists {
                save(app, "17e-reader-share-which-page")
                left.tap()
                sleep(2)
            }
            save(app, "17f-reader-share-sheet")
            // Out of the share sheet, however many taps that takes.
            let shareSheet = app.otherElements["ActivityListView"].firstMatch
            for _ in 0..<4 where shareSheet.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).tap()
                sleep(1)
            }
            XCTAssertFalse(shareSheet.exists, "The share sheet did not close")
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

        save(app, "17g-reader-before-swipe-up")
        // A swipe up on the page closes the book.
        let readerPage = app.otherElements["reader-page"].firstMatch
        readerPage.swipeUp(velocity: .fast)
        XCTAssertTrue(readerPage.waitForNonExistence(timeout: 10), "Swiping up did not close the book")
        XCTAssertTrue(harbor.waitForExistence(timeout: 10))
        sleep(1)
        save(app, "18-library-after-swipe-up")
    }

    /// Cover Info on the covers, then Select mode and its actions. Runs last (name order).
    /// Past searches show in a glass box under the field and can be removed one by one (#109).
    func testSearchHistory() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()

        XCTAssertTrue(app.buttons["book-Night Market 2"].waitForExistence(timeout: 90), "Demo library did not appear")
        sleep(2)

        let field = app.searchFields["Search books"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field")
        field.tap()
        field.typeText("Night\n")
        sleep(1)
        // Empty the field while still searching: the history box shows.
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))

        let term = app.descendants(matching: .any)["search-history-term-Night"].firstMatch
        XCTAssertTrue(term.waitForExistence(timeout: 5), "Search not in the history box")
        sleep(1)
        save(app, "21-search-history")

        app.buttons["search-history-remove-Night"].firstMatch.tap()
        XCTAssertTrue(term.waitForNonExistence(timeout: 5), "X did not remove the search")
    }

    func testSelectAndCoverInfo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft

        let book = app.buttons["book-Night Market 2"]
        XCTAssertTrue(book.waitForExistence(timeout: 90), "Demo library did not appear")
        sleep(2)

        let info = app.buttons["library-cover-info"].firstMatch
        XCTAssertTrue(info.waitForExistence(timeout: 5), "No Cover Info button")
        info.tap()
        sleep(2)
        save(app, "20-library-cover-info")
        info.tap()
        sleep(1)

        app.buttons["library-options"].firstMatch.tap()
        let select = app.buttons["library-select"].firstMatch
        XCTAssertTrue(select.waitForExistence(timeout: 5), "No Select in the options menu")
        select.tap()
        let done = app.buttons["selection-done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Select mode did not start")
        sleep(1)
        save(app, "21-library-select-mode")
        XCTAssertTrue(done.exists, "Select mode ended by itself")
        book.tap()
        let other = app.buttons["book-Starfall 1"].firstMatch
        if other.waitForExistence(timeout: 2) { other.tap() }
        sleep(1)
        save(app, "22-library-select")
        XCTAssertFalse(app.otherElements["reader-page"].firstMatch.exists, "A tap in Select mode opened the book")

        let actions = app.buttons["selection-actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5))

        // Tags… for the selected books (#64): the sheet keeps the selection when it closes.
        actions.tap()
        let tags = app.buttons["selection-tags"].firstMatch
        XCTAssertTrue(tags.waitForExistence(timeout: 5), "No Tags… in the Actions menu")
        tags.tap()
        let tagsDone = app.buttons["tags-done"].firstMatch
        XCTAssertTrue(tagsDone.waitForExistence(timeout: 5), "The tag editor did not open")
        let field = app.textFields["tags-new"].firstMatch
        if field.waitForExistence(timeout: 2) {
            field.tap()
            field.typeText("Shelf\n")
        }
        sleep(1)
        save(app, "22b-library-select-tags")
        tagsDone.tap()
        XCTAssertTrue(tagsDone.waitForNonExistence(timeout: 5), "The tag editor did not close")
        XCTAssertTrue(done.exists, "Closing Tags ended Select mode")

        actions.tap()
        // Earlier runs may have marked these books already.
        let favorite = app.buttons.matching(NSPredicate(format: "label IN %@", ["Favorite", "Remove from Favorites"])).firstMatch
        if favorite.waitForExistence(timeout: 3) {
            sleep(1)
            save(app, "23-library-select-actions")
            favorite.tap()
        }
        XCTAssertTrue(done.waitForNonExistence(timeout: 5), "Select mode did not end after an action")
        sleep(1)
        save(app, "24-library-after-select")
    }

    /// Each library view keeps its scroll position when the user goes to another view and
    /// back (#105).
    func testScrollPositionIsKept() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoCount", "200"]
        app.launch()

        let first = app.buttons["book-Night Market 2"]
        XCTAssertTrue(first.waitForExistence(timeout: 90), "Demo library did not appear")
        sleep(2)

        // Scroll All Books well down, to a book far from the top.
        let target = app.buttons["book-Series 12 1"]
        // A drag on the screen rather than `scrollViews.firstMatch`, which finds the hidden
        // sidebar's list first.
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        for _ in 0..<25 where !(target.exists && target.isHittable) {
            low.press(forDuration: 0.05, thenDragTo: high)
        }
        XCTAssertTrue(target.isHittable, "Could not scroll to the test book")
        sleep(1)
        save(app, "25-scroll-before")

        // Away to another sidebar item, and back.
        go(to: "Favorites", in: app)
        sleep(1)
        go(to: "All Books", in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "All Books did not come back where it was")
        sleep(1)
        save(app, "26-scroll-after")
        XCTAssertTrue(target.isHittable, "All Books did not come back where it was")
        XCTAssertFalse(first.isHittable, "All Books went back to the top")

        // A search from down the page shows its results on screen, and clearing it goes back
        // to the same spot.
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No search field")
        field.tap()
        field.typeText("Starfall")
        let result = app.buttons["book-Starfall 1"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "No search results")
        sleep(1)
        save(app, "27-scroll-search-results")
        XCTAssertTrue(result.isHittable, "The search results are off screen")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        XCTAssertTrue(target.waitForExistence(timeout: 5), "Clearing the search did not go back")
        sleep(1)
        save(app, "28-scroll-after-search")
        XCTAssertTrue(target.isHittable, "Clearing the search did not go back to the same spot")
    }

    /// Picks a sidebar row by its label.
    private func go(to row: String, in app: XCUIApplication) {
        openSidebar(app)
        let item = app.descendants(matching: .any)["sidebar-\(row)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "No \(row) in the sidebar")
        let label = app.staticTexts[row].firstMatch
        (label.isHittable ? label : item).tap()
        sleep(2)
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
