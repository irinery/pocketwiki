import Foundation

/// Inactive orchestration over injected ports. The stream port must return only
/// after validating SSE headers and confirming the server installed its watcher.
/// No URLSession/provider transport or real grant-change authority is supplied.
@MainActor final class ProviderStreamFirst {
    struct Stream {
        let events: AsyncThrowingStream<Data, Error>
        let cancel: @MainActor () -> Void
    }
    struct Ports {
        let snapshot: @MainActor (_ cursor: String?, _ pageSize: Int) async throws -> Data
        let openStream: @MainActor (_ afterSeq: Int) async throws -> Stream
        let payload: @MainActor (_ ref: String) async throws -> Data
    }
    enum Failure: Error { case inactive, stale, invalidSnapshot, overflow, streamEnded }
    private final class Cycle {
        let id = UUID()
        let ticket: ProviderProjection.ScopeTicket
        var stream: Stream?
        var pump: Task<Void, Never>?
        var drain: Task<Void, Never>?
        var queue: [Data] = []
        var queuedBytes = 0
        var pending = 0
        var started = false
        var ready = false
        init(_ ticket: ProviderProjection.ScopeTicket) { self.ticket = ticket }
    }
    private let schema: [String: Any]
    private let environment: String
    private let pageSize: Int
    private let projection: ProviderProjection
    private let ports: Ports
    private let onView: (ProviderProjection.View?) -> Void
    private var authority: ProviderProjection.AuthorityTicket?
    private var cycle: Cycle?
    init(schema: [String: Any], environmentID: UUID, pageSize: Int, ports: Ports, onView: @escaping (ProviderProjection.View?) -> Void) throws {
        self.schema = schema; self.environment = environmentID.uuidString.lowercased(); self.pageSize = pageSize; self.ports = ports; self.onView = onView
        projection = try ProviderProjection(schema: schema, environmentID: environmentID, pageSize: pageSize, confirmedRevision: 0)
    }
    func setScope(_ scope: ProviderProjection.Scope?) {
        retire(); authority = projection.setScope(scope); onView(nil)
    }
    func close() { setScope(nil) }
    private func retire() {
        let prior = cycle; cycle = nil
        prior?.pump?.cancel(); prior?.drain?.cancel(); prior?.stream?.cancel()
        prior?.queue.removeAll()
    }
    private func active(_ c: Cycle) -> Bool { cycle === c && projection.isCurrent(c.ticket) }
    private func check(_ c: Cycle) throws { guard active(c) else { throw Failure.stale } }
    private func fail(_ c: Cycle) {
        guard active(c) else { return }
        retire(); authority = nil; projection.setScope(nil); onView(nil)
    }
    private func snapshotFields(_ data: Data) throws -> (Int, String?) {
        guard data.count <= 4_194_304,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              HarnessV1.validateCorpusValue(body, schemaName: "providersFeatureSnapshot", document: schema),
              let seq = body["as_of_seq"] as? Int, seq >= 0, seq <= 9_007_199_254_740_991 else { throw Failure.invalidSnapshot }
        return (seq, body["next_cursor"] as? String)
    }
    func start(pageSize: Int) async throws {
        guard pageSize == self.pageSize, let authority else { throw Failure.inactive }
        retire(); let c = Cycle(try projection.beginRefresh(authority)); cycle = c
        do {
            onView(nil); try check(c)
            let preliminary = try await ports.snapshot(nil, pageSize); try check(c)
            let (after, _) = try snapshotFields(preliminary)
            let stream = try await ports.openStream(after)
            guard active(c) else { stream.cancel(); throw Failure.stale }
            c.stream = stream
            c.pump = Task { @MainActor [weak self] in await self?.pump(c) }
            await Task.yield(); try check(c)
            var page = try await ports.snapshot(nil, pageSize); try check(c)
            var (boundary, cursor) = try snapshotFields(page)
            guard boundary >= after else { throw Failure.invalidSnapshot }
            try projection.appendPage(page, requestedCursor: nil, scope: c.ticket)
            c.started = true; ensureDrain(c)
            while let requested = cursor {
                page = try await ports.snapshot(requested, pageSize); try check(c)
                (boundary, cursor) = try snapshotFields(page)
                try projection.appendPage(page, requestedCursor: requested, scope: c.ticket)
            }
            while active(c) && (c.drain != nil || !c.queue.isEmpty) {
                ensureDrain(c); if let drain = c.drain { await drain.value }; try check(c)
            }
            try check(c); c.ready = true; onView(try projection.finish(scope: c.ticket))
        } catch { fail(c); throw error }
    }
    private func pump(_ c: Cycle) async {
        do {
            guard let stream = c.stream else { throw Failure.inactive }
            for try await data in stream.events {
                try check(c)
                guard c.pending < 4096, data.count <= 4_194_304 - c.queuedBytes else { throw Failure.overflow }
                c.pending += 1; c.queuedBytes += data.count; c.queue.append(data); ensureDrain(c)
            }
            throw Failure.streamEnded
        } catch { fail(c) }
    }
    private func ensureDrain(_ c: Cycle) {
        guard active(c), c.started, c.drain == nil, !c.queue.isEmpty else { return }
        c.drain = Task { @MainActor [weak self] in await self?.drain(c) }
    }
    private func drain(_ c: Cycle) async {
        do {
            while active(c), !c.queue.isEmpty {
                let data = c.queue.removeFirst()
                guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      HarnessV1.validateCorpusValue(envelope, schemaName: "streamEnvelope", document: schema),
                      envelope["environment_id"] as? String == environment, envelope["module"] as? String == "providers", envelope["thread_id"] == nil else { throw Failure.invalidSnapshot }
                var payload: Data?
                if envelope["delivery"] as? String == "reference" {
                    guard let ref = envelope["payload_ref"] as? String else { throw Failure.invalidSnapshot }
                    payload = try await ports.payload(ref); try check(c)
                    guard let payload, payload.count <= 4_194_304 - c.queuedBytes else { throw Failure.overflow }
                }
                try projection.bufferEvent(data, resolvedPayload: payload, scope: c.ticket)
                c.pending -= 1; c.queuedBytes -= data.count
                if c.ready { try check(c); onView(try projection.finish(scope: c.ticket)) }
            }
            c.drain = nil
        } catch { c.drain = nil; fail(c) }
    }
}
