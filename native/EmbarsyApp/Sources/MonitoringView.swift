import Charts
import SwiftUI

struct MonitoringView: View {
    @EnvironmentObject private var store: EmbarsyStore
    /// Observed directly (not through the store) so only Monitoring re-renders on its
    /// own 2s ticks — the store no longer re-broadcasts these services' changes.
    @ObservedObject var monitoring: MonitoringService
    @ObservedObject var contentIndex: ContentIndexService
    @ObservedObject var sysMetrics: SystemMetricsService
    @State private var selectedScale: MonitoringScale = .hour1
    @State private var refreshInterval: RefreshInterval = .s2
    @State private var busy = false
    @State private var openMenu: OpenMenu? = nil

    private enum OpenMenu { case range, refresh }
    /// Fixed width for the refresh dropdown; the range dropdown instead matches its pill width.
    private let refreshMenuWidth: CGFloat = 184

    private func toggle(_ menu: OpenMenu) { openMenu = (openMenu == menu) ? nil : menu }

    var body: some View {
        VStack(spacing: 0) {
            // Header + chart controls stay pinned so the range / refresh can be changed while
            // scrolling the lower panels.
            BrandedHeader(title: "Monitoring", subtitle: "Counted at the Embarsy Qdrant proxy boundary.") {
                rangeControls
            }
            .padding(.horizontal, Theme.padScreen)
            .padding(.top, Theme.padScreen)
            .padding(.bottom, 14)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }

            ScrollView {
                // Lazy: collapsed/off-screen panels are not laid out on every data tick.
                LazyVStack(alignment: .leading, spacing: Theme.gapSection) {
                MonitorRowHeader(id: "overview", title: "OVERVIEW") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                        ForEach(metricTiles) { StatPanel(tile: $0).equatable() }
                    }
                }

                CollapsiblePanel(id: "rw", title: "Read / write activity", meta: "events / bucket") {
                    ActivityLinesChart(series: monitoring.snapshot.series, domain: xDomain)
                        .equatable()
                    legend.padding(.top, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1).offset(y: -1) }
                }

                CollapsiblePanel(id: "latency", title: "Embedding latency", meta: "ms") {
                    LatencyChart(series: monitoring.snapshot.series, domain: xDomain)
                        .equatable()
                }

