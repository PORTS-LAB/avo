import CoreGraphics
import Foundation
import Testing
@testable import AvoKit

@Suite struct ScreenTextLayoutTests {
    private func line(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat = 40) -> ScreenTextLayout.Line {
        ScreenTextLayout.Line(text: text, rect: CGRect(x: x, y: y, width: width, height: height))
    }

    @Test func paragraphLinesFormOneBlock() {
        let blocks = ScreenTextLayout.blocks([
            line("only the second", x: 40, y: 152, width: 600),
            line("This sentence goes on", x: 40, y: 100, width: 620),
            line("line.", x: 40, y: 204, width: 90),
        ])
        #expect(blocks.count == 1)
        #expect(blocks.first?.text == "This sentence goes on only the second line.")
        #expect(blocks.first?.rect == CGRect(x: 40, y: 100, width: 620, height: 144))
        #expect(blocks.first?.lineHeight == 40)
        #expect(blocks.first?.alignment == .leading)
    }

    @Test func listRowsAndSideBySideLabelsStayApart() {
        let blocks = ScreenTextLayout.blocks([
            // Rows of a list: further apart than lines of a paragraph.
            line("Wi-Fi", x: 40, y: 100, width: 120),
            line("Bluetooth", x: 40, y: 196, width: 200),
            // Tabs on one row.
            line("Home", x: 40, y: 900, width: 100),
            line("Search", x: 400, y: 900, width: 140),
        ])
        #expect(blocks.map(\.text) == ["Wi-Fi", "Bluetooth", "Home", "Search"])
    }

    @Test func aHeadingDoesNotJoinTheTextUnderIt() {
        let blocks = ScreenTextLayout.blocks([
            line("Welcome", x: 40, y: 100, width: 300, height: 80),
            line("Sign in to continue", x: 40, y: 190, width: 420, height: 40),
        ])
        #expect(blocks.count == 2)
    }

    @Test func centeredLinesAreCentered() {
        let blocks = ScreenTextLayout.blocks([
            line("Are you sure you want", x: 100, y: 100, width: 500),
            line("to quit?", x: 270, y: 150, width: 160),
        ])
        #expect(blocks.count == 1)
        #expect(blocks.first?.alignment == .center)
    }

    @Test func aLabelMayWidenUpToTheNextTextOrTheEdge() {
        let blocks = ScreenTextLayout.blocks([
            line("Settings", x: 40, y: 100, width: 160),
            line("Home", x: 40, y: 900, width: 100),
            line("Search", x: 200, y: 900, width: 140),
            line("Notifications", x: 800, y: 300, width: 260),
        ])
        let room = { (text: String) in
            ScreenTextLayout.room(after: blocks.firstIndex { $0.text == text }!, in: blocks, frameWidth: 1080)
        }
        #expect(room("Settings") == 80) // half its width
        #expect(room("Home") == 40) // up to "Search", half a line before it
        #expect(room("Notifications") == 0) // at the edge already
        #expect(ScreenTextLayout.room(after: 9, in: blocks, frameWidth: 1080) == 0)
    }

    @Test func linesJoinTheWayTheScriptIsWritten() {
        #expect(ScreenTextLayout.joined(["Press the button", " to start "]) == "Press the button to start")
        #expect(ScreenTextLayout.joined(["The trans-", "lation"]) == "The translation")
        #expect(ScreenTextLayout.joined(["Wi-", "Fi"]) == "Wi-Fi") // a compound keeps its hyphen
        #expect(ScreenTextLayout.joined(["ゲームを", "始める"]) == "ゲームを始める")
        #expect(ScreenTextLayout.joined(["设置", "Wi-Fi"]) == "设置Wi-Fi")
        #expect(ScreenTextLayout.joined(["", "  ", "OK"]) == "OK")
    }

    @Test func onlyTextWithLettersIsTranslated() {
        #expect(ScreenTextLayout.hasLetters("Level 3"))
        #expect(ScreenTextLayout.hasLetters("設定"))
        #expect(!ScreenTextLayout.hasLetters("12:30"))
        #expect(!ScreenTextLayout.hasLetters("99% · $4.99"))
    }

