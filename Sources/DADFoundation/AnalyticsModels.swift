import Foundation

// The analytics sink seam + the buffering recorder. A conformer maps a batch to the generated
// ingest client (WireAPI) or a test double; the recorder owns buffering, idempotent de-dup, and
// chunked flush so the "emit the taxonomy once, deliver reliably" behaviour is unit-testable.

/// The seam the recorder flushes through. A conformer POSTs the batch to /analytics/events.
public protocol AnalyticsSink: Sendable {
    func send(_ batch: AnalyticsBatch) async throws
}

/// One typed client-side event sink (§9). Call `record` from a flow; the recorder buffers and
/// flushes. Flushing is idempotent: each record carries a stable id, and a record already
/// delivered is never re-buffered, so a lifecycle that fires twice still emits one event.
public actor AnalyticsRecorder {
    /// Events kept while the network is unavailable; the oldest are dropped first so memory stays bounded.
    public static let maxBuffered = 500
    private static let baseBackoff: TimeInterval = 30
    private static let maxBackoff: TimeInterval = 900

    private let sink: any AnalyticsSink
    private let now: @Sendable () -> Date
    private var buffer: [AnalyticsRecord] = []
    private var deliveredIDs: Set<UUID> = []
    private var flushing = false
    private var failures = 0
    private var retryNotBefore: Date?

    public init(sink: any AnalyticsSink, now: @escaping @Sendable () -> Date = { Date() }) {
        self.sink = sink; self.now = now
    }

    /// Buffer a validated record. A record whose id was already delivered (a retried emit) is
    /// dropped, so instrumenting a flow that can re-enter never double-counts (§9 "once").
    public func record(_ record: AnalyticsRecord) {
        guard !deliveredIDs.contains(record.id) else { return }
        guard !buffer.contains(where: { $0.id == record.id }) else { return }
        buffer.append(record)
        if buffer.count > Self.maxBuffered { buffer.removeFirst(buffer.count - Self.maxBuffered) }
    }

    /// Convenience: build + buffer in one call. Invalid events throw and are not buffered.
    public func record(
        _ name: AnalyticsEvent, occurredAt: Date = Date(),
        properties: [String: String] = [:], journeyID: UUID? = nil
    ) throws {
        record(try AnalyticsRecord(name, occurredAt: occurredAt, properties: properties, journeyID: journeyID))
    }

    public var pending: Int { buffer.count }

    /// Drop everything not yet delivered (the donor declined analytics).
    public func discardPending() { buffer.removeAll() }

    /// Flush now, regardless of backoff. A flush already in progress covers the buffer, so a second
    /// caller returns instead of sending the same records twice.
    public func flush() async throws {
        guard !flushing, !buffer.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        while !buffer.isEmpty {
            let batch = try AnalyticsBatch(Array(buffer.prefix(AnalyticsBatch.maxEvents)))
            do {
                try await sink.send(batch)
            } catch AccountError.invalidInput {
                // The server rejects the whole batch for one bad event, so resending it would fail forever.
            } catch {
                failures += 1
                retryNotBefore = now().addingTimeInterval(min(Self.maxBackoff, Self.baseBackoff * pow(2, Double(failures - 1))))
                throw error
            }
            let ids = Set(batch.events.map(\.id))
            deliveredIDs.formUnion(ids)
            buffer.removeAll { ids.contains($0.id) }
        }
        failures = 0
        retryNotBefore = nil
    }

    /// Flush unless a recent failure is still backing off (exponential, 30 s to 15 min), so a throttled or
    /// unreachable server is not hit again by every new event.
    public func flushWhenDue() async throws {
        if let retryNotBefore, now() < retryNotBefore { return }
        try await flush()
    }
}
