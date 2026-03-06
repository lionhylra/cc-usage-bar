import Testing
import AppKit
@testable import CCUsageBar

struct ANSIParserTests {
    let font = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    @Test func plainText() {
        let result = ANSIParser.parse("hello world", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("hello world"))
    }

    @Test func bold() {
        let result = ANSIParser.parse("\u{1B}[1mbold\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("bold"))
        let attrs = result.attributes(at: 0, effectiveRange: nil)
        let f = attrs[.font] as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func resetAfterBold() {
        let result = ANSIParser.parse("\u{1B}[1mbold\u{1B}[0mnormal", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("boldnormal"))
        let attrs = result.attributes(at: 4, effectiveRange: nil)
        let f = attrs[.font] as? NSFont
        #expect(f?.fontDescriptor.symbolicTraits.contains(.bold) == false)
    }

    @Test func redColor() {
        let result = ANSIParser.parse("\u{1B}[31mred\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("red"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(color != nil)
        #expect((color?.greenComponent ?? 1) < 0.1)
    }

    @Test func brightGreen() {
        let result = ANSIParser.parse("\u{1B}[92mbright\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("bright"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(color != nil)
    }

    @Test func rgbColor() {
        let result = ANSIParser.parse("\u{1B}[38;2;255;128;0morange\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("orange"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(abs((color?.redComponent ?? 0) - 1.0) < 0.01)
        #expect(abs((color?.greenComponent ?? 0) - 128.0 / 255.0) < 0.01)
        #expect(abs((color?.blueComponent ?? 1) - 0.0) < 0.01)
    }

    @Test func color256() {
        let result = ANSIParser.parse("\u{1B}[38;5;196mred256\u{1B}[0m", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("red256"))
        let color = result.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        #expect(color != nil)
    }

    @Test func stripsEscapeCodes() {
        let input = "\u{1B}[1m\u{1B}[32mSuccess\u{1B}[0m: done"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("Success: done"))
    }

    @Test func multipleColorRuns() {
        let input = "\u{1B}[31mred\u{1B}[32mgreen\u{1B}[0mplain"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("redgreenplain"))
    }

    @Test func cursorForwardPreservesExistingContent() {
        let input = "hello\rhe\u{1B}[3Cd"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("hellod"))
    }

    @Test func cursorUpAndOverwrite() {
        let input = "aaa\r\nbbb\u{1B}[1AX"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        let lines = result.string.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2)
        #expect(lines[0].hasPrefix("aaaX"))
    }

    @Test func privateModesStripped() {
        let result = ANSIParser.parse("\u{1B}[?2026hhello", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("hello"))
    }

    @Test func eraseInLine() {
        let input = "hello\r\u{1B}[K"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func oscSequenceStripped() {
        let result = ANSIParser.parse("before\u{1B}]0;My Title\u{07}after", rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("beforeafter"))
    }

    @Test func carriageReturnOverwrites() {
        let input = "Resets 2pm\rRese\u{1B}[1Cs"
        let result = ANSIParser.parse(input, rows: 5, cols: 40, baseFont: font)
        #expect(result.string.hasPrefix("Resets"))
    }
}