                CollapsiblePanel(id: "memcpu", title: "Memory / CPU utilisation", meta: "GB / %") {
                    let w = memCpuWindow
                    if w.mem.count >= 2 {
                        DualAxisChart(mem: w.mem, cpu: w.cpu, dates: w.dates,
                                      domainStart: windowStart, domainEnd: domainEnd,
                                      leftColor: Theme.mReads, rightColor: Theme.mErrors)
                            .equatable()
                            .frame(height: 220)
                        HStack {
                            legendSwatch("memory \(String(format: "%.2f", sysMetrics.lastMemGB)) GB", color: Theme.mReads)
                            Spacer()
                            legendSwatch("cpu \(String(format: "%.0f", sysMetrics.lastCPU))%", color: Theme.mErrors)
                        }
                        .padding(.top, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Theme.separator).frame(height: 1).offset(y: -1) }
                    } else {
                        Text(sysMetrics.processCount == 0
                             ? "No Embarsy processes detected. Start the stack (Status \u{2192} Start All) to see live memory and CPU for qdrant, ollama and the API."
                             : "Sampling process metrics\u{2026}")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(height: 100).frame(maxWidth: .infinity)
                    }
                }

                CollapsiblePanel(id: "temp", title: "CPU temperature", meta: "°C") {
                    if let t = sysMetrics.lastTempC {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(format: "%.1f", t))
                                .font(.system(size: 21, weight: .bold).monospacedDigit())
                                .foregroundStyle(Theme.mTemp)
                            Text("°C").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.mTemp.opacity(0.8))
                            Spacer()
                        }
                    }
                    if sysMetrics.tempSeries.count >= 2 {
                        let w = tempWindow
                        TemperatureChart(dates: w.dates, values: w.values, domain: xDomain)
                            .equatable()
                    } else {
                        Text(sysMetrics.lastTempC == nil
                             ? "CPU temperature sensors aren\u{2019}t available on this Mac."
                             : "Sampling temperature\u{2026}")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(height: 100).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("CPU die temperature is read from the on-chip thermal sensors (average of the per-cluster PMU sensors), the same source as Stats / macmon \u{2014} no sudo required.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Qdrant read/write counters are counted at the Embarsy Qdrant proxy boundary. Memory / CPU reflect the live qdrant, ollama and Embarsy API processes. If reads/writes stay at zero while Watcher searches, point the Qdrant URL at the Embarsy proxy, not :6333 directly.")
                    .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.padScreen)
                .padding(.top, Theme.gapSection)
                .padding(.bottom, Theme.padScreen)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Custom dropdowns, drawn above everything (including the ScrollView) and positioned
        // from each pill's captured bounds. The range dropdown matches its pill's width; the
        // refresh dropdown is right-aligned to its pill so it stays inside the window edge.
        .overlayPreferenceValue(MenuAnchorsKey.self) { anchors in
            if let openMenu {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        Color.clear.contentShape(Rectangle())
                            .onTapGesture { self.openMenu = nil }
                        if openMenu == .range, let a = anchors.range {
                            let r = proxy[a]
                            rangeDropdownCard(width: r.width)
                                .offset(x: r.minX, y: r.maxY + 6)
                        }
                        if openMenu == .refresh, let a = anchors.refresh {
                            let r = proxy[a]
                            RefreshDropdownCard(interval: $refreshInterval, width: refreshMenuWidth,
                                                onRefreshNow: { refreshNow() },
                                                onSelect: { self.openMenu = nil })
                                .offset(x: max(0, r.maxX - refreshMenuWidth), y: r.maxY + 6)
                        }
                    }
                }
            }
        }
        .task(id: refreshInterval) {
            selectedScale = monitoring.scale
            // The "Points indexed" tile reads the Content service — populate it once if
            // the user opens Monitoring before ever visiting Content (it used to show 0).
            if contentIndex.snapshot.collections.isEmpty {
                await store.refreshContentIndex()
            }
            // Sleep in short slices and track the last fetch: while the window is
            // closed/minimized/covered nothing is fetched (nobody can see the result),
            // and on becoming visible again the next ≤2s slice refreshes immediately
            // instead of waiting out a full interval.
            var lastRefresh = Date.distantPast
            while !Task.isCancelled {
                if WindowVisibility.mainWindowVisible,
                   Date().timeIntervalSince(lastRefresh) >= refreshInterval.seconds {
                    busy = true
                    await store.refreshMonitoring()
                    busy = false
                    lastRefresh = Date()
                }
                try? await Task.sleep(
                    for: .seconds(min(2, refreshInterval.seconds)),
                    tolerance: .milliseconds(500)
                )
            }
        }
    }

    // MARK: Range / refresh controls

    private var rangeControls: some View {
        HStack(spacing: 8) {
            Button { toggle(.range) } label: {
                pill(icon: "clock", text: selectedScale.rangeLabel, open: openMenu == .range,
                     sizeToWidest: MonitoringScale.allCases.map(\.rangeLabel))
            }
            .buttonStyle(.plain).fixedSize()
            .anchorPreference(key: MenuAnchorsKey.self, value: .bounds) { MenuAnchors(range: $0) }

            Button { toggle(.refresh) } label: {
                RefreshPillLabel(short: refreshInterval.short, busy: busy, open: openMenu == .refresh)
            }
            .buttonStyle(.plain).fixedSize()
            .anchorPreference(key: MenuAnchorsKey.self, value: .bounds) { MenuAnchors(refresh: $0) }
        }
    }

    private func refreshNow() {
        Task {
            busy = true
            await store.refreshMonitoring()
            await sysMetrics.sample(rootPIDs: store.processManager.runningPIDs, config: store.config, watching: true)
            busy = false
        }
    }

    private func pill(icon: String, text: String, open: Bool = false, sizeToWidest labels: [String] = []) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            ZStack(alignment: .leading) {
                // Hidden copies of every option keep the pill (and the pill-width dropdown) a
                // constant width = the widest label, so no row truncates when a short one is picked.
                ForEach(labels, id: \.self) { Text($0).font(.system(size: 12, weight: .semibold)).hidden() }
                Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            }
            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 12).frame(height: 36)
        .background(Theme.fillQuaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator))
    }

    // MARK: Range dropdown (custom; width matches the trigger pill)

    private func rangeDropdownCard(width: CGFloat) -> some View {
        DropdownCard(width: width) {
            DropdownHeader(text: "Time range")
            ForEach(MonitoringScale.allCases) { scale in
                DropdownRow(label: scale.rangeLabel, selected: selectedScale == scale) {
                    selectedScale = scale
                    monitoring.scale = scale
                    openMenu = nil
                    // The service cancel-and-replaces any in-flight poll, so the new
                    // scale's data always lands (the old guard could drop this fetch).
                    Task { await store.refreshMonitoring() }
                }
            }
        }
    }

    // MARK: Metric tiles

    /// Sparkline budget per tile — min/max decimation keeps every visible peak, so the
    /// rendered line matches the full series at the 44pt sparkline's resolution.
    private static let sparkPoints = 120

    private var metricTiles: [MetricTile] {
        let s = monitoring.snapshot.summary
        let series = monitoring.snapshot.series
        func spark(_ f: (MonitoringPoint) -> Double) -> [SparkPoint] {
            ChartDownsample.minMaxPoints(series.map(f), to: Self.sparkPoints)
        }
        func spark(_ values: [Double]) -> [SparkPoint] {
            ChartDownsample.minMaxPoints(values, to: Self.sparkPoints)
        }
        let points = contentIndex.snapshot.collections.reduce(0) { $0 + $1.pointsCount }
        return [
            MetricTile(title: "Embedding requests", value: s.embeddingsRequests.formatted(), color: Theme.mRequests, spark: spark { Double($0.embeddingsRequests) }),
            MetricTile(title: "Vectors generated", value: s.embeddingsVectors.formatted(), color: Theme.mVectors, spark: spark { Double($0.embeddingsVectors) }),
            MetricTile(title: "Avg latency", value: String(format: "%.0f ms", s.embeddingsLatencyMSAverage), color: Theme.mLatency, spark: spark { $0.embeddingsLatencyMSAverage }),
            MetricTile(title: "Embedding errors", value: s.embeddingsErrors.formatted(), color: Theme.mErrors, spark: spark { Double($0.embeddingsErrors) }),
            MetricTile(title: "Qdrant reads", value: s.qdrantReads.formatted(), color: Theme.mReads, spark: spark { Double($0.qdrantReads) }),
            MetricTile(title: "Qdrant writes", value: s.qdrantWrites.formatted(), color: Theme.mWrites, spark: spark { Double($0.qdrantWrites) }),
            MetricTile(title: "Points indexed", value: points.formatted(), color: Theme.accent, spark: spark { Double($0.embeddingsVectors) }),
            MetricTile(title: "Memory", value: String(format: "%.2f GB", sysMetrics.lastMemGB), color: Theme.mReads, spark: spark(sysMetrics.memSeries)),
            MetricTile(title: "CPU", value: String(format: "%.0f %%", sysMetrics.lastCPU), color: Theme.mErrors, spark: spark(sysMetrics.cpuSeries)),
            MetricTile(title: "Temperature", value: sysMetrics.lastTempC.map { String(format: "%.1f °C", $0) } ?? "\u{2014}", color: Theme.mTemp, spark: spark(sysMetrics.tempSeries)),
        ]
    }

    // MARK: Charts

    private var domainEnd: Date {
        monitoring.snapshot.now > 0
            ? Date(timeIntervalSince1970: TimeInterval(monitoring.snapshot.now)) : Date()
    }
    private var xDomain: ClosedRange<Date> {
        domainEnd.addingTimeInterval(-Double(selectedScale.rawValue))...domainEnd
    }

    // Local Memory / CPU / temperature samples windowed to the selected time scale.
    private var windowStart: Date { domainEnd.addingTimeInterval(-Double(selectedScale.rawValue)) }

    /// Cap on the windowed client-side series — the raw buffer holds up to 1800 samples,
    /// which used to become ~1800 marks per chart at large scales.
    private static let windowPoints = 300

    private var memCpuWindow: (dates: [Date], mem: [Double], cpu: [Double]) {
        let dates = sysMetrics.sampleDates
        let end = min(dates.count, sysMetrics.memSeries.count, sysMetrics.cpuSeries.count)
        let cut = dates.firstIndex(where: { $0 >= windowStart }) ?? end
        guard cut < end else { return ([], [], []) }
        let mem = Array(sysMetrics.memSeries[cut..<end])
        let cpu = Array(sysMetrics.cpuSeries[cut..<end])
        let ds = Array(dates[cut..<end])
        // One shared index set keeps mem/cpu date-aligned while preserving both series' peaks.
        let idx = ChartDownsample.minMaxIndices(count: ds.count, maxPoints: Self.windowPoints, series: [mem, cpu])
        guard idx.count < ds.count else { return (ds, mem, cpu) }
        return (idx.map { ds[$0] }, idx.map { mem[$0] }, idx.map { cpu[$0] })
    }

    private var tempWindow: (dates: [Date], values: [Double]) {
        let dates = sysMetrics.tempDates
        let end = min(dates.count, sysMetrics.tempSeries.count)
        let cut = dates.firstIndex(where: { $0 >= windowStart }) ?? end
        guard cut < end else { return ([], []) }
        let values = Array(sysMetrics.tempSeries[cut..<end])
        let ds = Array(dates[cut..<end])
        let idx = ChartDownsample.minMaxIndices(count: ds.count, maxPoints: Self.windowPoints, series: [values])
        guard idx.count < ds.count else { return (ds, values) }
        return (idx.map { ds[$0] }, idx.map { values[$0] })
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendSwatch("Qdrant reads", color: Theme.mReads)
            legendSwatch("Qdrant writes", color: Theme.mWrites)
            legendSwatch("Embedding vectors", color: Theme.mVectors)
            legendSwatch("Embedding errors", color: Theme.mErrors, dashed: true)
        }
    }

    private func legendSwatch(_ label: String, color: Color, dashed: Bool = false) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 14, height: 2).opacity(dashed ? 0.9 : 1)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

}

