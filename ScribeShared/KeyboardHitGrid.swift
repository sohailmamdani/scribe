import CoreGraphics
import Foundation

/// Converts the *visual* key rectangles into *touch* regions.
///
/// The drawn caps are separated by 6 pt horizontal and 11 pt vertical gaps.
/// Hit-testing against those caps directly — then falling back to "nearest key
/// centre within 30 pt" — had two measured faults:
///
/// 1. Dead zones. Between 3.8% (320 pt wide) and 8.0% (440 pt wide) of the key
///    area resolved to no key at all, so the tap did nothing. They cluster in
///    the gap above the bottom letter row and around the wide Shift and Delete
///    caps, where the row gap crosses an unusually wide column gap.
/// 2. Centre distance under-weights wide keys. Shift's 50 pt cap puts its
///    centre 25 pt from its own right edge while a 37 pt letter sits 18 pt from
///    its left edge, so taps that clearly landed nearer Shift resolved to "z".
///
/// Apple's keyboard has neither: the touch regions tile the whole key area, the
/// outer keys claim the surrounding margin, and ranking follows the boundary
/// the finger actually crossed. This rebuilds that.
enum KeyboardHitGrid {
    /// Touches land slightly below where the user believes they are aiming, so
    /// hit-testing lifts the point before resolving it. Deliberately small —
    /// this compensates for finger geometry, it does not relocate keys.
    static let portraitVerticalTapBias: Double = 2
    static let compactVerticalTapBias: Double = 1

    /// A touch dragged this far beyond every region stops resolving to a key,
    /// so a finger leaving the keyboard clears the pressed state.
    static let maximumOutsideDistance: Double = 44

    /// Expands `frames` so the returned regions tile `bounds` with no gaps.
    /// Rows grow vertically to meet their neighbours and the top/bottom edges;
    /// keys grow horizontally to meet theirs and the left/right edges.
    static func regions<Key: Hashable>(
        forFrames frames: [Key: CGRect],
        in bounds: CGRect
    ) -> [Key: CGRect] {
        guard !frames.isEmpty else { return [:] }
        let rows = rowGroups(frames)
        guard !rows.isEmpty else { return [:] }

        var result: [Key: CGRect] = [:]
        for (rowIndex, row) in rows.enumerated() {
            guard !row.isEmpty else { continue }
            let rowMinY = row.map(\.frame.minY).min() ?? bounds.minY
            let rowMaxY = row.map(\.frame.maxY).max() ?? bounds.maxY

            let top: CGFloat
            if rowIndex == 0 {
                top = min(bounds.minY, rowMinY)
            } else {
                let previousMaxY = rows[rowIndex - 1].map(\.frame.maxY).max() ?? rowMinY
                top = (previousMaxY + rowMinY) / 2
            }

            let bottom: CGFloat
            if rowIndex == rows.count - 1 {
                bottom = max(bounds.maxY, rowMaxY)
            } else {
                let nextMinY = rows[rowIndex + 1].map(\.frame.minY).min() ?? rowMaxY
                bottom = (rowMaxY + nextMinY) / 2
            }

            for (index, entry) in row.enumerated() {
                let left: CGFloat = index == 0
                    ? min(bounds.minX, entry.frame.minX)
                    : (row[index - 1].frame.maxX + entry.frame.minX) / 2
                let right: CGFloat = index == row.count - 1
                    ? max(bounds.maxX, entry.frame.maxX)
                    : (entry.frame.maxX + row[index + 1].frame.minX) / 2

                result[entry.key] = CGRect(
                    x: left,
                    y: top,
                    width: max(0, right - left),
                    height: max(0, bottom - top)
                )
            }
        }
        return result
    }

    static func key<Key: Hashable>(
        at point: CGPoint,
        regions: [Key: CGRect],
        verticalTapBias: Double
    ) -> Key? {
        guard !regions.isEmpty else { return nil }
        let adjusted = CGPoint(x: point.x, y: point.y - CGFloat(verticalTapBias))

        // Regions tile the key area, so an in-bounds touch always lands here.
        // Sorting keeps the result deterministic if two regions ever abut.
        let containing = regions
            .filter { $0.value.contains(adjusted) }
            .min { distance(from: $0.value, to: adjusted) < distance(from: $1.value, to: adjusted) }
        if let containing { return containing.key }

        // Only touches dragged outside the key area reach this.
        let nearest = regions.min {
            distance(from: $0.value, to: adjusted) < distance(from: $1.value, to: adjusted)
        }
        guard let nearest,
              distance(from: nearest.value, to: adjusted) <= CGFloat(maximumOutsideDistance) else {
            return nil
        }
        return nearest.key
    }

    /// Distance from a point to the nearest edge of a rectangle — zero inside.
    /// Centre distance, which this replaces, mis-ranks wide keys against narrow
    /// ones and is why taps near Shift and Delete resolved unpredictably.
    static func distance(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        return hypot(point.x - clampedX, point.y - clampedY)
    }

    private struct Entry<Key: Hashable> {
        let key: Key
        let frame: CGRect
    }

    /// Groups frames into visual rows. Frames whose centre falls inside the
    /// row's vertical extent belong to that row, which keeps Shift and Delete
    /// with the letters they sit beside.
    private static func rowGroups<Key: Hashable>(
        _ frames: [Key: CGRect]
    ) -> [[Entry<Key>]] {
        var entries: [Entry<Key>] = []
        entries.reserveCapacity(frames.count)
        for (key, frame) in frames {
            entries.append(Entry(key: key, frame: frame))
        }
        let sorted: [Entry<Key>] = entries.sorted { lhs, rhs in
            let lhsMidY: CGFloat = lhs.frame.midY
            let rhsMidY: CGFloat = rhs.frame.midY
            if lhsMidY != rhsMidY { return lhsMidY < rhsMidY }
            return lhs.frame.midX < rhs.frame.midX
        }

        var rows: [[Entry<Key>]] = []
        for entry in sorted {
            if let reference = rows.last?.first?.frame,
               entry.frame.midY < reference.maxY {
                rows[rows.count - 1].append(entry)
            } else {
                rows.append([entry])
            }
        }
        return rows.map { $0.sorted { $0.frame.midX < $1.frame.midX } }
    }
}