    @Test func theSameTextReadTwiceIsRecognized() {
        // What Vision read for one post title and one shop name as the feed scrolled.
        #expect(ScreenTextLayout.sameTextRead("mantap gado\" nye", "mantap gado\" nye S"))
        #expect(ScreenTextLayout.sameTextRead("mantap gado\" nye", "Mantap gado\" nye &"))
        #expect(ScreenTextLayout.sameTextRead("Lagi Rice \"Sushi Ala R...", "T Lagi Rice \"Sushi Ala R..."))
        #expect(ScreenTextLayout.sameTextRead("Nona Shalsa M...", "Nona Shalsa M.…."))
        // Other text: too different, other numbers, or too short to tell.
        #expect(!ScreenTextLayout.sameTextRead("mantap gado\" nye", "mantap gadoỊồịnye"))
        #expect(!ScreenTextLayout.sameTextRead("Pesanan saya", "Pesanan baru"))
        #expect(!ScreenTextLayout.sameTextRead("Kirim pesan", "Kirim pesanan"))
        #expect(!ScreenTextLayout.sameTextRead("3 komentar", "4 komentar"))
        #expect(!ScreenTextLayout.sameTextRead("Masuk", "Masuk."))
        #expect(!ScreenTextLayout.sameTextRead("", ""))
    }

    @Test func aTranslationThatChangesNothingIsNotShown() {
        #expect(ScreenTextLayout.sameText("Netflix", " netflix "))
        #expect(ScreenTextLayout.sameText("Café", "Cafe"))
        #expect(!ScreenTextLayout.sameText("Settings", "Pengaturan"))
    }

    @Test func fontSizeIsTheLargestThatFits() {
        // Fits up to 13.2 points.
        let size = ScreenTextLayout.fittedSize(minimum: 6, maximum: 30) { $0 <= 13.2 }
        #expect(size <= 13.2 && size > 12.6)
        #expect(ScreenTextLayout.fittedSize(minimum: 6, maximum: 30) { _ in true } == 30)
        #expect(ScreenTextLayout.fittedSize(minimum: 6, maximum: 30) { _ in false } == 6)
        // Text smaller than the minimum keeps its size.
        #expect(ScreenTextLayout.fittedSize(minimum: 6, maximum: 4) { _ in false } == 4)
    }

    @Test func platesTakeTheBackgroundAndTheTextsColor() {
        typealias RGB = ScreenTextLayout.RGB
        let blue = RGB(red: 0.1, green: 0.3, blue: 0.8)
        let yellow = RGB(red: 1, green: 0.9, blue: 0.2)
        // A yellow label on a blue button, one stray white pixel on the edge.
        let edge = Array(repeating: blue, count: 30) + [.white]
        let inside = Array(repeating: blue, count: 70) + Array(repeating: yellow, count: 30)
        let colors = ScreenTextLayout.plateColors(edge: edge, inside: inside)
        #expect(colors.background == blue)
        #expect(colors.text == yellow)
    }

    @Test func antialiasedTextKeepsItsInk() {
        typealias RGB = ScreenTextLayout.RGB
        let paper = RGB(red: 0.97, green: 0.97, blue: 0.97)
        // Black text scaled down: a few pixels near black, many grays where strokes meet the paper.
        let grays = stride(from: 0.3, through: 0.65, by: 0.05).map { RGB(red: $0, green: $0, blue: $0) }
        let inside = Array(repeating: paper, count: 60) + Array(repeating: grays, count: 3).flatMap { $0 }
            + Array(repeating: RGB(red: 0.05, green: 0.05, blue: 0.05), count: 10)
        let text = ScreenTextLayout.plateColors(edge: [paper], inside: inside).text
        #expect(text.red < 0.1)
    }

    @Test func faintTextBecomesBlackOrWhite() {
        typealias RGB = ScreenTextLayout.RGB
        let light = RGB(red: 0.95, green: 0.95, blue: 0.95)
        let gray = RGB(red: 0.7, green: 0.7, blue: 0.7) // too little contrast on the plate
        #expect(ScreenTextLayout.plateColors(edge: [light], inside: [light, gray, gray]).text == .black)
        let dark = RGB(red: 0.1, green: 0.1, blue: 0.12)
        #expect(ScreenTextLayout.plateColors(edge: [dark], inside: [dark]).text == .white)
        let unknown = ScreenTextLayout.plateColors(edge: [], inside: [])
        #expect(unknown.background == .white && unknown.text == .black)
        #expect(RGB.black.contrast(with: .white) > 20.9)
    }

