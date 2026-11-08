import XCTest
@testable import DADFoundation

final class AnalyticsRecordTests: XCTestCase {
    func testTaxonomyCoversAllThirtyEvents() {
        // The §9 taxonomy has 30 events; guard against an accidental drop.
        XCTAssertEqual(AnalyticsEvent.allCases.count, 30)
        XCTAssertEqual(AnalyticsEvent.appOpened.rawValue, "app_opened")
        XCTAssertEqual(AnalyticsEvent.pushOpened.rawValue, "push_opened")
    }

    func testCarrierEventsRequireTheirProperty() throws {
        // attribution_captured requires {source}, invite_shared {channel}, push_opened {type}.
        XCTAssertThrowsError(try AnalyticsRecord(.attributionCaptured)) { error in
            XCTAssertEqual(error as? AnalyticsRecord.ValidationError, .missingRequiredProperty("source"))
        }
        for source in ["link", "IRL", "company"] {
            XCTAssertNoThrow(try AnalyticsRecord(.attributionCaptured, properties: ["source": source]))
        }
        for bad in ["share", "irl", "Link", "organic"] {
            XCTAssertThrowsError(try AnalyticsRecord(.attributionCaptured, properties: ["source": bad])) { error in
                XCTAssertEqual(error as? AnalyticsRecord.ValidationError, .invalidValue("source"))
            }
        }
        XCTAssertNoThrow(try AnalyticsRecord(.inviteShared, properties: ["channel": "sms"]))
        XCTAssertNoThrow(try AnalyticsRecord(.pushOpened, properties: ["type": "reminder"]))
    }

    func testNoPropertyEventRejectsProperties() {
        XCTAssertThrowsError(try AnalyticsRecord(.giftCompleted, properties: ["x": "y"])) { error in
            XCTAssertEqual(error as? AnalyticsRecord.ValidationError, .unexpectedProperties)
        }
    }

    func testEmptyRequiredValueIsRejected() {
        XCTAssertThrowsError(try AnalyticsRecord(.inviteShared, properties: ["channel": ""]))
    }
}

final class AnalyticsBatchTests: XCTestCase {
    private func records(_ n: Int) -> [AnalyticsRecord] {
        (0..<n).map { _ in try! AnalyticsRecord(.appOpened) }
    }

    func testBatchRejectsEmptyAndOversizedInput() throws {
        XCTAssertThrowsError(try AnalyticsBatch([])) { XCTAssertEqual($0 as? AnalyticsBatch.BatchError, .empty) }
        XCTAssertThrowsError(try AnalyticsBatch(records(101))) { XCTAssertEqual($0 as? AnalyticsBatch.BatchError, .tooLarge) }
        XCTAssertEqual(try AnalyticsBatch(records(100)).events.count, 100)
    }

    func testChunkRespectsThe100Cap() {
        XCTAssertEqual(AnalyticsBatch.chunk(records(1)).count, 1)
        XCTAssertEqual(AnalyticsBatch.chunk(records(100)).count, 1)
        XCTAssertEqual(AnalyticsBatch.chunk(records(101)).count, 2)
        XCTAssertEqual(AnalyticsBatch.chunk(records(250)).count, 3)
        // Each chunk is wire-legal (1...100).
        for batch in AnalyticsBatch.chunk(records(250)) {
            XCTAssertTrue(batch.events.count >= 1 && batch.events.count <= 100)
        }
    }

    func testChunkPreservesOrder() {
        let recs = records(150)
        let flattened = AnalyticsBatch.chunk(recs).flatMap(\.events)
        XCTAssertEqual(flattened.map(\.id), recs.map(\.id))
    }
}

final class AnalyticsRecorderTests: XCTestCase {
    private actor SpySink: AnalyticsSink {
        private(set) var sent: [[AnalyticsRecord]] = []
        var failUntil = 0 // fail the first N send calls
        private var calls = 0
        var attempts: Int { calls }
        func setFailUntil(_ n: Int) { failUntil = n }
        func send(_ batch: AnalyticsBatch) async throws {
            calls += 1
            if calls <= failUntil { throw AccountError.signedOut }
            sent.append(batch.events)
        }
        var flattened: [AnalyticsRecord] { sent.flatMap { $0 } }
    }

