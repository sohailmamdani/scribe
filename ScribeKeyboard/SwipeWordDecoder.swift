import CoreGraphics
import Foundation

/// Decodes the sequence of QWERTY keys traversed by a swipe gesture into the
/// most likely English word, using a frequency-ordered lexicon bundled with
/// the keyboard. Candidates are scored by comparing the swipe's path shape
/// against each word's ideal key-to-key path (SHARK2-style), weighted by
/// word frequency.
final class SwipeWordDecoder {
    static let shared = SwipeWordDecoder(words: SwipeWordDecoder.loadBundledWords())

    private struct Entry {
        let text: String
        let letters: [Character]
        let rank: Int
        /// Ideal path through the word's key positions, consecutive
        /// duplicate letters collapsed.
        let path: [CGPoint]
    }

    private static let sampleCount = 32

    private let entriesByFirstLetter: [Character: [Entry]]

    /// Unit-grid positions of each letter on a QWERTY layout (key width = 1).
    private static let keyPositions: [Character: CGPoint] = {
        var positions: [Character: CGPoint] = [:]
        for (rowIndex, row) in ["qwertyuiop", "asdfghjkl", "zxcvbnm"].enumerated() {
            let rowOffset = [0.0, 0.5, 1.5][rowIndex]
            for (column, letter) in row.enumerated() {
                positions[letter] = CGPoint(x: Double(column) + rowOffset, y: Double(rowIndex))
            }
        }
        return positions
    }()

    init(words: [String]) {
        var buckets: [Character: [Entry]] = [:]
        var rank = 0
        for word in words {
            guard word.count >= 2, word.allSatisfy({ $0.isLetter && $0.isLowercase }) else { continue }
            rank += 1
            let letters = Array(word)
            var path: [CGPoint] = []
            for letter in letters {
                guard let position = Self.keyPositions[letter] else { break }
                if path.last != position { path.append(position) }
            }
            guard !path.isEmpty else { continue }
            buckets[letters[0], default: []].append(
                Entry(text: word, letters: letters, rank: rank, path: path)
            )
        }
        entriesByFirstLetter = buckets
    }

    private static func loadBundledWords() -> [String] {
        guard let url = Bundle.main.url(forResource: "SwipeWords", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return contents.split(separator: "\n").map(String.init)
    }

    static func areNeighbors(_ a: Character, _ b: Character) -> Bool {
        guard let pa = keyPositions[a], let pb = keyPositions[b] else { return false }
        let dx = pa.x - pb.x
        let dy = pa.y - pb.y
        return dx * dx + dy * dy <= 2.25
    }

    /// `keys` is the deduplicated sequence of letter keys the finger passed
    /// over, in order. Returns the best-scoring word, or nil if nothing in the
    /// lexicon plausibly matches.
    func decode(keys: [Character]) -> String? {
        guard keys.count >= 2, let firstKey = keys.first, let lastKey = keys.last else { return nil }
        let swipePath = Self.resample(keys.compactMap { Self.keyPositions[$0] })
        guard !swipePath.isEmpty else { return nil }

        var firstLetters: Set<Character> = [firstKey]
        for letter in Self.keyPositions.keys where Self.areNeighbors(firstKey, letter) {
            firstLetters.insert(letter)
        }

        var best: (word: String, score: Double)?
        for firstLetter in firstLetters {
            for entry in entriesByFirstLetter[firstLetter] ?? [] {
                let lastLetter = entry.letters[entry.letters.count - 1]
                guard lastLetter == lastKey || Self.areNeighbors(lastLetter, lastKey) else { continue }

                let idealPath = Self.resample(entry.path)
                let shapeDistance = Self.meanDistance(swipePath, idealPath)
                guard shapeDistance < 1.8 else { continue }

                // Endpoints carry extra weight: users are most precise on the
                // keys they start and finish on.
                let startDistance = Double(hypot(swipePath[0].x - idealPath[0].x,
                                                 swipePath[0].y - idealPath[0].y))
                let endIndex = Self.sampleCount - 1
                let endDistance = Double(hypot(swipePath[endIndex].x - idealPath[endIndex].x,
                                               swipePath[endIndex].y - idealPath[endIndex].y))

                var score = -shapeDistance * 2.5
                score -= (startDistance + endDistance) * 1.2
                score += 3.0 * (1.0 - log10(Double(entry.rank) + 1.0) / 4.5)

                if best == nil || score > best!.score {
                    best = (entry.text, score)
                }
            }
        }
        return best?.word
    }

    /// Resamples a polyline to `sampleCount` points equidistant in arc length.
    private static func resample(_ points: [CGPoint]) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 1 else {
            return [CGPoint](repeating: first, count: sampleCount)
        }

        var cumulative: [CGFloat] = [0]
        cumulative.reserveCapacity(points.count)
        for index in 1..<points.count {
            let step = hypot(points[index].x - points[index - 1].x,
                             points[index].y - points[index - 1].y)
            cumulative.append(cumulative[index - 1] + step)
        }
        let total = cumulative[points.count - 1]
        guard total > 0 else {
            return [CGPoint](repeating: first, count: sampleCount)
        }

        var result: [CGPoint] = []
        result.reserveCapacity(sampleCount)
        var segment = 1
        for sample in 0..<sampleCount {
            let target = total * CGFloat(sample) / CGFloat(sampleCount - 1)
            while segment < points.count - 1, cumulative[segment] < target {
                segment += 1
            }
            let segmentLength = max(cumulative[segment] - cumulative[segment - 1], 0.0001)
            let t = (target - cumulative[segment - 1]) / segmentLength
            let a = points[segment - 1]
            let b = points[segment]
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }

    private static func meanDistance(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        var sum = 0.0
        for index in 0..<sampleCount {
            sum += Double(hypot(a[index].x - b[index].x, a[index].y - b[index].y))
        }
        return sum / Double(sampleCount)
    }
}
