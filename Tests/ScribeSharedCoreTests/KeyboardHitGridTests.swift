import CoreGraphics
import XCTest
@testable import ScribeSharedCore

final class KeyboardHitGridTests: XCTestCase {
    private let geometry = KeyboardGeometryRules.portrait
    private let totalWidth = 440.0

    private var bounds: CGRect {
        CGRect(
            x: 0,
            y: 0,
            width: totalWidth,
            height: 3 * geometry.keyHeight + 2 * geometry.verticalGap
        )
    }

    /// Rebuilds the real portrait letter layout: three rows of caps separated
    /// by the drawn gaps, with Shift and Delete flanking the bottom row.
    private func letterLayoutFrames() -> [String: CGRect] {
        let keyWidth = geometry.tenColumnKeyWidth(totalWidth: totalWidth)
        let homeInset = geometry.homeRowInset(totalWidth: totalWidth)
        let controlGap = geometry.controlToLetterGap(totalWidth: totalWidth)
        let rowPitch = geometry.keyHeight + geometry.verticalGap
        var frames: [String: CGRect] = [:]

        func addRow(_ characters: String, startX: Double, y: Double) {
            var x = startX
            for character in characters {
                frames[String(character)] = CGRect(
                    x: x,
                    y: y,
                    width: keyWidth,
                    height: geometry.keyHeight
                )
                x += keyWidth + geometry.horizontalGap
            }
        }

        addRow("qwertyuiop", startX: geometry.outerInset, y: 0)
        addRow("asdfghjkl", startX: geometry.outerInset + homeInset, y: rowPitch)

        let thirdRowY = 2 * rowPitch
        let controlWidth = geometry.controlWidth(totalWidth: totalWidth)
        frames["shift"] = CGRect(
            x: geometry.outerInset,
            y: thirdRowY,
            width: controlWidth,
            height: geometry.keyHeight
        )
        addRow(
            "zxcvbnm",
            startX: geometry.outerInset + controlWidth + controlGap,
            y: thirdRowY
        )
        frames["delete"] = CGRect(
            x: totalWidth - geometry.outerInset - controlWidth,
            y: thirdRowY,
            width: controlWidth,
            height: geometry.keyHeight
        )
        return frames
    }

    private func regions() -> [String: CGRect] {
        KeyboardHitGrid.regions(forFrames: letterLayoutFrames(), in: bounds)
    }

    private func key(at point: CGPoint) -> String? {
        KeyboardHitGrid.key(at: point, regions: regions(), verticalTapBias: 0)
    }

    // MARK: - The dead-zone regression

    /// Every point inside the key area must resolve to some key. The previous
    /// implementation hit-tested the drawn caps and fell back to "nearest key
    /// centre within 30 pt", which swallowed taps that landed in the gaps.
    func testEveryPointInTheKeyAreaResolvesToAKey() {
        let resolved = regions()
        var unresolved: [CGPoint] = []
        var y = bounds.minY
        while y <= bounds.maxY {
            var x = bounds.minX
            while x <= bounds.maxX {
                let point = CGPoint(x: x, y: y)
                if KeyboardHitGrid.key(
                    at: point,
                    regions: resolved,
                    verticalTapBias: 0
                ) == nil {
                    unresolved.append(point)
                }
                x += 2
            }
            y += 2
        }
        XCTAssertTrue(
            unresolved.isEmpty,
            "\(unresolved.count) dead points, first at \(unresolved.first as Any)"
        )
    }

    /// Replicates the previous rule exactly: hit-test the drawn caps, and
    /// otherwise take the nearest key *centre* within 30 pt.
    private func legacyKey(at point: CGPoint, frames: [String: CGRect]) -> String? {
        if let hit = frames.first(where: { $0.value.contains(point) }) {
            return hit.key
        }
        let nearest = frames.min { lhs, rhs in
            hypot(lhs.value.midX - point.x, lhs.value.midY - point.y)
                < hypot(rhs.value.midX - point.x, rhs.value.midY - point.y)
        }
        guard let nearest,
              hypot(
                nearest.value.midX - point.x,
                nearest.value.midY - point.y
              ) < 30 else { return nil }
        return nearest.key
    }

    private func scanKeyArea(_ visit: (CGPoint) -> Void) {
        var y = bounds.minY
        while y <= bounds.maxY {
            var x = bounds.minX
            while x <= bounds.maxX {
                visit(CGPoint(x: x, y: y))
                x += 0.5
            }
            y += 0.5
        }
    }

    /// Locates the taps the old rule discarded and proves the grid resolves
    /// every one of them. The dead zones sit where a row gap crosses a wider
    /// than usual column gap — most visibly around Shift and Delete, whose
    /// 50 pt caps push their centres far from the letters beside them.
    func testTapsTheOldNearestCentreRuleDiscardedNowResolve() {
        let frames = letterLayoutFrames()
        var deadPoints: [CGPoint] = []
        scanKeyArea { point in
            if legacyKey(at: point, frames: frames) == nil {
                deadPoints.append(point)
            }
        }

        XCTAssertFalse(
            deadPoints.isEmpty,
            "fixture should reproduce the dead zones the grid was built to remove"
        )

        let resolved = regions()
        for point in deadPoints {
            XCTAssertNotNil(
                KeyboardHitGrid.key(at: point, regions: resolved, verticalTapBias: 0),
                "\(point) is still dead"
            )
        }
    }

