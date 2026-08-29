import Dispatch
import Foundation

/// Kernel push notifications for memory-pressure transitions — no polling
/// needed for the trigger path.
public final class PressureSource {
    private let source: DispatchSourceMemoryPressure

    public init(queue: DispatchQueue, handler: @escaping (String) -> Void) {
        source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: queue)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            let label: String
            if event.contains(.critical) { label = "critical" }
            else if event.contains(.warning) { label = "warn" }
            else { label = "normal" }
            handler(label)
        }
        source.resume()
    }

    deinit { source.cancel() }
}
