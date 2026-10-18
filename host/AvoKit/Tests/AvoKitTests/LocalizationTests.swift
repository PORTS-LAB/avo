import Foundation
import Testing
@testable import AvoKit

@Suite struct LocalizationTests {
    /// The catalog is compiled into AvoKit's resource bundle with Indonesian.
    @Test func indonesianShipsWithTheResourceBundle() throws {
        #expect(Bundle.avoKit.bundleURL.lastPathComponent == "AvoKit_AvoKit.bundle")
        let path = try #require(Bundle.avoKit.path(forResource: "id", ofType: "lproj"))
        let indonesian = try #require(Bundle(path: path))
        #expect(String(localized: "Android is not running.", bundle: indonesian) == "Android tidak berjalan.")
        #expect(AvoError.vmNotRunning.errorDescription == "Android is not running.") // tests run in English
    }

    /// Interpolated values keep their format: numbers stay numbers in both languages.
    @Test func interpolationsMatchTheCatalogKeys() throws {
        let path = try #require(Bundle.avoKit.path(forResource: "id", ofType: "lproj"))
        let indonesian = try #require(Bundle(path: path))
        let cores = 8
        #expect(String(localized: "CPU cores must be between 1 and \(cores).", bundle: indonesian)
            == "Jumlah core CPU harus antara 1 dan 8.")
    }
}
