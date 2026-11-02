//
//  TakeModeViews.swift
//  Textream (CNL build)
//
//  Take Mode text sizing. Takes scroll in the regular prompter view at a
//  much larger size than the stock fullscreen teleprompter.
//

import AppKit

enum TakeFontSizing {
    /// The preferred take size, reduced only as far as needed for the
    /// longest word to fit on one line. The prompter never splits a word,
    /// so a word wider than the screen would be cut off.
    static func size(words: [String], preferred: CGFloat, availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0, !words.isEmpty else { return preferred }

        let referenceSize: CGFloat = 100
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: referenceSize, weight: .semibold)
        ]
        // Include the trailing space the prompter draws after each word
        let widest = words.reduce(CGFloat(0)) { current, word in
            max(current, ((word + " ") as NSString).size(withAttributes: attributes).width)
        }
        guard widest > 0 else { return preferred }

        let fitting = floor(referenceSize * availableWidth * 0.98 / widest)
        return max(36, min(preferred, fitting))
    }
}