    func testEmitOnceEvenWhenRecordedTwice() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        let record = try AnalyticsRecord(.giftCompleted)
        await recorder.record(record)
        await recorder.record(record) // same id — idempotent, not double-buffered
        let pending = await recorder.pending
        XCTAssertEqual(pending, 1)
        try await recorder.flush()
        let count = await sink.flattened.count
        XCTAssertEqual(count, 1)
    }

    func testFlushDeliversAndClears() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        try await recorder.record(.appOpened)
        try await recorder.record(.giftStarted)
        try await recorder.flush()
        let pending = await recorder.pending
        XCTAssertEqual(pending, 0)
        let count = await sink.flattened.count
        XCTAssertEqual(count, 2)
    }

    func testFlushFailureKeepsBufferForRetry() async throws {
        let sink = SpySink()
        await sink.setFailUntil(1) // first send throws
        let recorder = AnalyticsRecorder(sink: sink)
        try await recorder.record(.appOpened)
        do { try await recorder.flush(); XCTFail("expected throw") } catch {}
        // Buffer kept — a retry delivers it, and the event is not duplicated.
        let pendingAfterFail = await recorder.pending
        XCTAssertEqual(pendingAfterFail, 1)
        try await recorder.flush()
        let count = await sink.flattened.count
        XCTAssertEqual(count, 1)
        let pendingAfterRetry = await recorder.pending
        XCTAssertEqual(pendingAfterRetry, 0)
    }

    func testAlreadyDeliveredIsNotRebuffered() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        let record = try AnalyticsRecord(.badgeEarned)
        await recorder.record(record)
        try await recorder.flush()
        // Re-recording a delivered id is a no-op.
        await recorder.record(record)
        let pending = await recorder.pending
        XCTAssertEqual(pending, 0)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.withLock { date } }
        func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
    }

    func testFlushWhenDueBacksOffAfterFailure() async throws {
        let sink = SpySink()
        await sink.setFailUntil(1)
        let clock = Clock()
        let recorder = AnalyticsRecorder(sink: sink, now: { clock.now })
        try await recorder.record(.appOpened)
        do { try await recorder.flushWhenDue(); XCTFail("expected throw") } catch {}
        try await recorder.record(.giftStarted)
        try await recorder.flushWhenDue() // still backing off: nothing is sent
        var pending = await recorder.pending
        XCTAssertEqual(pending, 2)
        clock.advance(31)
        try await recorder.flushWhenDue()
        pending = await recorder.pending
        XCTAssertEqual(pending, 0)
        let count = await sink.flattened.count
        XCTAssertEqual(count, 2)
    }

    func testBufferIsBoundedAndDropsOldest() async throws {
        let sink = SpySink()
        let recorder = AnalyticsRecorder(sink: sink)
        let all = try (0..<(AnalyticsRecorder.maxBuffered + 5)).map { _ in try AnalyticsRecord(.appOpened) }
        for record in all { await recorder.record(record) }
        let pending = await recorder.pending
        XCTAssertEqual(pending, AnalyticsRecorder.maxBuffered)
        try await recorder.flush()
        let delivered = await sink.flattened.map(\.id)
        XCTAssertEqual(delivered, all.suffix(AnalyticsRecorder.maxBuffered).map(\.id), "the newest events survive, the oldest are dropped")
    }

    func testBackoffDoublesPerFailureAndIsCapped() async throws {
        let sink = SpySink()
        await sink.setFailUntil(Int.max)
        let clock = Clock()
        let recorder = AnalyticsRecorder(sink: sink, now: { clock.now })
        try await recorder.record(.appOpened)
        do { try await recorder.flushWhenDue(); XCTFail("expected the sink failure") } catch {}
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            // The first moment flushWhenDue stops being a no-op is the end of the backoff; that probe is the next attempt.
            var waited: TimeInterval = 0
            var attempted = false
            while !attempted, waited < 2_000 {
                let before = await sink.attempts
                try? await recorder.flushWhenDue()
                if await sink.attempts != before { attempted = true } else { clock.advance(1); waited += 1 }
            }
            XCTAssertTrue(attempted)
            waits.append(waited)
        }
        XCTAssertEqual(Array(waits.prefix(5)), [30, 60, 120, 240, 480])
        XCTAssertEqual(Array(waits.suffix(2)), [900, 900], "capped at fifteen minutes")
    }

    func testAnInvalidBatchIsDroppedWithoutBackoffSoLaterEventsStillFlow() async throws {
        actor Rejecting: AnalyticsSink {
            var seen: [Int] = []
            func send(_ batch: AnalyticsBatch) async throws {
                seen.append(batch.events.count)
                if seen.count == 1 { throw AccountError.invalidInput }
            }
        }
        let sink = Rejecting()
        let recorder = AnalyticsRecorder(sink: sink)
        try await recorder.record(.appOpened)
        try await recorder.flushWhenDue()
        let afterReject = await recorder.pending
        XCTAssertEqual(afterReject, 0, "a batch the server will never accept is not resent forever")
        try await recorder.record(.giftStarted)
        try await recorder.flushWhenDue()   // would be a no-op if the rejection had started a backoff
        let sent = await sink.seen
        XCTAssertEqual(sent, [1, 1])
    }

    func testRecordsAddedDuringFlushAreNotLost() async throws {
        actor Gate: AnalyticsSink {
            var release: CheckedContinuation<Void, Never>?
            var sent = 0
            func send(_ batch: AnalyticsBatch) async throws {
                if sent == 0 { await withCheckedContinuation { release = $0 } }
                sent += batch.events.count
            }
            func open() { release?.resume(); release = nil }
            var waiting: Bool { release != nil }
        }
        let gate = Gate()
        let recorder = AnalyticsRecorder(sink: gate)
        try await recorder.record(.appOpened)
        let first = Task { try await recorder.flush() }
        while await !gate.waiting { await Task.yield() }
        try await recorder.record(.giftStarted) // arrives while the first batch is in flight
        await gate.open()
        try await first.value
        let pending = await recorder.pending
        XCTAssertEqual(pending, 0)
        let sent = await gate.sent
        XCTAssertEqual(sent, 2)
    }
}
