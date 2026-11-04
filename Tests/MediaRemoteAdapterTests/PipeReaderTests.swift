import Foundation
import XCTest
@testable import MediaRemoteAdapter

/// The class under test: a pipe reader that can return without draining, or that stays attached
/// after EOF, busy-spins its dispatch source at 100% CPU for the life of the host process.
final class PipeReaderTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
    }

    func testReaderDrainsAndDetachesAtEOF() {
        let pipe = Pipe()
        let sink = Sink()
        let eof = expectation(description: "EOF observed")
        PipeReader.attach(pipe.fileHandleForReading, onEOF: { eof.fulfill() }) { [sink] data in
            sink.lock.lock()
            sink.data.append(data)
            sink.lock.unlock()
        }
        pipe.fileHandleForWriting.write(Data("abc\n".utf8))
        try? pipe.fileHandleForWriting.close()

        wait(for: [eof], timeout: 5)
        XCTAssertNil(pipe.fileHandleForReading.readabilityHandler, "a reader left attached after EOF spins")
        XCTAssertEqual(String(decoding: sink.data, as: UTF8.self), "abc\n")
    }

    /// End to end through the call that shipped the spin: its per-call state was captured weakly,
    /// died on return, and from then on the handler neither drained nor delivered.
    func testGetTrackInfoDeliversExactlyOnceAndLeavesNoSpinningReader() {
        let controller = MediaController()
        let delivered = expectation(description: "getTrackInfo completion")
        delivered.assertForOverFulfill = true
        controller.getTrackInfo { _ in delivered.fulfill() }
        wait(for: [delivered], timeout: 10)

        // Let any leaked reader show itself, then measure what this process burns while idle.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let before = Self.cpuSeconds()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let burned = Self.cpuSeconds() - before
        XCTAssertLessThan(burned, Self.idleCPUBudgetSeconds,
                          "process burned \(burned)s of CPU in 1s idle — a pipe reader is spinning")
    }

    /// A spinning reader burns ~1s per wall second; an idle test process burns milliseconds.
    private static let idleCPUBudgetSeconds = 0.25

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
