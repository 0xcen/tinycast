import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Synchronization

private func commandEscapeTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let thread = Unmanaged<TapThread>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        thread.send(.disabledBySystem)
        return Unmanaged.passUnretained(event)
    }
    guard
        CommandEscapeTap.isChord(
            keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
    else { return Unmanaged.passUnretained(event) }

    thread.send(.chord)
    return nil
}

/// ⌘esc is claimed upstream of every app, so the palette takes it where it enters the system.
///
/// The window server binds the chord itself, so it never reaches `onCommandShortcut` the way ⌘.
/// and ⌘w do: no keystroke is left by the time the responder chain runs, and a head-inserted HID
/// tap is the one place earlier than that. See docs/features/palette.md.
@MainActor
final class CommandEscapeTap {
    private let onChord: () -> Void

    private var tapPort: CFMachPort?
    private var thread: TapThread?
    private var isEnabled = false

    init(onChord: @escaping () -> Void) {
        self.onChord = onChord
    }

    isolated deinit {
        tearDown()
    }

    /// True only for a bare ⌘esc: any further modifier spells somebody else's chord.
    nonisolated static func isChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == Int64(kVK_Escape)
            && flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
                == .maskCommand
    }

    /// Called whenever the panel takes key: a tap refused for want of Accessibility is retried then.
    func enable() {
        isEnabled = true
        guard let port = installIfNeeded() else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    func disable() {
        isEnabled = false
        guard let tapPort else { return }
        CGEvent.tapEnable(tap: tapPort, enable: false)
    }

    private func installIfNeeded() -> CFMachPort? {
        if let tapPort { return tapPort }
        let thread = TapThread { [weak self] signal in self?.receive(signal) }
        // Head of the HID stream: anywhere later and the system hotkey has already eaten the chord.
        guard
            let port = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
                callback: commandEscapeTapCallback,
                userInfo: Unmanaged.passUnretained(thread).toOpaque())
        else { return nil }
        // A created tap is already live, and one nobody services stalls every keystroke.
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        thread.start(running: source)
        tapPort = port
        self.thread = thread
        return port
    }

    private func receive(_ signal: TapThread.Signal) {
        switch signal {
        case .chord:
            onChord()
        case .disabledBySystem:
            guard isEnabled, let tapPort else { return }
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
    }

    private func tearDown() {
        guard let tapPort else { return }
        CGEvent.tapEnable(tap: tapPort, enable: false)
        CFMachPortInvalidate(tapPort)
        thread?.stop()
        self.tapPort = nil
        thread = nil
    }
}

/// An active HID tap holds all input behind it until it answers, so it never waits on main.
private final class TapThread: Sendable {
    enum Signal {
        case chord
        case disabledBySystem
    }

    private let onSignal: @MainActor @Sendable (Signal) -> Void
    private let runLoop = Mutex<CFRunLoop?>(nil)

    init(onSignal: @escaping @MainActor @Sendable (Signal) -> Void) {
        self.onSignal = onSignal
    }

    /// The thread retains `self` until its loop returns, so the callback's pointer never dangles.
    func start(running source: CFRunLoopSource) {
        // Handed over once and never touched here again; CF run loop calls are thread-safe.
        nonisolated(unsafe) let source = source
        let thread = Thread { [self] in
            runLoop.withLock { $0 = CFRunLoopGetCurrent() }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "CommandEscapeTap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        runLoop.withLock { runLoop in
            if let runLoop { CFRunLoopStop(runLoop) }
        }
    }

    func send(_ signal: Signal) {
        Task { @MainActor [onSignal] in onSignal(signal) }
    }
}
