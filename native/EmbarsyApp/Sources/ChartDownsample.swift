import Foundation

/// Min/max-preserving decimation for chart series. Splitting the sample range into
/// buckets and keeping each bucket's extremes (in time order) caps the mark count a
/// chart has to lay out while keeping every visible peak — the rendered line is
/// pixel-equivalent to the full series at chart resolution.
enum ChartDownsample {
    /// Indices to keep so that every series in `series` retains its per-bucket min and
    /// max. Result is sorted and unique; identity when `count <= maxPoints`.
    static func minMaxIndices(count: Int, maxPoints: Int, series: [[Double]]) -> [Int] {
        guard count > maxPoints, maxPoints > 0, !series.isEmpty else {
            return Array(0..<count)
        }
        // Each bucket contributes up to (2 × series.count) indices before dedup.
        let buckets = max(1, maxPoints / (2 * series.count))
        var keep = Set<Int>()
        for b in 0..<buckets {
            // Integer bucket boundaries: floating-point math could round the final
            // boundary below `count` and silently drop the newest sample.
            let start = b * count / buckets
            let end = b == buckets - 1 ? count : (b + 1) * count / buckets
            guard start < end else { continue }
            for values in series {
                var minIdx = start, maxIdx = start
                for i in start..<end {
                    if values[i] < values[minIdx] { minIdx = i }
                    if values[i] > values[maxIdx] { maxIdx = i }
                }
                keep.insert(minIdx)
                keep.insert(maxIdx)
            }
            // Always keep bucket edges so the line's time coverage has no visible gaps.
            keep.insert(start)
            keep.insert(end - 1)
        }
        return keep.sorted()
    }

    /// Single-series convenience (sparklines). Keeps each point's ORIGINAL index so the
    /// x-axis stays proportional to time — plotting decimated values by enumeration
    /// offset would compress busy stretches and stretch quiet ones.
    static func minMaxPoints(_ values: [Double], to maxPoints: Int) -> [SparkPoint] {
        minMaxIndices(count: values.count, maxPoints: maxPoints, series: [values])
            .map { SparkPoint(x: $0, y: values[$0]) }
    }
}

struct SparkPoint: Equatable {
    let x: Int      // index in the original (undecimated) series
    let y: Double
}
