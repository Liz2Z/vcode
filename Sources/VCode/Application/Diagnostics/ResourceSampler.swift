import Foundation
import Darwin

struct ProcessResourceSample {
    let pid: pid_t
    let name: String
    let startedAt: UInt64
    let userTime: UInt64
    let systemTime: UInt64
    let memory: UInt64
    let threads: Int?
}

struct ProcessResourceUsage {
    let sample: ProcessResourceSample
    let cpu: Double?
}

struct ResourceUsageSnapshot {
    let processes: [ProcessResourceUsage]
    let updatedAt: Date
    let unavailable: Int
    var memory: UInt64 { processes.reduce(0) { $0 + $1.sample.memory } }
    var threads: Int? {
        guard !processes.isEmpty, processes.allSatisfy({ $0.sample.threads != nil }) else { return nil }
        return processes.reduce(0) { $0 + ($1.sample.threads ?? 0) }
    }
    var cpu: Double? {
        guard !processes.isEmpty, processes.allSatisfy({ $0.cpu != nil }) else { return nil }
        return processes.reduce(0) { $0 + ($1.cpu ?? 0) }
    }
}

/// CPU counters and the sampling clock both use Mach absolute ticks. Comparing them
/// directly avoids assuming the timebase is nanoseconds (it isn't on Apple Silicon).
struct ResourceUsageCalculator {
    private var previous: [pid_t: ProcessResourceSample] = [:]
    private var previousTime: UInt64?

    mutating func update(_ samples: [ProcessResourceSample], at time: UInt64, unavailable: Int = 0) -> ResourceUsageSnapshot {
        let rows = samples.map { sample -> ProcessResourceUsage in
            var cpu: Double?
            if let oldTime = previousTime, time > oldTime,
               let old = previous[sample.pid], old.startedAt == sample.startedAt,
               sample.userTime >= old.userTime, sample.systemTime >= old.systemTime {
                cpu = (Double(sample.userTime - old.userTime) + Double(sample.systemTime - old.systemTime)) / Double(time - oldTime) * 100
            }
            return ProcessResourceUsage(sample: sample, cpu: cpu)
        }
        previous = Dictionary(uniqueKeysWithValues: samples.map { ($0.pid, $0) })
        previousTime = time
        return ResourceUsageSnapshot(processes: rows, updatedAt: Date(), unavailable: unavailable)
    }
}

struct NativeResourceReader {
    let rootPID: pid_t

    func processIDs() -> [pid_t] {
        var result = [rootPID]
        var visited: Set<pid_t> = [rootPID]
        var index = 0
        while index < result.count {
            for child in children(of: result[index]) where visited.insert(child).inserted {
                result.append(child)
            }
            index += 1
        }
        return result
    }

    private func children(of parent: pid_t) -> [pid_t] {
        // proc_listchildpids returns a PID count; its buffer argument is in bytes.
        var capacity = max(32, Int(proc_listchildpids(parent, nil, 0)) + 16)
        while true {
            var buffer = [pid_t](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { proc_listchildpids(parent, $0.baseAddress, Int32($0.count)) }
            guard count > 0 else { return [] }
            if Int(count) < capacity { return buffer.prefix(Int(count)).filter { $0 > 0 } }
            capacity *= 2
        }
    }

    func read(_ pid: pid_t) -> ProcessResourceSample? {
        var usage = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard status == 0 else { return nil }
        var task = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let taskSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size)
        var name = [CChar](repeating: 0, count: 1024)
        let nameSize = name.withUnsafeMutableBytes { proc_name(pid, $0.baseAddress, UInt32($0.count)) }
        return ProcessResourceSample(pid: pid, name: pid == rootPID ? "VCode" : (nameSize > 0 ? String(cString: name) : "Process"), startedAt: usage.ri_proc_start_abstime, userTime: usage.ri_user_time, systemTime: usage.ri_system_time, memory: usage.ri_phys_footprint, threads: taskSize == size ? Int(task.pti_threadnum) : nil)
    }
}

/// Main-thread lifecycle, serial background sampling. Closing the window invalidates
/// pending deliveries as well as the timer; reopening begins a fresh CPU baseline.
final class ResourceUsageMonitor {
    private let queue = DispatchQueue(label: "dev.vcode.resource-usage", qos: .utility)
    private var timer: Timer?
    private var generation = UUID()
    private var inFlight = false
    private let read: () -> ([ProcessResourceSample], UInt64, Int)
    private var calculator = ResourceUsageCalculator() // accessed only on queue
    var onUpdate: ((ResourceUsageSnapshot) -> Void)?
    var isRunning: Bool { timer != nil }

    init(read: @escaping () -> ([ProcessResourceSample], UInt64, Int) = {
        let reader = NativeResourceReader(rootPID: getpid())
        let ids = reader.processIDs()
        let samples = ids.compactMap { reader.read($0) }
        return (samples, mach_absolute_time(), ids.count - samples.count)
    }) { self.read = read }

    func start() {
        guard timer == nil else { return }
        generation = UUID()
        queue.async { [weak self] in self?.calculator = ResourceUsageCalculator() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        inFlight = false
    }

    private func sample() {
        guard !inFlight else { return }
        inFlight = true
        let token = generation
        queue.async { [weak self] in
            guard let self else { return }
            let (samples, time, unavailable) = self.read()
            let snapshot = self.calculator.update(samples, at: time, unavailable: unavailable)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.generation == token else { return }
                self.inFlight = false
                self.onUpdate?(snapshot)
            }
        }
    }
    deinit { timer?.invalidate() }
}