    /// Centre distance systematically under-weights wide keys: Shift's 50 pt
    /// cap puts its centre 25 pt from its own right edge, while a 37 pt letter
    /// sits only 18 pt from its left edge. A tap in the gap that is plainly
    /// nearer Shift therefore resolved to "z" — you reach for Shift and get a
    /// letter. Edge distance ranks by the boundary the finger actually crossed.
    func testTapsNearerShiftNoLongerResolveToTheNarrowLetter() {
        let frames = letterLayoutFrames()
        let shift = frames["shift"]!
        let z = frames["z"]!
        // Sits inside the gap, closer to Shift's edge than to z's.
        let point = CGPoint(x: shift.maxX + 6, y: z.midY)
        XCTAssertLessThan(point.x - shift.maxX, z.minX - point.x)

        XCTAssertEqual(legacyKey(at: point, frames: frames), "z")
        XCTAssertEqual(key(at: point), "shift")
    }

    // MARK: - Edges and margins

    /// Outer keys claim the margin beside them, as they do on iOS. A tap on the
    /// far left of the top row is a "q", not a miss.
    func testOuterKeysClaimTheSurroundingMargin() {
        XCTAssertEqual(key(at: CGPoint(x: 0, y: 4)), "q")
        XCTAssertEqual(key(at: CGPoint(x: totalWidth, y: 4)), "p")
        XCTAssertEqual(key(at: CGPoint(x: 0, y: bounds.maxY - 2)), "shift")
        XCTAssertEqual(key(at: CGPoint(x: totalWidth, y: bounds.maxY - 2)), "delete")
    }

    /// The home row is inset, so its first key has to absorb the inset rather
    /// than leaving a strip that resolves to nothing.
    func testHomeRowInsetIsAbsorbedByTheOuterKeys() {
        let rowPitch = geometry.keyHeight + geometry.verticalGap
        let midRowY = rowPitch + geometry.keyHeight / 2
        XCTAssertEqual(key(at: CGPoint(x: 0, y: midRowY)), "a")
        XCTAssertEqual(key(at: CGPoint(x: totalWidth, y: midRowY)), "l")
    }

    func testKeysStillResolveToThemselvesAtTheirCentres() {
        let frames = letterLayoutFrames()
        for (name, frame) in frames {
            XCTAssertEqual(
                key(at: CGPoint(x: frame.midX, y: frame.midY)),
                name,
                "centre of \(name) resolved elsewhere"
            )
        }
    }

    /// Shift is 50 pt wide against 37 pt letters. Centre distance mis-ranks
    /// that pairing; edge distance does not.
    func testWideControlKeysDoNotStealNeighbouringLetters() {
        let frames = letterLayoutFrames()
        let z = frames["z"]!
        XCTAssertEqual(key(at: CGPoint(x: z.minX + 1, y: z.midY)), "z")
        XCTAssertEqual(key(at: CGPoint(x: frames["shift"]!.maxX - 1, y: z.midY)), "shift")
    }

    // MARK: - Outside the key area

    func testTouchesFarOutsideTheKeyAreaResolveToNothing() {
        let farBelow = CGPoint(
            x: totalWidth / 2,
            y: bounds.maxY + KeyboardHitGrid.maximumOutsideDistance + 10
        )
        XCTAssertNil(key(at: farBelow))
    }

    /// A finger that slides just past the edge is still on the key it left, so
    /// drags and hold-to-repeat do not break at the boundary.
    func testTouchesJustOutsideStillResolve() {
        XCTAssertNotNil(key(at: CGPoint(x: totalWidth / 2, y: bounds.maxY + 8)))
    }

    // MARK: - Geometry helpers

    func testVerticalTapBiasLiftsTheResolvedPoint() {
        let frames = letterLayoutFrames()
        let q = frames["q"]!
        // A point just inside the second row resolves there without bias, and
        // moves up to the first row once the bias exceeds the overshoot.
        let point = CGPoint(x: q.midX, y: q.maxY + geometry.verticalGap / 2 + 1)
        let unbiased = KeyboardHitGrid.key(
            at: point,
            regions: regions(),
            verticalTapBias: 0
        )
        let biased = KeyboardHitGrid.key(
            at: point,
            regions: regions(),
            verticalTapBias: 4
        )
        XCTAssertEqual(unbiased, "a")
        XCTAssertEqual(biased, "q")
    }

    func testDistanceIsZeroInsideTheRectangle() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 40)
        XCTAssertEqual(KeyboardHitGrid.distance(from: rect, to: CGPoint(x: 30, y: 30)), 0)
        XCTAssertEqual(KeyboardHitGrid.distance(from: rect, to: CGPoint(x: 60, y: 30)), 10)
    }

    func testEmptyInputProducesNoRegions() {
        XCTAssertTrue(KeyboardHitGrid.regions(forFrames: [String: CGRect](), in: bounds).isEmpty)
        XCTAssertNil(
            KeyboardHitGrid.key(
                at: .zero,
                regions: [String: CGRect](),
                verticalTapBias: 0
            )
        )
    }

    /// A single row must still expand to fill the whole area.
    func testSingleRowFillsTheBounds() {
        let frames = [
            "a": CGRect(x: 10, y: 20, width: 30, height: 40),
            "b": CGRect(x: 50, y: 20, width: 30, height: 40),
        ]
        let area = CGRect(x: 0, y: 0, width: 100, height: 80)
        let expanded = KeyboardHitGrid.regions(forFrames: frames, in: area)
        XCTAssertEqual(expanded["a"], CGRect(x: 0, y: 0, width: 45, height: 80))
        XCTAssertEqual(expanded["b"], CGRect(x: 45, y: 0, width: 55, height: 80))
    }
}
