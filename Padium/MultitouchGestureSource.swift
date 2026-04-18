import Foundation

struct MultitouchDeviceFrame: Sendable {
    let deviceID: Int
    let points: [TouchPoint]
}

protocol MultitouchFrameMonitoring: AnyObject, Sendable {
    func startListening(onFrame: @escaping @Sendable (MultitouchDeviceFrame) -> Void) -> Bool
    func stopListening()
}

// Concrete GestureSource backed by a local MultitouchSupport bridge.
// Thread-safety: frame callbacks arrive on private framework threads, so device
// ownership and continuation access are serialized on processingQueue.
final class MultitouchGestureSource: GestureSource, @unchecked Sendable {
    private let monitor: any MultitouchFrameMonitoring
    private let processingQueue = DispatchQueue(label: "com.padium.multitouch.source")

    private var stream: AsyncStream<[TouchPoint]>
    private var continuation: AsyncStream<[TouchPoint]>.Continuation
    private var activeContinuation: AsyncStream<[TouchPoint]>.Continuation?
    private var activeDeviceID: Int?

    var touchFrameStream: AsyncStream<[TouchPoint]> { stream }

    init(monitor: (any MultitouchFrameMonitoring)? = nil) {
        self.monitor = monitor ?? MultitouchBridgeMonitor()
        (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
    }

    func startListening() throws {
        (stream, continuation) = AsyncStream<[TouchPoint]>.makeStream()
        processingQueue.sync {
            activeContinuation = continuation
            activeDeviceID = nil
        }

        let started = monitor.startListening { [weak self] frame in
            self?.processingQueue.async { [weak self] in
                self?.handle(frame)
            }
        }

        guard started else {
            processingQueue.sync {
                activeContinuation = nil
                activeDeviceID = nil
            }
            PadiumLogger.gesture.error("Multitouch listener failed to start")
            throw MultitouchGestureSourceError.listenerAlreadyActiveOrHardwareUnavailable
        }

        PadiumLogger.gesture.info("Multitouch listener started")
    }

    func stopListening() {
        monitor.stopListening()

        let continuationToFinish = processingQueue.sync {
            let current = activeContinuation
            activeContinuation = nil
            activeDeviceID = nil
            return current
        }
        continuationToFinish?.finish()

        PadiumLogger.gesture.info("Multitouch listener stopped")
    }

    private func handle(_ frame: MultitouchDeviceFrame) {
        guard let continuation = activeContinuation else { return }
        guard shouldEmit(frame) else { return }
        continuation.yield(frame.points)
    }

    private func shouldEmit(_ frame: MultitouchDeviceFrame) -> Bool {
        if frame.points.isEmpty {
            guard let activeDeviceID, activeDeviceID == frame.deviceID else {
                return false
            }
            self.activeDeviceID = nil
            return true
        }

        if let activeDeviceID {
            return activeDeviceID == frame.deviceID
        }

        activeDeviceID = frame.deviceID
        return true
    }
}

enum MultitouchGestureSourceError: Error {
    case listenerAlreadyActiveOrHardwareUnavailable
}

final class MultitouchBridgeMonitor: MultitouchFrameMonitoring, @unchecked Sendable {
    private lazy var bridge = PadiumMultitouchBridge { [weak self] frame in
        self?.handle(frame)
    }
    private let stateLock = NSLock()
    private var frameHandler: (@Sendable (MultitouchDeviceFrame) -> Void)?

    init() {}

    func startListening(onFrame: @escaping @Sendable (MultitouchDeviceFrame) -> Void) -> Bool {
        stateLock.lock()
        frameHandler = onFrame
        stateLock.unlock()

        let started = bridge.startListening()
        if !started {
            stateLock.lock()
            frameHandler = nil
            stateLock.unlock()
        }
        return started
    }

    func stopListening() {
        bridge.stopListening()

        stateLock.lock()
        frameHandler = nil
        stateLock.unlock()
    }

    private func handle(_ frame: PadiumMultitouchFrame) {
        let points = frame.contacts.map { contact in
            TouchPoint(
                identifier: Int(contact.identifier),
                normalizedX: contact.normalizedX,
                normalizedY: contact.normalizedY,
                pressure: contact.pressure,
                state: TouchState(contact.state),
                total: contact.total,
                majorAxis: contact.majorAxis
            )
        }
        let deviceFrame = MultitouchDeviceFrame(deviceID: Int(frame.deviceID), points: points)

        stateLock.lock()
        let handler = frameHandler
        stateLock.unlock()
        handler?(deviceFrame)
    }
}

private extension TouchState {
    init(_ state: PadiumMultitouchContactState) {
        switch state {
        case .notTouching: self = .notTouching
        case .starting:    self = .starting
        case .hovering:    self = .hovering
        case .making:      self = .making
        case .touching:    self = .touching
        case .breaking:    self = .breaking
        case .lingering:   self = .lingering
        case .leaving:     self = .leaving
        @unknown default:  self = .notTouching
        }
    }
}
