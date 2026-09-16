import Foundation
import Combine

/// UI binding for `LiveTranscriptEngine`.
///
/// Consumes the engine's `AsyncStream<TranscriptEvent>` and exposes a
/// split `committed` / `volatile` segment array that SwiftUI can diff
/// efficiently — volatile segments carry a stable `utteranceID` and `id`,
/// so the tail is updated in place instead of replaced.
@MainActor
public final class LiveTranscriptViewModel: ObservableObject {
    @Published public private(set) var committed: [TranscriptSegment] = []
    @Published public private(set) var volatile: [TranscriptSegment] = []

    private let engine: LiveTranscriptEngine
    private var consumeTask: Task<Void, Never>?

    public init(engine: LiveTranscriptEngine) { self.engine = engine }

    public func start() {
        consumeTask?.cancel()
        consumeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.start()
            for await event in stream {
                self.apply(event)
            }
        }
    }

    public func stop() async {
        await engine.stop()
        consumeTask?.cancel()
        // Reconcile against the authoritative snapshot in case the
        // AsyncStream dropped a final under backpressure.
        committed = await engine.transcriptSnapshot().filter { $0.stability == .stable }
        volatile = []
    }

    public func ingest(_ frame: AudioFrame) async {
        await engine.ingest(frame)
    }

    private func apply(_ event: TranscriptEvent) {
        switch event {
        case .partial(let s):
            if let i = volatile.firstIndex(where: { $0.id == s.id }) {
                volatile[i] = s
            } else {
                volatile.append(s)
                volatile.sort { $0.range.lowerBound < $1.range.lowerBound }
            }
        case .final(let s):
            volatile.removeAll { $0.id == s.id }
            committed.append(s)
        case .gap:
            // gap marker – insert a gap marker view at the range
            break
        case .finished:
            volatile = []
        }
    }
}
