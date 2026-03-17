import AppKit

enum ANSIParser {
    // Screen cell: character + style
    private struct Cell {
        var char: Character = " "
        var color: NSColor = .white
        var bgColor: NSColor? = nil
        var isBold: Bool = false
        var isItalic: Bool = false
    }

    static func parse(
        _ string: String,
        rows: Int = 50,
        cols: Int = 72,
        baseFont: NSFont = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    ) -> NSAttributedString {
        // Virtual screen buffer
        var screen = [[Cell]](repeating: [Cell](repeating: Cell(), count: cols), count: rows)
        var curRow = 0
        var curCol = 0
        var currentColor: NSColor = .white
        var currentBgColor: NSColor? = nil
        var isBold = false
        var isItalic = false

        func clampCursor() {
            curRow = max(0, min(curRow, rows - 1))
            curCol = max(0, min(curCol, cols - 1))
        }

        func scrollUp() {
            screen.removeFirst()
            screen.append([Cell](repeating: Cell(), count: cols))
        }

        func applyCode(_ parts: [Int]) {
            var i = 0
            while i < parts.count {
                let n = parts[i]
                switch n {
                case 0:
                    currentColor = .white; currentBgColor = nil; isBold = false; isItalic = false
                case 1:  isBold = true
                case 3:  isItalic = true
                case 22: isBold = false
                case 23: isItalic = false
                case 30...37: currentColor = ANSIParser.standardColor(n - 30)
                case 39:      currentColor = .white
                case 40...47: currentBgColor = ANSIParser.standardColor(n - 40)
                case 49:      currentBgColor = nil
                case 90...97: currentColor = ANSIParser.brightColor(n - 90)
                case 38:
                    if i + 2 < parts.count && parts[i + 1] == 5 {
                        currentColor = ANSIParser.color256(parts[i + 2])
                        i += 2
                    } else if i + 4 < parts.count && parts[i + 1] == 2 {
                        let r = CGFloat(parts[i + 2]) / 255.0
                        let g = CGFloat(parts[i + 3]) / 255.0
                        let b = CGFloat(parts[i + 4]) / 255.0
                        currentColor = ANSIParser.srgb(r, g, b)
                        i += 4
                    }
                case 48:
                    if i + 2 < parts.count && parts[i + 1] == 5 {
                        currentBgColor = ANSIParser.color256(parts[i + 2])
                        i += 2
                    } else if i + 4 < parts.count && parts[i + 1] == 2 {
                        let r = CGFloat(parts[i + 2]) / 255.0
                        let g = CGFloat(parts[i + 3]) / 255.0
                        let b = CGFloat(parts[i + 4]) / 255.0
                        currentBgColor = ANSIParser.srgb(r, g, b)
                        i += 4
                    }
                default: break
                }
                i += 1
            }
        }

        func putChar(_ ch: Character) {
            if curCol >= cols {
                curCol = 0
                curRow += 1
                if curRow >= rows { scrollUp(); curRow = rows - 1 }
            }
            screen[curRow][curCol] = Cell(char: ch, color: currentColor, bgColor: currentBgColor, isBold: isBold, isItalic: isItalic)
            curCol += 1
        }

        // Parse escape sequences and write to screen buffer
        // Use Unicode scalars to avoid Swift treating \r\n as a single Character
        let scalars = string.unicodeScalars
        var idx = scalars.startIndex
        while idx < scalars.endIndex {
            let sc = scalars[idx]

            if sc == "\u{1B}" {
                let after = scalars.index(after: idx)
                guard after < scalars.endIndex else { idx = after; continue }

                if scalars[after] == Unicode.Scalar("[") {
                    // CSI sequence
                    var j = scalars.index(after: after)
                    if j < scalars.endIndex && (scalars[j] == Unicode.Scalar("?") || scalars[j] == Unicode.Scalar(">")) {
                        j = scalars.index(after: j)
                    }
                    while j < scalars.endIndex {
                        let v = scalars[j].value
                        if v >= 0x40 && v <= 0x7E { break }
                        j = scalars.index(after: j)
                    }
                    if j < scalars.endIndex {
                        let finalChar = scalars[j]
                        let codeStart = scalars.index(after: after)
                        let codeStr = String(scalars[codeStart..<j])
                            .replacingOccurrences(of: "?", with: "")
                            .replacingOccurrences(of: ">", with: "")
                        let params = codeStr.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                        let p1 = params.first ?? 0

                        switch finalChar {
                        case "m":
                            applyCode(params)
                        case "A": // Cursor up
                            curRow -= max(p1, 1); clampCursor()
                        case "B": // Cursor down
                            curRow += max(p1, 1); clampCursor()
                        case "C": // Cursor forward
                            curCol += max(p1, 1); clampCursor()
                        case "D": // Cursor back
                            curCol -= max(p1, 1); clampCursor()
                        case "G": // Cursor to column
                            curCol = max(p1 - 1, 0); clampCursor()
                        case "H", "f": // Cursor position (row;col)
                            curRow = max(p1 - 1, 0)
                            curCol = max((params.count > 1 ? params[1] : 1) - 1, 0)
                            clampCursor()
                        case "J": // Erase in display
                            if p1 == 2 || p1 == 3 {
                                for r in 0..<rows { for c in 0..<cols { screen[r][c] = Cell() } }
                            }
                        case "K": // Erase in line
                            if p1 == 0 { // erase to end of line
                                for c in curCol..<cols { screen[curRow][c] = Cell() }
                            } else if p1 == 2 { // erase entire line
                                for c in 0..<cols { screen[curRow][c] = Cell() }
                            }
                        default: break
                        }
                        idx = scalars.index(after: j)
                        continue
                    }
                } else if scalars[after] == Unicode.Scalar("]") {
                    // OSC: skip until BEL or ST
                    var j = scalars.index(after: after)
                    while j < scalars.endIndex {
                        if scalars[j] == "\u{07}" { idx = scalars.index(after: j); break }
                        if scalars[j] == "\u{1B}" {
                            let next = scalars.index(after: j)
                            if next < scalars.endIndex && scalars[next] == Unicode.Scalar("\\") {
                                idx = scalars.index(after: next); break
                            }
                        }
                        j = scalars.index(after: j)
                    }
                    if j >= scalars.endIndex { idx = j }
                    continue
                } else if scalars[after] == Unicode.Scalar("(") || scalars[after] == Unicode.Scalar(")") || scalars[after] == Unicode.Scalar("*") || scalars[after] == Unicode.Scalar("+") {
                    let third = scalars.index(after: after)
                    idx = (third < scalars.endIndex) ? scalars.index(after: third) : third
                    continue
                } else {
                    idx = after
                    continue
                }
            } else if sc == "\r" {
                curCol = 0
                idx = scalars.index(after: idx)
                continue
            } else if sc == "\n" {
                curRow += 1
                if curRow >= rows { scrollUp(); curRow = rows - 1 }
                idx = scalars.index(after: idx)
                continue
            } else if sc == "\t" {
                let tabStop = ((curCol / 8) + 1) * 8
                curCol = min(tabStop, cols - 1)
                idx = scalars.index(after: idx)
                continue
            } else if sc.value < 0x20 {
                // Skip other control characters
                idx = scalars.index(after: idx)
                continue
            } else {
                putChar(Character(sc))
                idx = scalars.index(after: idx)
                continue
            }
            idx = scalars.index(after: idx)
        }

        // Convert screen buffer to NSAttributedString, trimming trailing blank rows
        let result = NSMutableAttributedString()
        var lastNonBlankRow = -1
        for r in (0..<rows).reversed() {
            if screen[r].contains(where: { $0.char != " " }) {
                lastNonBlankRow = r
                break
            }
        }

        // Cache the four font variants to avoid allocating NSFont per character.
        let fontPlain = baseFont
        let fontBold = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold), size: baseFont.pointSize) ?? baseFont
        let fontItalic = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.italic), size: baseFont.pointSize) ?? baseFont
        let fontBoldItalic = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits([.bold, .italic]), size: baseFont.pointSize) ?? baseFont

        for r in 0...max(lastNonBlankRow, 0) {
            // Find last non-space column to trim trailing spaces
            var lastCol = -1
            for c in (0..<cols).reversed() {
                if screen[r][c].char != " " { lastCol = c; break }
            }

            for c in 0...max(lastCol, 0) {
                let cell = screen[r][c]
                let font: NSFont
                switch (cell.isBold, cell.isItalic) {
                case (false, false): font = fontPlain
                case (true,  false): font = fontBold
                case (false, true):  font = fontItalic
                case (true,  true):  font = fontBoldItalic
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: cell.color
                ]
                if let bg = cell.bgColor { attrs[.backgroundColor] = bg }
                result.append(NSAttributedString(string: String(cell.char), attributes: attrs))
            }
            if r < lastNonBlankRow {
                result.append(NSAttributedString(string: "\n"))
            }
        }

        return result
    }

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    private static func standardColor(_ index: Int) -> NSColor {
        switch index {
        case 0: return srgb(0,     0,     0)     // black
        case 1: return srgb(0.804, 0,     0)     // red
        case 2: return srgb(0,     0.804, 0)     // green
        case 3: return srgb(0.804, 0.804, 0)     // yellow
        case 4: return srgb(0,     0,     0.804) // blue
        case 5: return srgb(0.804, 0,     0.804) // magenta
        case 6: return srgb(0,     0.804, 0.804) // cyan
        case 7: return srgb(0.753, 0.753, 0.753) // white
        default: return .white
        }
    }

    private static func brightColor(_ index: Int) -> NSColor {
        switch index {
        case 0: return srgb(0.502, 0.502, 0.502) // bright black
        case 1: return srgb(1,     0,     0)     // bright red
        case 2: return srgb(0,     1,     0)     // bright green
        case 3: return srgb(1,     1,     0)     // bright yellow
        case 4: return srgb(0,     0,     1)     // bright blue
        case 5: return srgb(1,     0,     1)     // bright magenta
        case 6: return srgb(0,     1,     1)     // bright cyan
        case 7: return srgb(1,     1,     1)     // bright white
        default: return .white
        }
    }

    private static func color256(_ n: Int) -> NSColor {
        guard n >= 0 && n <= 255 else { return .white }
        if n < 8  { return standardColor(n) }
        if n < 16 { return brightColor(n - 8) }
        if n >= 232 {
            let v = CGFloat(8 + (n - 232) * 10) / 255.0
            return srgb(v, v, v)
        }
        let idx = n - 16
        let bi = idx % 6
        let gi = (idx / 6) % 6
        let ri = idx / 36
        func comp(_ x: Int) -> CGFloat { x == 0 ? 0 : CGFloat(55 + x * 40) / 255.0 }
        return srgb(comp(ri), comp(gi), comp(bi))
    }
}
