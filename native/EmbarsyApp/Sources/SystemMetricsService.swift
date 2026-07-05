import Foundation

/// Samples live CPU% / memory (GB) / temperature (°C) of the Embarsy processes
/// (qdrant, ollama, embarsy-api) and keeps rolling windows for the Monitoring charts.
///
/// PIDs come straight from the app's own `ProcessManager` (the app launches these
/// processes, so it knows their PIDs) plus every descendant — ollama's `llama-server`
/// child holds the model's memory. `lsof`-by-port is only a fallback for externally
/// started stacks.
///
/// CPU is the **current whole-system load** — the busy-tick share (user+system+nice vs
/// idle) from Mach `host_statistics(HOST_CPU_LOAD_INFO)` between samples, i.e. the live
/// 0–100% the OS reports right now, not a lifetime average. Memory stays the Embarsy
/// processes' RSS. Temperature is the average CPU die sensor via `CPUTemperature`.
@MainActor
final class SystemMetricsService: ObservableObject {
    @Published private(set) var cpuSeries: [Double] = []   // percent (sum across processes)
    @Published private(set) var memSeries: [Double] = []   // gigabytes (RSS sum)
    @Published private(set) var tempSeries: [Double] = []   // °C (CPU die average)
    @Published private(set) var lastCPU: Double = 0
    @Published private(set) var lastMemGB: Double = 0
    @Published private(set) var lastTempC: Double?          // nil when sensors unavailable
    @Published private(set) var processCount: Int = 0
    @Published private(set) var sampleDates: [Date] = []    // timestamps aligned with mem/cpu series
    @Published private(set) var tempDates: [Date] = []      // timestamps aligned with tempSeries

    private let maxPoints = 1800   // rolling buffer; the view windows it to the selected time scale
    private var prevCPUTicks: CPUTicks?   // previous whole-system CPU tick counters

    struct ProcSample { let pid: Int32; let rssKB: Double }
    struct CPUTicks { let user: Double; let system: Double; let idle: Double; let nice: Double }

    func sample(rootPIDs: [Int32], config: EmbarsyConfig) async {
        let ports = [config.qdrantRestPort, config.qdrantGrpcPort, 11434, config.apiPort]
        let (procs, temp, ticks) = await Task.detached(priority: .utility) { () -> ([ProcSample], Double?, CPUTicks?) in
            var roots = rootPIDs
            if roots.isEmpty { roots = Self.pids(onPorts: ports) }   // fallback: externally started stack
            return (Self.treeStats(roots: roots), CPUTemperature.read(), Self.systemCPUTicks())
        }.value

        let now = Date()
        processCount = procs.count
        let memGB = procs.reduce(0) { $0 + $1.rssKB } / 1024.0 / 1024.0

        // Whole-system CPU load right now = share of busy ticks since the previous sample.
        var cpu = lastCPU
        if let ticks {
            if let prev = prevCPUTicks {
                let user = max(0, ticks.user - prev.user)
                let system = max(0, ticks.system - prev.system)
                let nice = max(0, ticks.nice - prev.nice)
                let idle = max(0, ticks.idle - prev.idle)
                let total = user + system + nice + idle
                cpu = total > 0 ? (user + system + nice) / total * 100.0 : 0
            }
            prevCPUTicks = ticks
        }

        lastCPU = cpu
        lastMemGB = memGB
        cpuSeries.append(cpu)
        memSeries.append(memGB)
        sampleDates.append(now)
        trim(&cpuSeries)
        trim(&memSeries)
        trim(&sampleDates)

        lastTempC = temp
        if let temp { tempSeries.append(temp); tempDates.append(now); trim(&tempSeries); trim(&tempDates) }
    }

    private func trim<T>(_ arr: inout [T]) {
        if arr.count > maxPoints { arr.removeFirst(arr.count - maxPoints) }
    }

    // MARK: - Shell helpers (run off the main actor)

    /// Root PIDs + all descendants, with RSS, from a single `ps -A`.
    private nonisolated static func treeStats(roots: [Int32]) -> [ProcSample] {
        guard !roots.isEmpty else { return [] }
        let out = runShell("/bin/ps", ["-A", "-o", "pid=,ppid=,rss="])
        var info: [Int32: Double] = [:]   // pid → RSS KB
        var children: [Int32: [Int32]] = [:]
        for line in out.split(separator: "\n") {
            let cols = line.split(whereSeparator: { $0 == " " }).filter { !$0.isEmpty }
            guard cols.count >= 3, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            info[pid] = Double(cols[2]) ?? 0
            children[ppid, default: []].append(pid)
        }
        // BFS from the roots to collect the whole process tree.
        var target = Set<Int32>()
        var queue = roots
        while let pid = queue.popLast() {
            guard !target.contains(pid) else { continue }
            target.insert(pid)
            if let kids = children[pid] { queue.append(contentsOf: kids) }
        }
        return target.compactMap { pid in
            info[pid].map { ProcSample(pid: pid, rssKB: $0) }
        }
    }

    /// Cumulative whole-system CPU tick counters via Mach `host_statistics`.
    private nonisolated static func systemCPUTicks() -> CPUTicks? {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return CPUTicks(user: Double(info.cpu_ticks.0), system: Double(info.cpu_ticks.1),
                        idle: Double(info.cpu_ticks.2), nice: Double(info.cpu_ticks.3))
    }

    private nonisolated static func pids(onPorts ports: [Int]) -> [Int32] {
        var found = Set<Int32>()
        for port in ports {
            let out = runShell("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
            for line in out.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) { found.insert(pid) }
            }
        }
        return Array(found)
    }

    private nonisolated static func runShell(_ path: String, _ args: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: path) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