// MARK: - Extracted Equatable charts
//
// Each chart is a standalone value-only view mounted with `.equatable()`: SwiftUI skips its
// (expensive) body when the data and domain haven't changed — in particular on every scroll
// frame and on unrelated state changes, which used to re-lay-out all charts at once.

private struct MonitoringAxisMarks {
    static var y: some AxisContent {
        AxisMarks(position: .trailing) { _ in
            AxisGridLine().foregroundStyle(Theme.separator)
            AxisValueLabel().font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.accent)
        }
    }
    static var x: some AxisContent {
        AxisMarks { _ in
            AxisGridLine().foregroundStyle(Theme.separator)
            AxisValueLabel().font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.accent)
        }
    }
}

private struct ActivityLinesChart: View, Equatable {
    let series: [MonitoringPoint]
    let domain: ClosedRange<Date>

    private enum Series {
        static let reads = "Qdrant reads", writes = "Qdrant writes", vectors = "Embedding vectors", errors = "Embedding errors"
    }
    private static let colorScale: KeyValuePairs<String, Color> = [
        Series.reads: Theme.mReads, Series.writes: Theme.mWrites, Series.vectors: Theme.mVectors, Series.errors: Theme.mErrors,
    ]

    var body: some View {
        Chart(series) { point in
            LineMark(x: .value("Time", point.date), y: .value(Series.reads, point.qdrantReads)).foregroundStyle(by: .value("Metric", Series.reads))
            LineMark(x: .value("Time", point.date), y: .value(Series.writes, point.qdrantWrites)).foregroundStyle(by: .value("Metric", Series.writes))
            LineMark(x: .value("Time", point.date), y: .value(Series.vectors, point.embeddingsVectors)).foregroundStyle(by: .value("Metric", Series.vectors))
            LineMark(x: .value("Time", point.date), y: .value(Series.errors, point.embeddingsErrors)).foregroundStyle(by: .value("Metric", Series.errors))
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
        }
        .chartForegroundStyleScale(Self.colorScale)
        .chartLegend(.hidden)
        .chartYAxis { MonitoringAxisMarks.y }
        .chartXAxis { MonitoringAxisMarks.x }
        .chartXScale(domain: domain)
        .frame(height: 210)
    }
}

