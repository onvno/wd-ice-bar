import Foundation
import CoreGraphics

/// Routes a targeted status-bar event through the same two stages used by Ice: first place a
/// harmless marker in the target process, then inject the real event into the session stream,
/// and finally deliver it to the target process only after the session has accepted it.
@MainActor
final class MenuBarEventRouter {
    enum Result: Equatable {
        case delivered
        case targetTapUnavailable
        case timedOut
        case tapDisabled

        var description: String {
            switch self {
            case .delivered: "事件已送达"
            case .targetTapUnavailable: "无法连接目标状态栏进程的事件通道"
            case .timedOut: "事件路由超时"
            case .tapDisabled: "macOS 停用了自动拖拽事件通道"
            }
        }
    }

    func route(_ event: CGEvent, to targetPID: pid_t) async -> Result {
        await RoutedMenuBarEvent(event: event, targetPID: targetPID).perform()
    }
}

// Event-tap callbacks are delivered on the main run loop that installs them. The class owns all
// mutable tap state and serializes lifetime through `lock`; annotate it explicitly for Swift 6.
private final class RoutedMenuBarEvent: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var active = [UUID: RoutedMenuBarEvent]()

    private let id = UUID()
    private let event: CGEvent
    private let targetPID: pid_t
    private let markerUserData: Int64
    private let runLoop: CFRunLoop
    private var sourcePort: CFMachPort?
    private var sessionPort: CFMachPort?
    private var sourceRunLoopSource: CFRunLoopSource?
    private var sessionRunLoopSource: CFRunLoopSource?
    private var continuation: CheckedContinuation<MenuBarEventRouter.Result, Never>?
    private var finished = false

    init(event: CGEvent, targetPID: pid_t) {
        self.event = event
        self.targetPID = targetPID
        markerUserData = Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(event)))
        runLoop = CFRunLoopGetCurrent()
    }

    func perform() async -> MenuBarEventRouter.Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            Self.lock.lock()
            Self.active[id] = self
            Self.lock.unlock()
            install()
        }
    }

    private func install() {
        guard let marker = CGEvent(source: nil) else {
            finish(.targetTapUnavailable)
            return
        }
        marker.setIntegerValueField(.eventSourceUserData, value: markerUserData)

        let sourceMask = CGEventMask(1) << CGEventType.null.rawValue
        let sessionMask = CGEventMask(1) << event.type.rawValue
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        guard
            let sourcePort = CGEvent.tapCreateForPid(
                pid: targetPID,
                place: .tailAppendEventTap,
                options: .defaultTap,
                eventsOfInterest: sourceMask,
                callback: sourceCallback,
                userInfo: pointer
            ),
            let sessionPort = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: sessionMask,
                callback: sessionCallback,
                userInfo: pointer
            ),
            let sourceRunLoopSource = CFMachPortCreateRunLoopSource(nil, sourcePort, 0),
            let sessionRunLoopSource = CFMachPortCreateRunLoopSource(nil, sessionPort, 0)
        else {
            finish(.targetTapUnavailable)
            return
        }

        self.sourcePort = sourcePort
        self.sessionPort = sessionPort
        self.sourceRunLoopSource = sourceRunLoopSource
        self.sessionRunLoopSource = sessionRunLoopSource
        CFRunLoopAddSource(runLoop, sourceRunLoopSource, .commonModes)
        CFRunLoopAddSource(runLoop, sessionRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: sourcePort, enable: true)
        CGEvent.tapEnable(tap: sessionPort, enable: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { [weak self] in
            self?.finish(.timedOut)
        }
        marker.postToPid(targetPID)
    }

    private func receiveMarker(_ received: CGEvent) -> Unmanaged<CGEvent>? {
        guard received.getIntegerValueField(.eventSourceUserData) == markerUserData else {
            return Unmanaged.passUnretained(received)
        }
        if let sourcePort { CGEvent.tapEnable(tap: sourcePort, enable: false) }
        event.post(tap: .cgSessionEventTap)
        return nil
    }

    private func receiveSessionEvent(_ received: CGEvent) -> Unmanaged<CGEvent>? {
        guard eventMatches(received) else {
            return Unmanaged.passUnretained(received)
        }
        event.postToPid(targetPID)
        finish(.delivered)
        return Unmanaged.passUnretained(received)
    }

    private func eventMatches(_ received: CGEvent) -> Bool {
        let fields: [CGEventField] = [
            .eventSourceUserData,
            .mouseEventWindowUnderMousePointer,
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            CGEventField(rawValue: 0x33)!,
        ]
        return fields.allSatisfy { received.getIntegerValueField($0) == event.getIntegerValueField($0) }
    }

    private func finish(_ result: MenuBarEventRouter.Result) {
        guard !finished else { return }
        finished = true
        if let sourceRunLoopSource { CFRunLoopRemoveSource(runLoop, sourceRunLoopSource, .commonModes) }
        if let sessionRunLoopSource { CFRunLoopRemoveSource(runLoop, sessionRunLoopSource, .commonModes) }
        if let sourcePort {
            CGEvent.tapEnable(tap: sourcePort, enable: false)
            CFMachPortInvalidate(sourcePort)
        }
        if let sessionPort {
            CGEvent.tapEnable(tap: sessionPort, enable: false)
            CFMachPortInvalidate(sessionPort)
        }
        sourcePort = nil
        sessionPort = nil
        sourceRunLoopSource = nil
        sessionRunLoopSource = nil
        Self.lock.lock()
        Self.active[id] = nil
        Self.lock.unlock()
        continuation?.resume(returning: result)
        continuation = nil
    }

    fileprivate static func receiveMarker(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let routedEvent = Unmanaged<RoutedMenuBarEvent>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            routedEvent.finish(.tapDisabled)
            return Unmanaged.passUnretained(event)
        }
        return routedEvent.receiveMarker(event)
    }

    fileprivate static func receiveSessionEvent(_ proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let routedEvent = Unmanaged<RoutedMenuBarEvent>.fromOpaque(userInfo).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            routedEvent.finish(.tapDisabled)
            return Unmanaged.passUnretained(event)
        }
        return routedEvent.receiveSessionEvent(event)
    }
}

private func sourceCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    RoutedMenuBarEvent.receiveMarker(proxy, type: type, event: event, userInfo: userInfo)
}

private func sessionCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    RoutedMenuBarEvent.receiveSessionEvent(proxy, type: type, event: event, userInfo: userInfo)
}
