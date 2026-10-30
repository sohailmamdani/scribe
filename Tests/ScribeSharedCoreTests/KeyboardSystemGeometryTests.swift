import CoreGraphics
import XCTest
@testable import ScribeSharedCore

final class KeyboardSystemGeometryTests: XCTestCase {
    /// White-cap bounds from native English (US) QWERTY screenshots on iOS
    /// 26.2, captured at 2x (SE) and 3x (17 Pro / Pro Max). Allow half a point
    /// for UIKit's pixel rounding and antialiased cap edges.
    func testPortraitRowsMatchMeasuredAppleCaps() {
        let samples: [(width: Double, height: Double, pitch: Double, qWidth: Double,
                       aX: Double, zX: Double, shiftWidth: Double)] = [
            (375, 42, 54, 31, 25, 61.5, 42),
            (402, 43, 54, 33.333, 26.333, 65.667, 45.333),
            (440, 45, 56, 37, 28, 71.333, 50)
        ]
        for sample in samples {
            let geometry = KeyboardGeometryRules.portrait(totalWidth: sample.width)
            XCTAssertEqual(geometry.keyHeight, sample.height)
            XCTAssertEqual(geometry.keyHeight + geometry.verticalGap, sample.pitch)
            XCTAssertEqual(geometry.tenColumnKeyWidth(totalWidth: sample.width), sample.qWidth, accuracy: 0.5)
            XCTAssertEqual(geometry.outerInset + geometry.homeRowInset(totalWidth: sample.width), sample.aX, accuracy: 0.5)
            XCTAssertEqual(geometry.controlWidth(totalWidth: sample.width), sample.shiftWidth, accuracy: 0.5)
            XCTAssertEqual(
                geometry.outerInset + geometry.controlWidth(totalWidth: sample.width)
                    + geometry.controlToLetterGap(totalWidth: sample.width),
                sample.zX, accuracy: 0.5
            )
        }
    }

    func testSpaceAndReturnMatchAppleWhilePeriodStaysOnTheLeft() {
        for (width, spaceX, spaceWidth, returnX) in [
            (402.0, 105.333, 191.333, 302.667),
            (440.0, 114.667, 210.667, 331.333)
        ] {
            let g = KeyboardGeometryRules.portrait(totalWidth: width)
            let bottom = KeyboardBottomRowWidths.resolve(
                totalWidth: width, outerInset: g.outerInset, horizontalGap: g.horizontalGap,
                punctuationWidth: 46, includesInputModeSwitchKey: false, usesSystemProportions: true
            )
            let actualSpaceX = g.outerInset + bottom.mode + bottom.punctuation + 2 * g.horizontalGap
            XCTAssertEqual(actualSpaceX, spaceX, accuracy: 0.5)
            XCTAssertEqual(bottom.space, spaceWidth, accuracy: 0.5)
            XCTAssertEqual(actualSpaceX + bottom.space + g.horizontalGap, returnX, accuracy: 0.5)
            XCTAssertEqual(actualSpaceX + bottom.space / 2, width / 2, accuracy: 0.001)

            let y = 3 * (g.keyHeight + g.verticalGap)
            let frames = [
                "period": CGRect(x: g.outerInset + bottom.mode + g.horizontalGap, y: y,
                                 width: bottom.punctuation, height: g.keyHeight),
                "space": CGRect(x: actualSpaceX, y: y, width: bottom.space, height: g.keyHeight),
                "return": CGRect(x: actualSpaceX + bottom.space + g.horizontalGap, y: y,
                                 width: bottom.returnKey, height: g.keyHeight)
            ]
            let regions = KeyboardHitGrid.regions(forFrames: frames,
                in: CGRect(x: 0, y: y, width: width, height: g.keyHeight))
            for x in [spaceX + 1, width / 2, spaceX + spaceWidth - 1] {
                XCTAssertEqual(KeyboardHitGrid.key(at: CGPoint(x: x, y: y + 20), regions: regions,
                                                  verticalTapBias: 2), "space")
            }
        }
    }

    func testAllPortraitRowsFitAcrossSupportedPhoneWidths() {
        for width in [320.0, 375, 390, 393, 402, 414, 430, 440] {
            let g = KeyboardGeometryRules.portrait(totalWidth: width)
            for hasGlobe in [false, true] {
                let bottom = KeyboardBottomRowWidths.resolve(
                    totalWidth: width, outerInset: g.outerInset, horizontalGap: g.horizontalGap,
                    punctuationWidth: 46, includesInputModeSwitchKey: hasGlobe, usesSystemProportions: true
                )
                let occupied = bottom.mode + bottom.punctuation + bottom.space + bottom.returnKey
                    + (hasGlobe ? 45 : 0) + (hasGlobe ? 4 : 3) * g.horizontalGap + 2 * g.outerInset
                XCTAssertEqual(occupied, width, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(bottom.mode, 32)
                XCTAssertGreaterThanOrEqual(bottom.punctuation, 32)
                XCTAssertGreaterThan(bottom.space, 80)
            }
            XCTAssertEqual(g.letterControlRowWidth(totalWidth: width), width - 2 * g.outerInset, accuracy: 0.001)
        }
    }
}