private struct LatencyChart: View, Equatable {
    let series: [MonitoringPoint]
    let domain: ClosedRange<Date>

    var body: some View {
        Chart(series) { point in
            LineMark(x: .value("Time", point.date), y: .value("Latency", point.embeddingsLatencyMSAverage))
                .foregroundStyle(Theme.mLatency)
                .interpolationMethod(.monotone)
        }
        .chartYAxis { MonitoringAxisMarks.y }
        .chartXAxis { MonitoringAxisMarks.x }
        .chartXScale(domain: domain)
        .frame(height: 180)
    }
}

private struct TemperatureChart: View, Equatable {
    let dates: [Date]
    let values: [Double]
    let domain: ClosedRange<Date>

    var body: some View {
        let pts = Array(zip(dates, values).enumerated())   // (offset, (Date, °C))
        let lo = (values.min() ?? 40) - 3
        let hi = (values.max() ?? 60) + 3
        let yMin = max(0, (lo / 5).rounded(.down) * 5)
        let yMax = max(yMin + 5, (hi / 5).rounded(.up) * 5)
        return Chart(pts, id: \.offset) { row in
            // Fill from the domain floor (not the default y=0 baseline, which sits below the
            // 40…55 domain and bleeds past the plot on macOS Swift Charts).
            AreaMark(x: .value("time", row.element.0), yStart: .value("min", yMin), yEnd: .value("°C", row.element.1))
                .foregroundStyle(LinearGradient(colors: [Theme.mTemp.opacity(0.30), Theme.mTemp.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("time", row.element.0), y: .value("°C", row.element.1))
                .foregroundStyle(Theme.mTemp)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: yMin...yMax)
        .chartYAxis { MonitoringAxisMarks.y }
        .chartXAxis { MonitoringAxisMarks.x }
        .chartXScale(domain: domain)
        .frame(height: 140)
    }
}

// MARK: - Stat tile

struct MetricTile: Identifiable, Equatable {
    let title: String
    let value: String
    let color: Color
    let spark: [SparkPoint]
    var id: String { title }
}

private struct StatPanel: View, Equatable {
    let tile: MetricTile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(tile.title)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(tile.value)
                    .font(.system(size: 21, weight: .bold).monospacedDigit())
                    .foregroundStyle(tile.color)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13).padding(.top, 11)
            Spacer(minLength: 4)
            sparkline.frame(height: 44)
        }
        .frame(height: 112, alignment: .top)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.separator))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var sparkline: some View {
        if tile.spark.count >= 2 {
            Chart(tile.spark, id: \.x) { point in
                AreaMark(x: .value("i", point.x), y: .value("v", point.y))
                    .foregroundStyle(LinearGradient(colors: [tile.color.opacity(0.30), tile.color.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("i", point.x), y: .value("v", point.y))
                    .foregroundStyle(tile.color)
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
            // Pure vector + gradient, no text: safe to rasterize into one layer.
            .drawingGroup()
        } else {
            Color.clear
        }
    }
}

// MARK: - Collapsible panel + row header (persisted)

private struct CollapsiblePanel<Content: View>: View {
    let id: String
    let title: String
    var meta: String?
    @AppStorage private var open: Bool
    @ViewBuilder var content: () -> Content

    init(id: String, title: String, meta: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.id = id; self.title = title; self.meta = meta; self.content = content
        _open = AppStorage(wrappedValue: true, "emb.monitor.\(id)")
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.system(size: 13)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                    Spacer()
                    if let meta { Text(meta).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary) }
                }
                .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, open ? 7 : 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusXl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusXl, style: .continuous).stroke(Theme.separator))
    }
}