    @Test func theCacheForgetsWhatWasNotUsedLately() {
        var cache = RecentCache<String, Int>(capacity: 4)
        for (index, key) in ["a", "b", "c", "d"].enumerated() { cache.insert(index, for: key) }
        #expect(cache.value(for: "a") == 0) // used: kept
        cache.insert(4, for: "e")
        #expect(cache.count == 3)
        #expect(cache.value(for: "a") == 0)
        #expect(cache.value(for: "e") == 4)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == nil)
    }

    @Test func languagesMatchAcrossRegionsButNotScripts() {
        let supported = ["en-GB", "en-US", "zh-Hans", "zh-Hant", "id", "ja", "pt-BR"].map(Locale.Language.init(identifier:))
        #expect(ScreenTextLanguages.same(Locale.Language(identifier: "en"), Locale.Language(identifier: "en-GB")))
        #expect(!ScreenTextLanguages.same(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-TW")))
        #expect(ScreenTextLanguages.same(Locale.Language(identifier: "zh-CN"), Locale.Language(identifier: "zh-Hans")))
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "en-US"), in: supported)?.region?.identifier == "US")
        // No region asked for: the language's own (the US for English), not the first listed.
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "en"), in: supported)?.region?.identifier == "US")
        // English in Indonesia (a Mac set to en-ID) is English in the US, not in India.
        let english = ["en-IN", "en-GB", "en-US", "en-AU"].map(Locale.Language.init(identifier:))
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "en-ID"), in: english)?.region?.identifier == "US")
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "en-AU"), in: english)?.region?.identifier == "AU")
        // Without the language's own region, the first one.
        let arabic = ["ar-AE", "ar-SA"].map(Locale.Language.init(identifier:))
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "ar"), in: arabic)?.region?.identifier == "AE")
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "zh-TW"), in: supported) == Locale.Language(identifier: "zh-Hant"))
        #expect(ScreenTextLanguages.match(Locale.Language(identifier: "fi"), in: supported) == nil)
    }

    @Test func translateIntoListsEachLanguageOnceByItsName() {
        // As LanguageAvailability lists them: every one with its script and region.
        let supported = ["en-Latn-IN", "it-Latn-CH", "ko-Kore-KR", "en-Latn-GB", "zh-Hant-HK", "zh-Hant-TW", "it-Latn-IT",
                         "zh-Hans-CN", "en-Latn-US", "pt-Latn-BR", "pt-Latn-PT", "id-Latn-ID", "ar-Arab-AE", "ar-Arab-SA"]
            .map(Locale.Language.init(identifier:))
        let distinct = ScreenTextLanguages.distinct(supported)
        #expect(distinct.map(\.maximalIdentifier) == ["en-Latn-US", "it-Latn-IT", "ko-Kore-KR", "zh-Hant-TW", "zh-Hans-CN",
                                                       "pt-Latn-BR", "id-Latn-ID", "ar-Arab-AE"])
        let names = distinct.map { ScreenTextLanguages.nameIdentifier(of: $0, among: supported) }
        #expect(names == ["en", "it", "ko", "zh-Hant", "zh-Hans", "pt", "id", "ar"])
    }

    @Test func theTargetIsTheFirstPreferredLanguageThatCanBeTranslatedInto() {
        let supported = ["en-US", "id", "ja"].map(Locale.Language.init(identifier:))
        #expect(ScreenTextLanguages.target(preferred: ["fi-FI", "id-ID", "en-US"], supported: supported) == Locale.Language(identifier: "id"))
        #expect(ScreenTextLanguages.target(preferred: ["fi-FI"], supported: supported) == nil)
        let english = ["en-IN", "en-GB", "en", "id"].map(Locale.Language.init(identifier:))
        #expect(ScreenTextLanguages.target(preferred: ["en-ID", "id-ID"], supported: english)?.maximalIdentifier == "en-Latn-US")
    }

    @Test func naturalLanguageCodesNameTheChineseScript() {
        #expect(ScreenTextLanguages.naturalLanguageCode(for: Locale.Language(identifier: "en-US")) == "en")
        #expect(ScreenTextLanguages.naturalLanguageCode(for: Locale.Language(identifier: "zh-TW")) == "zh-Hant")
        #expect(ScreenTextLanguages.naturalLanguageCode(for: Locale.Language(identifier: "zh")) == "zh-Hans")
        #expect(ScreenTextLanguages.naturalLanguageCode(for: Locale.Language(identifier: "ja")) == "ja")
    }
}
