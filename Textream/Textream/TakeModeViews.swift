//
//  TakeModeViews.swift
//  Textream (CNL build)
//
//  Take Mode: one take at a time, scaled to fill the screen, with the
//  same word-by-word highlighting the regular prompter uses.
//

import AppKit
import SwiftUI

// MARK: - Font fitting

/// Finds the largest font size at which a take fits a given box.
enum TakeTextFitter {
    private struct CacheKey: Hashable {
        let text: String
        let width: Int
        let height: Int
        let maxSize: Int
        let family: String
    }

    private static var cache: [CacheKey: CGFloat] = [:]

    static func fittedSize(
        text: String,
        family: FontFamilyPreset,
        width: CGFloat,
        height: CGFloat,
        maxSize: CGFloat,
        minSize: CGFloat = 28
    ) -> CGFloat {
        guard width > 0, height > 0, !text.isEmpty else { return minSize }

        let key = CacheKey(
            text: text,
            width: Int(width),
            height: Int(height),
            maxSize: Int(maxSize),
            family: family.rawValue
        )
        if let cached = cache[key] { return cached }

        let longestWord = splitTextIntoWords(text).max { a, b in
            (a as NSString).length < (b as NSString).length
        } ?? text

        func fits(_ size: CGFloat) -> Bool {
            let attributes: [NSAttributedString.Key: Any] = [.font: family.font(size: size)]
            // A single word must never be wider than the box, or it would be clipped.
            if (longestWord as NSString).size(withAttributes: attributes).width > width {
                return false
            }
            let rect = (text as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes,
                context: nil
            )
            return ceil(rect.height) <= height
        }

        let upper = max(minSize, maxSize)
        let result: CGFloat
        if fits(upper) {
            result = upper
        } else if !fits(minSize) {
            result = minSize
        } else {
            var lo = minSize
            var hi = upper
            for _ in 0..<18 {
                let mid = (lo + hi) / 2
                if fits(mid) { lo = mid } else { hi = mid }
            }
            result = floor(lo)
        }

        if cache.count > 200 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

// MARK: - Take text

/// Renders one take, centered on screen at the largest size that fits.
/// Words light up as they are read, matching the regular prompter's colors.
struct TakeTextView: View {
    let words: [String]
    let paragraphBreakBeforeWordIndices: Set<Int>
    let highlightedCharCount: Int
    let highlightColor: Color
    let cueColor: Color
    let cueUnreadOpacity: Double
    let cueReadOpacity: Double
    let fontFamily: FontFamilyPreset
    let maxFontSize: CGFloat

    /// The take as laid out on screen: spaces between words, line breaks
    /// where the script has them. Used for measuring.
    private var layoutText: String {
        var text = ""
        for (i, word) in words.enumerated() {
            if i > 0 {
                text += paragraphBreakBeforeWordIndices.contains(i) ? "\n" : " "
            }
            text += word
        }
        return text
    }

    var body: some View {
        GeometryReader { geo in
            // Measure slightly inside the real box so SwiftUI's own line
            // wrapping never needs more room than we measured.
            let fontSize = TakeTextFitter.fittedSize(
                text: layoutText,
                family: fontFamily,
                width: geo.size.width * 0.96,
                height: geo.size.height * 0.95,
                maxSize: maxFontSize
            )

            Text(attributedTake(fontSize: fontSize))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
    }

    private func attributedTake(fontSize: CGFloat) -> AttributedString {
        let baseFont = Font(fontFamily.font(size: fontSize))
        let annotationFlags = SpeechTextAlignment.annotationFlags(for: words)

        var result = AttributedString()
        var charOffset = 0
        var markedCurrentWord = false

        for (i, word) in words.enumerated() {
            if i > 0 {
                var separator = AttributedString(paragraphBreakBeforeWordIndices.contains(i) ? "\n" : " ")
                separator.swiftUI.font = baseFont
                result += separator
            }

            let isAnnotation = (i < annotationFlags.count && annotationFlags[i])
                || WordFlowLayout.isAnnotationWord(word)
            let charsIntoWord = highlightedCharCount - charOffset
            let litCount = max(0, min(word.count, charsIntoWord))
            let letterCount = max(1, word.filter { $0.isLetter || $0.isNumber }.count)
            let isFullyLit = litCount >= letterCount

            var run = AttributedString(word)
            if isAnnotation {
                // Cues like [pause] stay italic and dim, as in the regular prompter
                run.swiftUI.font = baseFont.italic()
                run.swiftUI.foregroundColor = isFullyLit
                    ? cueColor.opacity(cueReadOpacity)
                    : cueColor.opacity(cueUnreadOpacity)
            } else {
                run.swiftUI.font = baseFont
                if isFullyLit {
                    run.swiftUI.foregroundColor = highlightColor.opacity(0.3)
                } else if !markedCurrentWord {
                    markedCurrentWord = true
                    run.swiftUI.foregroundColor = highlightColor.opacity(0.6)
                    run.swiftUI.underlineStyle = .single
                } else {
                    run.swiftUI.foregroundColor = highlightColor
                }
            }
            result += run
            charOffset += word.count + 1
        }
        return result
    }
}