private struct MonitorRowHeader<Content: View>: View {
    let id: String
    let title: String
    @AppStorage private var open: Bool
    @ViewBuilder var content: () -> Content

    init(id: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id; self.title = title; self.content = content
        _open = AppStorage(wrappedValue: true, "emb.monitor.row.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down").font(.system(size: 13)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 0 : -90))
                    Text(title).font(.system(size: 12, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.bottom, 7)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content() }
        }
    }
}

// MARK: - Dual-axis Memory/CPU chart (Canvas: mem area on left scale, cpu line on right)

private struct DualAxisChart: View, Equatable {
    let mem: [Double]     // GB
    let cpu: [Double]     // %
    let dates: [Date]     // timestamps aligned with mem/cpu
    let domainStart: Date // left edge = now − selected scale
    let domainEnd: Date   // right edge = now
    let leftColor: Color
    let rightColor: Color

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.domainStart == rhs.domainStart && lhs.domainEnd == rhs.domainEnd
            && lhs.mem == rhs.mem && lhs.cpu == rhs.cpu && lhs.dates == rhs.dates
    }

    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    var body: some View {
        Canvas { ctx, size in
            let leftLabelW: CGFloat = 32, rightLabelW: CGFloat = 26, gap: CGFloat = 6, xLabelH: CGFloat = 16
            let plotX = leftLabelW + gap
            let plotW = max(1, size.width - leftLabelW - rightLabelW - gap * 2)
            let plotTop: CGFloat = 6
            let plotH = max(1, size.height - xLabelH - plotTop)
            let leftMax = max(1.0, (mem.max() ?? 1) * 1.15)
            let rightMax = max(100.0, ((cpu.max() ?? 0) / 100).rounded(.up) * 100)
            let n = min(mem.count, cpu.count, dates.count)
            let span = max(1, domainEnd.timeIntervalSince(domainStart))

            // X is positioned by timestamp within the selected scale window, so the chart
            // respects the time-range picker like the activity / latency charts do.
            func x(_ d: Date) -> CGFloat { plotX + CGFloat(d.timeIntervalSince(domainStart) / span) * plotW }
            func ly(_ v: Double) -> CGFloat { plotTop + (1 - CGFloat(v / leftMax)) * plotH }
            func ry(_ v: Double) -> CGFloat { plotTop + (1 - CGFloat(v / rightMax)) * plotH }

            // gridlines (6 divisions) + Y labels
            for t in 0...6 {
                let frac = CGFloat(t) / 6
                let yy = plotTop + (1 - frac) * plotH
                var g = Path(); g.move(to: CGPoint(x: plotX, y: yy)); g.addLine(to: CGPoint(x: plotX + plotW, y: yy))
                ctx.stroke(g, with: .color(Theme.separator), lineWidth: 1)
                let leftVal = leftMax * Double(frac)
                let rightVal = rightMax * Double(frac)
                ctx.draw(Text(String(format: leftVal >= 10 ? "%.0f" : "%.1f", leftVal))
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.accent),
                    at: CGPoint(x: leftLabelW - 2, y: yy), anchor: .trailing)
                ctx.draw(Text("\(Int(rightVal))")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.accent),
                    at: CGPoint(x: plotX + plotW + 4, y: yy), anchor: .leading)
            }

            // X-axis time labels from the selected scale (start · mid · end) in the brand colour
            let yLabel = plotTop + plotH + 10
            let mid = domainStart.addingTimeInterval(span / 2)
            ctx.draw(Text(Self.timeFmt.string(from: domainStart)).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.accent),
                     at: CGPoint(x: plotX, y: yLabel), anchor: .leading)
            ctx.draw(Text(Self.timeFmt.string(from: mid)).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.accent),
                     at: CGPoint(x: plotX + plotW / 2, y: yLabel), anchor: .center)
            ctx.draw(Text(Self.timeFmt.string(from: domainEnd)).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.accent),
                     at: CGPoint(x: plotX + plotW, y: yLabel), anchor: .trailing)

            guard n >= 2 else { return }

            // memory area + line (left scale)
            var area = Path()
            area.move(to: CGPoint(x: x(dates[0]), y: ly(mem[0])))
            for i in 1..<n { area.addLine(to: CGPoint(x: x(dates[i]), y: ly(mem[i]))) }
            area.addLine(to: CGPoint(x: x(dates[n - 1]), y: plotTop + plotH))
            area.addLine(to: CGPoint(x: x(dates[0]), y: plotTop + plotH))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [leftColor.opacity(0.26), leftColor.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: plotTop), endPoint: CGPoint(x: 0, y: plotTop + plotH)))
            var memLine = Path()
            memLine.move(to: CGPoint(x: x(dates[0]), y: ly(mem[0])))
            for i in 1..<n { memLine.addLine(to: CGPoint(x: x(dates[i]), y: ly(mem[i]))) }
            ctx.stroke(memLine, with: .color(leftColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

            // cpu line (right scale)
            var cpuLine = Path()
            cpuLine.move(to: CGPoint(x: x(dates[0]), y: ry(cpu[0])))
            for i in 1..<n { cpuLine.addLine(to: CGPoint(x: x(dates[i]), y: ry(cpu[i]))) }
            ctx.stroke(cpuLine, with: .color(rightColor), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}
