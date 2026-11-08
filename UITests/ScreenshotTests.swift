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
            var image = screenshot.image
            // The simulator captures in portrait; turn landscape shots the right way up.
            if XCUIDevice.shared.orientation.isLandscape { image = rotatedCounterClockwise(image) }
            try? image.pngData()?.write(to: url.appendingPathComponent("\(name).png"))
        }
    }

    private func rotatedCounterClockwise(_ image: UIImage) -> UIImage {
        let size = CGSize(width: image.size.height, height: image.size.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: 0, y: size.height)
            ctx.cgContext.rotate(by: -.pi / 2)
            image.draw(at: .zero)
        }
    }
}
