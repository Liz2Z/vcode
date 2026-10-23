import AppKit
import XCTest
@testable import VCode

final class ResourceUsageTests: XCTestCase {
    private func process(_ pid: pid_t = 1, start: UInt64 = 10, user: UInt64 = 0, system: UInt64 = 0) -> ProcessResourceSample {
        ProcessResourceSample(pid: pid, name: "test", startedAt: start, userTime: user, systemTime: system, memory: 4096, threads: 2)
    }

    func testCPUUsesMachTicksAndAllowsMultipleCores() {
        var calculator = ResourceUsageCalculator()
        XCTAssertNil(calculator.update([process()], at: 100).cpu)
        let usage = calculator.update([process(user: 120, system: 30)], at: 200)
        XCTAssertEqual(usage.cpu ?? -1, 150, accuracy: 0.001)
        XCTAssertEqual(usage.memory, 4096)
        XCTAssertEqual(usage.threads, 2)
    }

    func testPIDReuseNewProcessesAndExitNeverReuseOldCPU() {
        var calculator = ResourceUsageCalculator()
        _ = calculator.update([process()], at: 100)
        XCTAssertNil(calculator.update([process(start: 20, user: 500)], at: 200).cpu)
        let added = calculator.update([process(start: 20, user: 550), process(2)], at: 300)
        XCTAssertNil(added.cpu)
        XCTAssertEqual(added.processes[0].cpu ?? -1, 50, accuracy: 0.001)
        let exited = calculator.update([process(start: 20, user: 575)], at: 400)
        XCTAssertEqual(exited.cpu ?? -1, 25, accuracy: 0.001)
        XCTAssertEqual(exited.memory, 4096)
    }

    func testEmptyOrReversedSamplesDoNotReportFakeCPU() {
        var calculator = ResourceUsageCalculator()
        XCTAssertNil(calculator.update([], at: 100, unavailable: 1).threads)
        XCTAssertNil(calculator.update([process(user: 100)], at: 200).cpu)
        XCTAssertNil(calculator.update([process(user: 50)], at: 300).cpu)
        XCTAssertNil(calculator.update([process(user: 70)], at: 300).cpu)
    }

    func testNativeReaderFindsOwnedChildAndGrandchildAndExcludesExitedProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "/bin/sleep 30 & wait"]
        child.standardError = FileHandle.nullDevice
        try child.run()
        let reader = NativeResourceReader(rootPID: getpid())
        let deadline = Date().addingTimeInterval(3)
        var grandchild: pid_t?
        repeat {
            let descendants = NativeResourceReader(rootPID: child.processIdentifier).processIDs()
            grandchild = descendants.first { $0 != child.processIdentifier }
            if grandchild == nil { Thread.sleep(forTimeInterval: 0.01) }
        } while grandchild == nil && Date() < deadline
        defer {
            if let grandchild { kill(grandchild, SIGTERM) }
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        let pid = try XCTUnwrap(grandchild)
        let ids = reader.processIDs()
        XCTAssertTrue(ids.contains(child.processIdentifier))
        XCTAssertTrue(ids.contains(pid))
        XCTAssertEqual(Set(ids).count, ids.count)
        let own = try XCTUnwrap(reader.read(getpid()))
        XCTAssertGreaterThan(own.memory, 0)
        XCTAssertGreaterThan(own.threads ?? 0, 0)
        XCTAssertNotNil(reader.read(pid))
        kill(pid, SIGTERM)
        child.waitUntilExit()
        XCTAssertFalse(reader.processIDs().contains(child.processIdentifier))
        XCTAssertNil(reader.read(child.processIdentifier))
    }

    func testNativeCPUCounterAndClockUseTheSameTimebase() throws {
        let reader = NativeResourceReader(rootPID: getpid())
        let before = try XCTUnwrap(reader.read(getpid()))
        let start = mach_absolute_time()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.06
        while ProcessInfo.processInfo.systemUptime < deadline { _ = getpid() }
        let end = mach_absolute_time()
        let after = try XCTUnwrap(reader.read(getpid()))
        let ratio = (Double(after.userTime - before.userTime) + Double(after.systemTime - before.systemTime)) / Double(end - start)
        XCTAssertGreaterThan(ratio, 0.25)
        XCTAssertLessThan(ratio, 4, "CPU counters must not be treated as nanoseconds on Apple Silicon")
    }

    func testClosedMonitorDoesNotContinuePeriodicSampling() {
        let lock = NSLock()
        var count = 0
        let repeated = expectation(description: "periodic sample")
        let stopped = expectation(description: "no samples after closing")
        let monitor = ResourceUsageMonitor(read: {
            lock.lock(); count += 1; lock.unlock()
            return ([self.process()], mach_absolute_time(), 0)
        })
        var deliveries = 0
        monitor.onUpdate = { _ in
            deliveries += 1
            if deliveries == 2 { repeated.fulfill() }
        }
        monitor.start()
        wait(for: [repeated], timeout: 3)
        monitor.stop()
        lock.lock(); let atClose = count; lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            lock.lock(); let afterClose = count; lock.unlock()
            XCTAssertEqual(afterClose, atClose)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 2)
    }

    func testMonitorStopsAndDiscardsInFlightDeliveryThenRestartsFresh() {
        let entered = expectation(description: "sampling started")
        let release = DispatchSemaphore(value: 0)
        let delivered = expectation(description: "fresh sample after reopen")
        var reads = 0 // accessed only on the monitor's serial worker queue
        let monitor = ResourceUsageMonitor(read: {
            reads += 1
            if reads == 1 { entered.fulfill(); release.wait() }
            return ([self.process(user: UInt64(reads * 100))], UInt64(reads * 100), 0)
        })
        monitor.onUpdate = { value in
            XCTAssertEqual(value.processes.first?.sample.userTime, 200)
            XCTAssertNil(value.cpu, "Reopening must reset the CPU baseline")
            delivered.fulfill()
        }
        monitor.start()
        wait(for: [entered], timeout: 2)
        monitor.stop()
        XCTAssertFalse(monitor.isRunning)
        monitor.start()
        release.signal()
        wait(for: [delivered], timeout: 2)
        monitor.stop()
    }
}
