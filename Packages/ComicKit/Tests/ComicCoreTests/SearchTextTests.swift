@testable import ComicCore
import Foundation
import Testing

/// Japanese search across hiragana, katakana, kanji and romaji (#106).
@Suite struct SearchTextTests {
    private func finds(_ query: String, in text: String) -> Bool {
        SearchQuery(query).matches(SearchKey(text))
    }

    @Test func folding() {
        #expect(SearchKey.fold("キミ") == "きみ")
        #expect(SearchKey.fold("ｷﾐ") == "きみ")
        #expect(SearchKey.fold("ｶﾞﾝﾀﾞﾑ") == "がんだむ")
        #expect(SearchKey.fold("Café ＡＢＣ") == "cafe abc")
        #expect(SearchKey.fold("ガ") == "が", "kana keep their voicing marks")
    }

    @Test func romajiFolding() {
        #expect(SearchKey.foldRomaji("Tōkyō") == "tokyo")
        #expect(SearchKey.foldRomaji("toukyou") == "tokyo")
        #expect(SearchKey.foldRomaji("Kimi no Na wa") == "kiminonawa")
        #expect(SearchKey.foldRomaji("ren'ai") == "renai")
        #expect(SearchKey.foldRomaji("tuki") == "tsuki")
        #expect(SearchKey.foldRomaji("tsuki") == "tsuki")
        #expect(SearchKey.foldRomaji("sinsekai") == "shinsekai")
    }

    @Test func plainTextAsBefore() {
        #expect(finds("aria", in: "ARIA 第07巻"))
        #expect(finds("cafe", in: "Café Stories"))
        #expect(finds("Bat", in: "Batman"))
        #expect(!finds("superman", in: "Batman"))
        #expect(!finds("batman", in: "君の名は"))
    }

    @Test func hiraganaFindsKatakana() {
        #expect(finds("きみ", in: "キミと僕"))
        #expect(finds("キミ", in: "きみと僕"))
        #expect(finds("きみ", in: "ｷﾐと僕"))
    }

    @Test func kanaFindsKanji() {
        #expect(finds("きみ", in: "君の名は"))
        #expect(finds("キミ", in: "君の名は"))
        #expect(finds("きみのなは", in: "君の名は"))
        #expect(finds("きみのなわ", in: "君の名は"), "particles as spoken")
        #expect(finds("とうきょう", in: "東京喰種"))
        #expect(!finds("さくら", in: "君の名は"))
    }

    @Test func kanjiFindsKana() {
        #expect(finds("君", in: "キミに決めた"))
        #expect(finds("君", in: "君の名は"))
    }

    @Test func romajiFindsJapanese() {
        #expect(finds("kimi", in: "君の名は"))
        #expect(finds("kiminonawa", in: "君の名は"))
        #expect(finds("kimi no na ha", in: "君の名は"))
        #expect(finds("tokyo", in: "東京喰種"))
        #expect(finds("toukyou", in: "東京喰種"))
        #expect(finds("aria", in: "アリア"))
        #expect(!finds("sakura", in: "君の名は"))
    }

    /// Not checked, but printed in the test log to see what the dictionary makes of titles.
    @Test func printSampleReadings() {
        for title in ["君の名は", "ARIA 第07巻", "東京喰種トーキョーグール", "進撃の巨人", "鋼の錬金術師", "よつばと!", "ﾁｪﾝｿｰﾏﾝ", "葬送のフリーレン"] {
            let key = SearchKey(title)
            print("reading:", title, key.readings, key.romaji)
        }
    }

    @Test func manyTitlesAreQuick() {
        let titles = (0..<500).map { "進撃の巨人 第\($0)巻" }
        let start = Date()
        let keys = titles.map { SearchKey($0) }
        let elapsed = Date().timeIntervalSince(start)
        print("reading: 500 titles in \(elapsed)s")
        #expect(keys.count == 500)
        #expect(SearchQuery("しんげき").matches(keys[0]))
    }
}
