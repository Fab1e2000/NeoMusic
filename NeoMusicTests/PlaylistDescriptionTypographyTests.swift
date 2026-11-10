import SwiftUI
import UIKit
import XCTest
@testable import NeoMusic

@MainActor
final class PlaylistDescriptionTypographyTests: XCTestCase {
    func testStandardTextSizeUsesMeasuredFifteenPointFont() throws {
        let view = UITextView()
        view.traitOverrides.preferredContentSizeCategory = .large
        view.updateTraitsIfNeeded()
        let field = PlaylistDescriptionTextView(text: .constant("播放列表描述"))

        field.updateTextAndStyle(view)

        let font = try XCTUnwrap(view.font)
        XCTAssertEqual(font.pointSize, 15, accuracy: 0.001)
        XCTAssertTrue(view.adjustsFontForContentSizeCategory)
        XCTAssertEqual(view.text, "播放列表描述")
        try assertMatchingFonts(in: view, expected: font)
    }

    func testAccessibilityTextSizeSurvivesTraitAndTextUpdates() throws {
        let view = UITextView()
        view.traitOverrides.preferredContentSizeCategory = .large
        view.updateTraitsIfNeeded()
        let initial = PlaylistDescriptionTextView(text: .constant("原来的描述"))
        initial.updateTextAndStyle(view)

        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.updateTraitsIfNeeded()
        initial.updateTextAndStyle(view)

        let font = try XCTUnwrap(view.font)
        let expected = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15), compatibleWith: view.traitCollection)
        XCTAssertGreaterThan(font.pointSize, 15)
        XCTAssertEqual(font, expected)
        try assertMatchingFonts(in: view, expected: font)

        let edited = PlaylistDescriptionTextView(text: .constant("编辑后的新描述"))
        edited.updateTextAndStyle(view)

        XCTAssertEqual(view.text, "编辑后的新描述")
        try assertMatchingFonts(in: view, expected: font)
    }

    func testEmptyTextRetainsScaledFontForContinuedTyping() throws {
        let view = UITextView()
        view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        view.updateTraitsIfNeeded()
        let populated = PlaylistDescriptionTextView(text: .constant("待清空的描述"))
        populated.updateTextAndStyle(view)
        let font = try XCTUnwrap(view.font)

        let empty = PlaylistDescriptionTextView(text: .constant(""))
        empty.updateTextAndStyle(view)

        XCTAssertEqual(view.text, "")
        XCTAssertGreaterThan(font.pointSize, 15)
        XCTAssertEqual(view.font, font)
        XCTAssertEqual(view.typingAttributes[.font] as? UIFont, font)
    }

    private func assertMatchingFonts(in view: UITextView, expected: UIFont,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(view.font, expected, file: file, line: line)
        XCTAssertEqual(view.typingAttributes[.font] as? UIFont, expected, file: file, line: line)
        let attributed = try XCTUnwrap(view.attributedText, file: file, line: line)
        XCTAssertGreaterThan(attributed.length, 0, file: file, line: line)
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { font, _, _ in
            XCTAssertEqual(font as? UIFont, expected, file: file, line: line)
        }
    }
}
