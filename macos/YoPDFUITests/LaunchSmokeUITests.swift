import XCTest

@MainActor
final class LaunchSmokeUITests: XCTestCase {

    func testAppLaunchesAndExitsRepeatedly() throws {
        let applicationURL = try applicationURL()

        for iteration in 1...3 {
            let app = XCUIApplication(url: applicationURL)
            app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
            app.launch()

            XCTAssertTrue(
                app.wait(for: .runningForeground, timeout: 20),
                "YoPDF should reach the foreground on launch iteration \(iteration)."
            )
            XCTAssertTrue(
                app.windows.firstMatch.waitForExistence(timeout: 10),
                "YoPDF should create its workspace window on launch iteration \(iteration)."
            )

            app.terminate()
            XCTAssertTrue(
                app.wait(for: .notRunning, timeout: 10),
                "YoPDF should exit on launch iteration \(iteration)."
            )
        }
    }

    private func applicationURL() throws -> URL {
        var directory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("YoPDF.app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        throw NSError(domain: "LaunchSmokeUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not find YoPDF.app beside the test runner."
        ])
    }
}
