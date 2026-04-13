import AppKit
import ApplicationServices
import Foundation

private let blueStacksConfigPath = "/Users/Shared/Library/Application Support/BlueStacks/bluestacks.conf"
private let blueStacksMappingDir = "/Users/Shared/Library/Application Support/BlueStacks/Engine/UserData/InputMapper/UserFiles"
private let blueStacksBundleIDs = [
    "com.now.gg.BlueStacks",
    "com.bluestacks.BlueStacks"
]
private let blueStacksADBRelativePath = "Contents/MacOS/hd-adb"

enum DragMode: String, CaseIterable, Identifiable {
    case coalescedSwipe = "coalesced-swipe"
    case segmentedSwipe = "segmented-swipe"
    case virtualTouchExperiment = "virtual-touch-experiment"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coalescedSwipe:
            return "默认（整段 Swipe）"
        case .segmentedSwipe:
            return "实验：分段 Swipe"
        case .virtualTouchExperiment:
            return "实验：Virtual Touch"
        }
    }
}

struct Config {
    let sourcePID: pid_t
    let targetPID: pid_t
    let targetADBSerial: String
    let verbose: Bool
    let mappingFilePathOverride: String?
    let triggerKey: String?
    let dragMode: DragMode
}

struct TapMapping {
    let key: String
    let xPercent: Double
    let yPercent: Double
}

private let equivalentKeyGroups: [Set<String>] = [
    ["`", "·", "oem3"],
    ["-", "oemminus"],
    ["=", "oemplus"]
]

private struct BlueStacksInstance {
    let name: String
    let adbPort: Int
}

private func blueStacksADBPath() -> String? {
    for bundleID in blueStacksBundleIDs {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let adbURL = appURL.appendingPathComponent(blueStacksADBRelativePath)
            if FileManager.default.isExecutableFile(atPath: adbURL.path) {
                return adbURL.path
            }
        }
    }

    let fallbackPaths = [
        "/Applications/BlueStacks.app/\(blueStacksADBRelativePath)",
        "\(NSHomeDirectory())/Applications/BlueStacks.app/\(blueStacksADBRelativePath)"
    ]

    return fallbackPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
}

private func runProcess(_ args: [String]) -> (status: Int32, stdout: String, stderr: String)? {
    guard !args.isEmpty else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: args[0])
    process.arguments = Array(args.dropFirst())

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return nil
    }

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    return (
        status: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}

private func adbDevices() -> [String] {
    guard let adbPath = blueStacksADBPath() else {
        return []
    }
    guard let result = runProcess([
        adbPath,
        "devices", "-l"
    ]), result.status == 0 else {
        return []
    }

    return result.stdout
        .split(separator: "\n")
        .dropFirst()
        .compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            guard let first = parts.first else { return nil }
            return String(first)
        }
}

private func ensureADBConnected(serial: String) -> Bool {
    guard let adbPath = blueStacksADBPath() else {
        return false
    }
    let current = Set(adbDevices())
    if current.contains(serial) {
        return true
    }

    guard serial.hasPrefix("127.0.0.1:") else {
        return false
    }

    _ = runProcess([
        adbPath,
        "connect", serial
    ])

    return Set(adbDevices()).contains(serial)
}

final class ADBSynchronizer {
    private static let minimumScrollGesturePixels = 36
    private static let scrollCoalesceDelay: TimeInterval = 0.05
    private static let minimumScrollDurationMs = 50
    private static let maximumScrollDurationMs = 1200

    private let config: Config
    private let workspace = NSWorkspace.shared
    private let adbQueue = DispatchQueue(label: "tools.synchronizer.adb", qos: .userInitiated)
    private let stateQueue = DispatchQueue(label: "tools.synchronizer.state")
    private var cachedDisplaySize: CGSize?
    private var cachedMappingContext: (package: String?, path: String, mappings: [String: TapMapping])?
    private var activeLeftTouchStart: CGPoint?
    private var activeLeftTouchCurrent: CGPoint?
    private var activeLeftTouchStartedAt: CFTimeInterval?
    private var pendingScrollDeltaX: Int64 = 0
    private var pendingScrollDeltaY: Int64 = 0
    private var pendingScrollPoint: CGPoint?
    private var pendingScrollStartedAt: CFTimeInterval?
    private var pendingScrollGeneration: Int = 0
    private var activeLeftTouchLastSent: CGPoint?
    private var leftDragStreaming = false
    private let injectedMarker: Int64 = 0x53494E43

    init(config: Config) {
        self.config = config
    }

    func run() {
        guard hasAccessibilityPermission() else {
            print("Missing required permissions.")
            print("Grant Accessibility and Input Monitoring to BlueStacks Synchronizer, then run again.")
            exit(1)
        }

        guard verifyADB() else {
            print("Unable to access BlueStacks ADB.")
            exit(1)
        }

        if displaySize() == nil {
            print("Unable to prime Android display size from \(config.targetADBSerial)")
            exit(1)
        }

        if let triggerKey = config.triggerKey {
            runSingleTrigger(for: triggerKey)
            return
        }

        let eventMask = buildEventMask()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, refcon in
                let sync = Unmanaged<ADBSynchronizer>.fromOpaque(refcon!).takeUnretainedValue()
                return sync.handleEvent(type: type, event: event)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            print("Unable to create key event tap.")
            exit(1)
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("ADB synchronizer running.")
        print("Source PID: \(config.sourcePID)")
        print("Target PID: \(config.targetPID)")
        print("Target ADB serial: \(config.targetADBSerial)")
        print("Drag mode: \(config.dragMode.rawValue)")
        if let mappingFilePathOverride = config.mappingFilePathOverride {
            print("Mapping file override: \(mappingFilePathOverride)")
        } else {
            print("Mapping mode: auto-resolve from target foreground package")
        }
        print("Mouse mirror: move/down/drag/up + scroll")
        print("Press Control+C to stop.")

        RunLoop.current.run()
    }

    private func buildEventMask() -> CGEventMask {
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .mouseMoved,
            .scrollWheel,
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp
        ]

        return eventTypes.reduce(0) { mask, type in
            mask | (1 << type.rawValue)
        }
    }

    private func runSingleTrigger(for triggerKey: String) {
        let normalizedKey = normalizeBlueStacksKey(triggerKey)
        guard let context = mappingContext(),
              let mapping = context.mappings[normalizedKey] else {
            print("No tap mapping for key \(triggerKey)")
            exit(1)
        }

        guard let size = displaySize() else {
            print("Unable to read Android display size from \(config.targetADBSerial)")
            exit(1)
        }

        let displayWidth = Int(size.width)
        let displayHeight = Int(size.height)
        let x = max(0, min(Int((mapping.xPercent / 100.0) * Double(displayWidth)), displayWidth - 1))
        let y = max(0, min(Int((mapping.yPercent / 100.0) * Double(displayHeight)), displayHeight - 1))

        if sendTap(serial: config.targetADBSerial, x: x, y: y) {
            print("Triggered key \(normalizedKey) -> (\(x), \(y)) on \(config.targetADBSerial) via \(context.path)")
            exit(0)
        } else {
            print("ADB tap failed for key \(normalizedKey) on \(config.targetADBSerial)")
            exit(1)
        }
    }

    private func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func verifyADB() -> Bool {
        guard let adbPath = blueStacksADBPath() else {
            return false
        }
        if !ensureADBConnected(serial: config.targetADBSerial) {
            return false
        }

        return runCommand([
            adbPath,
            "-s", config.targetADBSerial,
            "shell", "-T", "getprop", "ro.serialno"
        ]) != nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard hasAccessibilityPermission() else {
            print("Accessibility permission lost. Stopping synchronizer.")
            exit(2)
        }

        if event.getIntegerValueField(.eventSourceUserData) == injectedMarker {
            return Unmanaged.passRetained(event)
        }

        guard let frontmost = workspace.frontmostApplication,
              frontmost.processIdentifier == config.sourcePID else {
            return Unmanaged.passRetained(event)
        }

        switch type {
        case .keyDown:
            return handleKeyDown(event)
        case .flagsChanged:
            return handleModifierFlagsChanged(event)
        case .keyUp:
            return Unmanaged.passRetained(event)
        case .mouseMoved,
             .scrollWheel,
             .leftMouseDown, .leftMouseDragged, .leftMouseUp,
             .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            mirrorMouseEvent(type: type, event: event)
            return Unmanaged.passRetained(event)
        default:
            return Unmanaged.passRetained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat {
            return Unmanaged.passRetained(event)
        }

        if isEmergencyExitHotkey(event) {
            print("Emergency exit hotkey received. Stopping synchronizer.")
            exit(0)
        }

        if let systemAction = sidebarSystemAction(for: event) {
            adbQueue.async { [self] in
                let succeeded = sendKeyEvent(serial: config.targetADBSerial, keycode: systemAction.keycode)
                if config.verbose {
                    if succeeded {
                        print("Triggered sidebar action \(systemAction.name) via keyevent \(systemAction.keycode)")
                    } else {
                        print("Failed sidebar action \(systemAction.name) via keyevent \(systemAction.keycode)")
                    }
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard let key = keyIdentifier(for: event) else {
            return Unmanaged.passRetained(event)
        }
        adbQueue.async { [self] in
            guard let context = mappingContext(),
                  let mapping = context.mappings[key] else {
                if config.verbose {
                    print("No tap mapping for key \(key)")
                }
                return
            }

            guard let size = displaySize() else {
                print("Unable to read Android display size from \(config.targetADBSerial)")
                return
            }

            let displayWidth = Int(size.width)
            let displayHeight = Int(size.height)
            let x = max(0, min(Int((mapping.xPercent / 100.0) * Double(displayWidth)), displayWidth - 1))
            let y = max(0, min(Int((mapping.yPercent / 100.0) * Double(displayHeight)), displayHeight - 1))

            if sendTap(serial: config.targetADBSerial, x: x, y: y) {
                if config.verbose {
                    print("Tapped key \(key) -> (\(x), \(y)) on \(config.targetADBSerial) via \(context.path)")
                }
            } else {
                print("ADB tap failed for key \(key) on \(config.targetADBSerial)")
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func handleModifierFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        let isCtrlKey = keycode == 59 || keycode == 62
        let isShiftKey = keycode == 56 || keycode == 60

        if isCtrlKey && !flags.contains(.maskControl) {
            return Unmanaged.passRetained(event)
        }
        if isShiftKey && !flags.contains(.maskShift) {
            return Unmanaged.passRetained(event)
        }

        guard let key = keyIdentifier(for: event) else {
            return Unmanaged.passRetained(event)
        }

        adbQueue.async { [self] in
            guard let context = mappingContext(),
                  let mapping = context.mappings[key] else {
                if config.verbose {
                    print("No tap mapping for key \(key)")
                }
                return
            }

            guard let size = displaySize() else {
                print("Unable to read Android display size from \(config.targetADBSerial)")
                return
            }

            let displayWidth = Int(size.width)
            let displayHeight = Int(size.height)
            let x = max(0, min(Int((mapping.xPercent / 100.0) * Double(displayWidth)), displayWidth - 1))
            let y = max(0, min(Int((mapping.yPercent / 100.0) * Double(displayHeight)), displayHeight - 1))

            if sendTap(serial: config.targetADBSerial, x: x, y: y) {
                if config.verbose {
                    print("Tapped modifier \(key) -> (\(x), \(y)) on \(config.targetADBSerial) via \(context.path)")
                }
            } else {
                print("ADB tap failed for modifier \(key) on \(config.targetADBSerial)")
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func mirrorMouseEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            mirrorPrimaryMouseAsTouch(type: type, event: event)
        case .mouseMoved:
            _ = mappedPoint(from: event.location, sourcePID: config.sourcePID, targetPID: config.targetPID)
        case .scrollWheel:
            guard let displayPoint = mappedDisplayPoint(from: event.location) else {
                return
            }
            let deltaY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
            let deltaX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
            scheduleScrollGesture(at: displayPoint, deltaX: deltaX, deltaY: deltaY)

            if config.verbose {
                print("Mirrored mouse scroll as gesture dx=\(deltaX) dy=\(deltaY)")
            }
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp,
             .otherMouseDown, .otherMouseDragged, .otherMouseUp:
            guard let targetPoint = mappedPoint(from: event.location, sourcePID: config.sourcePID, targetPID: config.targetPID),
                  let rebuilt = rebuiltMouseEvent(from: event, type: type, targetPoint: targetPoint) else {
                return
            }

            rebuilt.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
            rebuilt.postToPid(config.targetPID)

            if config.verbose {
                let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
                print("Mirrored mouse \(mouseEventName(type)) button=\(buttonNumber) -> (\(Int(targetPoint.x)), \(Int(targetPoint.y)))")
            }
        default:
            return
        }
    }

    private func scheduleScrollGesture(at point: CGPoint, deltaX: Int64, deltaY: Int64) {
        let generation = stateQueue.sync { () -> Int in
            pendingScrollDeltaX += deltaX
            pendingScrollDeltaY += deltaY
            pendingScrollPoint = point
            if pendingScrollStartedAt == nil {
                pendingScrollStartedAt = CFAbsoluteTimeGetCurrent()
            }
            pendingScrollGeneration += 1
            return pendingScrollGeneration
        }

        adbQueue.asyncAfter(deadline: .now() + Self.scrollCoalesceDelay) { [self] in
            let scrollState = stateQueue.sync { () -> (CGPoint, Int64, Int64, CFTimeInterval)? in
                guard generation == pendingScrollGeneration else {
                    return nil
                }
                guard let point = pendingScrollPoint else {
                    return nil
                }
                let dx = pendingScrollDeltaX
                let dy = pendingScrollDeltaY
                let startedAt = pendingScrollStartedAt ?? CFAbsoluteTimeGetCurrent()
                pendingScrollDeltaX = 0
                pendingScrollDeltaY = 0
                pendingScrollPoint = nil
                pendingScrollStartedAt = nil
                return (point, dx, dy, startedAt)
            }

            guard let (scrollPoint, mergedDeltaX, mergedDeltaY, startedAt) = scrollState,
                  let (scaleX, scaleY) = scrollScaleFactors() else { return }

            let translatedX = Int((Double(mergedDeltaX) * scaleX).rounded())
            let translatedY = Int((Double(mergedDeltaY) * scaleY).rounded())

            let belowThreshold = abs(translatedX) < Self.minimumScrollGesturePixels
                && abs(translatedY) < Self.minimumScrollGesturePixels
            if belowThreshold {
                if config.verbose {
                    print("Ignored undersized scroll gesture dx=\(translatedX) dy=\(translatedY)")
                }
                return
            }

            guard let displaySize = displaySize() else { return }
            let displayWidth = max(1, Int(displaySize.width))
            let displayHeight = max(1, Int(displaySize.height))
            let startX = min(max(Int(scrollPoint.x), 0), displayWidth - 1)
            let startY = min(max(Int(scrollPoint.y), 0), displayHeight - 1)
            let endX = min(max(startX + translatedX, 0), displayWidth - 1)
            let endY = min(max(startY + translatedY, 0), displayHeight - 1)
            let observedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
            let elapsedMs = max(
                Self.minimumScrollDurationMs,
                min(Self.maximumScrollDurationMs, observedMs)
            )

            let succeeded = sendSwipe(
                serial: config.targetADBSerial,
                fromX: startX,
                fromY: startY,
                toX: endX,
                toY: endY,
                durationMs: elapsedMs
            )

            if config.verbose {
                if succeeded {
                    print("Coalesced scroll gesture dx=\(translatedX) dy=\(translatedY) duration=\(elapsedMs)ms")
                } else {
                    print("ADB scroll gesture failed from (\(startX), \(startY)) to (\(endX), \(endY))")
                }
            }
        }
    }

    private func scrollScaleFactors() -> (Double, Double)? {
        guard let sourceFrame = interactionFrame(for: config.sourcePID),
              let displaySize = displaySize(),
              sourceFrame.width > 0,
              sourceFrame.height > 0 else {
            return nil
        }

        return (
            Double(displaySize.width / sourceFrame.width),
            Double(displaySize.height / sourceFrame.height)
        )
    }

    private func rebuiltScrollEvent(from event: CGEvent, targetPoint: CGPoint) -> CGEvent? {
        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let units: CGScrollEventUnit = isContinuous ? .pixel : .line
        let wheel1Field: CGEventField = isContinuous ? .scrollWheelEventPointDeltaAxis1 : .scrollWheelEventDeltaAxis1
        let wheel2Field: CGEventField = isContinuous ? .scrollWheelEventPointDeltaAxis2 : .scrollWheelEventDeltaAxis2
        let wheel3Field: CGEventField = isContinuous ? .scrollWheelEventPointDeltaAxis3 : .scrollWheelEventDeltaAxis3

        let wheel1 = Int32(event.getIntegerValueField(wheel1Field))
        let wheel2 = Int32(event.getIntegerValueField(wheel2Field))
        let wheel3 = Int32(event.getIntegerValueField(wheel3Field))

        guard let rebuilt = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 3,
            wheel1: wheel1,
            wheel2: wheel2,
            wheel3: wheel3
        ) else {
            return nil
        }

        rebuilt.location = targetPoint
        rebuilt.flags = event.flags
        rebuilt.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        rebuilt.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        rebuilt.setIntegerValueField(.scrollWheelEventDeltaAxis3, value: event.getIntegerValueField(.scrollWheelEventDeltaAxis3))
        rebuilt.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        rebuilt.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        rebuilt.setIntegerValueField(.scrollWheelEventPointDeltaAxis3, value: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis3))
        rebuilt.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1))
        rebuilt.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2))
        rebuilt.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis3, value: event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis3))
        rebuilt.setIntegerValueField(.scrollWheelEventIsContinuous, value: event.getIntegerValueField(.scrollWheelEventIsContinuous))
        rebuilt.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.getIntegerValueField(.scrollWheelEventScrollPhase))
        rebuilt.setIntegerValueField(.scrollWheelEventMomentumPhase, value: event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        rebuilt.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(config.targetPID))
        return rebuilt
    }

    private func mirrorPrimaryMouseAsTouch(type: CGEventType, event: CGEvent) {
        if let chromeTargetPoint = mappedChromePoint(from: event.location) {
            mirrorChromePrimaryMouse(type: type, event: event, targetPoint: chromeTargetPoint)
            return
        }

        guard let displayPoint = mappedDisplayPoint(from: event.location) else {
            return
        }

        switch type {
        case .leftMouseDown:
            let dragMode = config.dragMode
            stateQueue.sync {
                activeLeftTouchStart = displayPoint
                activeLeftTouchCurrent = displayPoint
                activeLeftTouchStartedAt = CFAbsoluteTimeGetCurrent()
                activeLeftTouchLastSent = displayPoint
            }
            if config.verbose {
                print("Mirrored mouse leftDown as dragStart [\(dragMode.rawValue)] -> (\(Int(displayPoint.x)), \(Int(displayPoint.y)))")
            }
        case .leftMouseDragged:
            stateQueue.sync {
                activeLeftTouchCurrent = displayPoint
            }
            if config.dragMode == .segmentedSwipe {
                scheduleStreamingDrag()
            }
            if config.verbose {
                print("Mirrored mouse leftDragged as dragMove -> (\(Int(displayPoint.x)), \(Int(displayPoint.y)))")
            }
        case .leftMouseUp:
            let touchPath = stateQueue.sync { () -> (CGPoint, CGPoint, CFTimeInterval, CGPoint)? in
                guard let start = activeLeftTouchStart else {
                    return nil
                }
                let end = activeLeftTouchCurrent ?? displayPoint
                let startedAt = activeLeftTouchStartedAt ?? CFAbsoluteTimeGetCurrent()
                let lastSent = activeLeftTouchLastSent ?? start
                activeLeftTouchStart = nil
                activeLeftTouchCurrent = nil
                activeLeftTouchStartedAt = nil
                activeLeftTouchLastSent = nil
                leftDragStreaming = false
                return (start, end, startedAt, lastSent)
            }

            let finalPath = touchPath ?? (displayPoint, displayPoint, CFAbsoluteTimeGetCurrent(), displayPoint)
            adbQueue.async { [self] in
                let start = finalPath.0
                let end = finalPath.1
                let startedAt = finalPath.2
                var lastSent = finalPath.3
                let distance = hypot(end.x - start.x, end.y - start.y)

                if distance < 8 {
                    let succeeded = sendTap(serial: config.targetADBSerial, x: Int(end.x), y: Int(end.y))
                    if config.verbose {
                        if succeeded {
                            print("Mirrored mouse leftUp with tap fallback -> (\(Int(end.x)), \(Int(end.y)))")
                        } else {
                            print("ADB tap fallback failed for mirrored left click")
                        }
                    }
                } else {
                    switch config.dragMode {
                    case .coalescedSwipe, .virtualTouchExperiment:
                        let observedMs = Int(((CFAbsoluteTimeGetCurrent() - startedAt) * 1000).rounded())
                        let durationMs = max(120, min(1200, observedMs))
                        let succeeded = sendSwipe(
                            serial: config.targetADBSerial,
                            fromX: Int(start.x),
                            fromY: Int(start.y),
                            toX: Int(end.x),
                            toY: Int(end.y),
                            durationMs: durationMs
                        )
                        if config.verbose {
                            let modeLabel = config.dragMode == .virtualTouchExperiment ? "virtual-touch-experiment (fallback)" : "coalesced drag"
                            if succeeded {
                                print("Mirrored mouse leftUp as \(modeLabel) -> (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y))) duration=\(durationMs)ms")
                            } else {
                                print("ADB \(modeLabel) failed from (\(Int(start.x)), \(Int(start.y))) to (\(Int(end.x)), \(Int(end.y)))")
                            }
                        }
                    case .segmentedSwipe:
                        let tailDistance = hypot(end.x - lastSent.x, end.y - lastSent.y)
                        if tailDistance >= 2 {
                            _ = sendSwipe(
                                serial: config.targetADBSerial,
                                fromX: Int(lastSent.x),
                                fromY: Int(lastSent.y),
                                toX: Int(end.x),
                                toY: Int(end.y),
                                durationMs: 18
                            )
                            lastSent = end
                        }
                        if config.verbose {
                            print("Mirrored mouse leftUp as segmented dragEnd -> (\(Int(start.x)), \(Int(start.y))) to (\(Int(lastSent.x)), \(Int(lastSent.y)))")
                        }
                    }
                }
            }
        default:
            break
        }
    }

    private func mirrorChromePrimaryMouse(type: CGEventType, event: CGEvent, targetPoint: CGPoint) {
        guard let rebuilt = rebuiltMouseEvent(from: event, type: type, targetPoint: targetPoint) else {
            return
        }

        rebuilt.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
        rebuilt.postToPid(config.targetPID)

        if config.verbose {
            print("Mirrored chrome mouse \(mouseEventName(type)) -> (\(Int(targetPoint.x)), \(Int(targetPoint.y)))")
        }
    }

    private func rebuiltMouseEvent(from event: CGEvent, type: CGEventType, targetPoint: CGPoint) -> CGEvent? {
        let buttonNumberValue = event.getIntegerValueField(.mouseEventButtonNumber)
        let clickState = event.getIntegerValueField(.mouseEventClickState)
        let pressure = event.getDoubleValueField(.mouseEventPressure)
        let mouseButton = cgMouseButton(for: buttonNumberValue)

        guard let rebuilt = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: targetPoint, mouseButton: mouseButton) else {
            return nil
        }

        rebuilt.flags = event.flags
        rebuilt.setIntegerValueField(.mouseEventButtonNumber, value: buttonNumberValue)
        rebuilt.setIntegerValueField(.mouseEventClickState, value: clickState)
        rebuilt.setDoubleValueField(.mouseEventPressure, value: pressure)
        rebuilt.setIntegerValueField(.mouseEventDeltaX, value: event.getIntegerValueField(.mouseEventDeltaX))
        rebuilt.setIntegerValueField(.mouseEventDeltaY, value: event.getIntegerValueField(.mouseEventDeltaY))
        rebuilt.setIntegerValueField(.mouseEventInstantMouser, value: event.getIntegerValueField(.mouseEventInstantMouser))
        rebuilt.setIntegerValueField(.mouseEventNumber, value: event.getIntegerValueField(.mouseEventNumber))
        rebuilt.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(config.targetPID))
        return rebuilt
    }

    private func cgMouseButton(for buttonNumber: Int64) -> CGMouseButton {
        switch buttonNumber {
        case 0: return .left
        case 1: return .right
        case 2: return .center
        default: return CGMouseButton(rawValue: UInt32(max(buttonNumber, 0))) ?? .center
        }
    }

    private func mouseEventName(_ type: CGEventType) -> String {
        switch type {
        case .mouseMoved: return "moved"
        case .scrollWheel: return "scroll"
        case .leftMouseDown: return "leftDown"
        case .leftMouseDragged: return "leftDragged"
        case .leftMouseUp: return "leftUp"
        case .rightMouseDown: return "rightDown"
        case .rightMouseDragged: return "rightDragged"
        case .rightMouseUp: return "rightUp"
        case .otherMouseDown: return "otherDown"
        case .otherMouseDragged: return "otherDragged"
        case .otherMouseUp: return "otherUp"
        default: return String(type.rawValue)
        }
    }

    private func keyIdentifier(for event: CGEvent) -> String? {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if let fallback = fallbackKeyMap[keycode] {
            return fallback
        }

        if let nsEvent = NSEvent(cgEvent: event),
           let chars = nsEvent.charactersIgnoringModifiers,
           !chars.isEmpty {
            return normalizeBlueStacksKey(chars)
        }

        return nil
    }

    private func isEmergencyExitHotkey(_ event: CGEvent) -> Bool {
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == 53 else { return false }
        let flags = event.flags
        return flags.contains(.maskControl) && flags.contains(.maskShift)
    }

    private func sidebarSystemAction(for event: CGEvent) -> (name: String, keycode: Int)? {
        let flags = event.flags
        guard flags.contains(.maskControl), flags.contains(.maskShift) else {
            return nil
        }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        switch keycode {
        case 18:
            return ("home", 3)
        case 19:
            return ("back", 4)
        case 23:
            return ("overview", 187)
        default:
            return nil
        }
    }

    private func displaySize() -> CGSize? {
        stateQueue.sync {
            if let cachedDisplaySize { return cachedDisplaySize }
            let size = androidDisplaySize(serial: config.targetADBSerial)
            cachedDisplaySize = size
            return size
        }
    }

    private func androidDisplaySize(serial: String) -> CGSize? {
        guard let adbPath = blueStacksADBPath() else { return nil }
        guard let output = runCommand([
            adbPath,
            "-s", serial,
            "shell", "-T", "wm", "size"
        ]) else { return nil }

        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(\d+)x(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let widthRange = Range(match.range(at: 1), in: text),
              let heightRange = Range(match.range(at: 2), in: text),
              let width = Int(text[widthRange]),
              let height = Int(text[heightRange]) else {
            return nil
        }

        return CGSize(width: width, height: height)
    }

    private func sendTap(serial: String, x: Int, y: Int) -> Bool {
        guard let adbPath = blueStacksADBPath() else { return false }
        return runCommand([
            adbPath,
            "-s", serial,
            "shell", "-T", "input", "tap",
            String(x), String(y)
        ]) != nil
    }

    private func sendSwipe(serial: String, fromX: Int, fromY: Int, toX: Int, toY: Int, durationMs: Int) -> Bool {
        guard let adbPath = blueStacksADBPath() else { return false }
        return runCommand([
            adbPath,
            "-s", serial,
            "shell", "-T", "input", "swipe",
            String(fromX), String(fromY),
            String(toX), String(toY),
            String(durationMs)
        ]) != nil
    }

    private func sendKeyEvent(serial: String, keycode: Int) -> Bool {
        guard let adbPath = blueStacksADBPath() else { return false }
        return runCommand([
            adbPath,
            "-s", serial,
            "shell", "-T", "input", "keyevent",
            String(keycode)
        ]) != nil
    }

    private func scheduleStreamingDrag() {
        let shouldStart = stateQueue.sync { () -> Bool in
            guard !leftDragStreaming, activeLeftTouchStart != nil else {
                return false
            }
            leftDragStreaming = true
            return true
        }

        guard shouldStart else { return }

        adbQueue.async { [self] in
            while true {
                let state = stateQueue.sync { () -> (start: CGPoint?, current: CGPoint?, lastSent: CGPoint?) in
                    (activeLeftTouchStart, activeLeftTouchCurrent, activeLeftTouchLastSent)
                }

                guard let start = state.start,
                      let current = state.current else {
                    stateQueue.sync { leftDragStreaming = false }
                    return
                }

                let lastSent = state.lastSent ?? start
                let distance = hypot(current.x - lastSent.x, current.y - lastSent.y)

                if distance < 2 {
                    stateQueue.sync { leftDragStreaming = false }
                    return
                }

                let succeeded = sendSwipe(
                    serial: config.targetADBSerial,
                    fromX: Int(lastSent.x),
                    fromY: Int(lastSent.y),
                    toX: Int(current.x),
                    toY: Int(current.y),
                    durationMs: 18
                )

                stateQueue.sync {
                    activeLeftTouchLastSent = current
                    leftDragStreaming = false
                }

                if config.verbose && !succeeded {
                    print("ADB drag segment failed from (\(Int(lastSent.x)), \(Int(lastSent.y))) to (\(Int(current.x)), \(Int(current.y)))")
                }

                let needsAnotherPass = stateQueue.sync { () -> Bool in
                    guard let newest = activeLeftTouchCurrent,
                          let newestLastSent = activeLeftTouchLastSent,
                          activeLeftTouchStart != nil else {
                        return false
                    }
                    if hypot(newest.x - newestLastSent.x, newest.y - newestLastSent.y) >= 2 {
                        leftDragStreaming = true
                        return true
                    }
                    return false
                }

                if !needsAnotherPass {
                    return
                }
            }
        }
    }

    private func runCommand(_ args: [String]) -> String? {
        guard let result = runProcess(args) else {
            return nil
        }
        if result.status == 0 {
            return result.stdout
        }
        if config.verbose, !result.stderr.isEmpty {
            print(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func mappingContext() -> (package: String?, path: String, mappings: [String: TapMapping])? {
        stateQueue.sync {
            let currentPackage = config.mappingFilePathOverride == nil
                ? foregroundPackage(serial: config.targetADBSerial)
                : nil

            if let cachedMappingContext {
                let reuseFixedOverride = config.mappingFilePathOverride != nil
                let reuseSamePackage = cachedMappingContext.package == currentPackage
                if reuseFixedOverride || reuseSamePackage {
                    return cachedMappingContext
                }
            }

            let path = config.mappingFilePathOverride ?? autoSelectMappingFile(serial: config.targetADBSerial, verbose: config.verbose)
            guard let path else { return nil }

            let mappings = loadTapMappings(from: path)
            let context = (package: currentPackage, path: path, mappings: mappings)
            cachedMappingContext = context

            if config.verbose {
                print("Resolved mapping package=\(currentPackage ?? "unknown") file=\(path) tap_count=\(mappings.count)")
            }
            return context
        }
    }

    private func mappedPoint(from globalPoint: CGPoint, sourcePID: pid_t, targetPID: pid_t) -> CGPoint? {
        guard let sourceFrame = interactionFrame(for: sourcePID),
              let targetFrame = interactionFrame(for: targetPID),
              sourceFrame.width > 0,
              sourceFrame.height > 0 else {
            return nil
        }

        let relativeX = (globalPoint.x - sourceFrame.minX) / sourceFrame.width
        let relativeY = (globalPoint.y - sourceFrame.minY) / sourceFrame.height
        let clampedX = min(max(relativeX, 0), 1)
        let clampedY = min(max(relativeY, 0), 1)

        return CGPoint(
            x: targetFrame.minX + (targetFrame.width * clampedX),
            y: targetFrame.minY + (targetFrame.height * clampedY)
        )
    }

    private func mappedChromePoint(from globalPoint: CGPoint) -> CGPoint? {
        guard let sourceWindow = focusedWindowFrame(for: config.sourcePID),
              let targetWindow = focusedWindowFrame(for: config.targetPID),
              let sourceContent = interactionFrame(for: config.sourcePID),
              sourceWindow.contains(globalPoint),
              !sourceContent.contains(globalPoint),
              sourceWindow.width > 0,
              sourceWindow.height > 0 else {
            return nil
        }

        let relativeX = (globalPoint.x - sourceWindow.minX) / sourceWindow.width
        let relativeY = (globalPoint.y - sourceWindow.minY) / sourceWindow.height
        let clampedX = min(max(relativeX, 0), 1)
        let clampedY = min(max(relativeY, 0), 1)

        return CGPoint(
            x: targetWindow.minX + (targetWindow.width * clampedX),
            y: targetWindow.minY + (targetWindow.height * clampedY)
        )
    }

    private func mappedDisplayPoint(from globalPoint: CGPoint) -> CGPoint? {
        guard let sourceFrame = interactionFrame(for: config.sourcePID),
              sourceFrame.width > 0,
              sourceFrame.height > 0,
              let displaySize = displaySize(),
              displaySize.width > 0,
              displaySize.height > 0 else {
            return nil
        }

        let relativeX = min(max((globalPoint.x - sourceFrame.minX) / sourceFrame.width, 0), 1)
        let relativeY = min(max((globalPoint.y - sourceFrame.minY) / sourceFrame.height, 0), 1)

        return CGPoint(
            x: relativeX * displaySize.width,
            y: relativeY * displaySize.height
        )
    }


    private func interactionFrame(for pid: pid_t) -> CGRect? {
        guard let windowFrame = focusedWindowFrame(for: pid) else {
            return nil
        }
        return adjustedInteractionFrame(from: windowFrame)
    }

    private func focusedWindowFrame(for pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)

        guard focusedError == .success,
              let window = value,
              CFGetTypeID(window) == AXUIElementGetTypeID() else {
            return frontWindowFrame(for: pid)
        }

        let axWindow = window as! AXUIElement
        guard let position = axPointValue(of: axWindow, attribute: kAXPositionAttribute),
              let size = axSizeValue(of: axWindow, attribute: kAXSizeAttribute) else {
            return frontWindowFrame(for: pid)
        }

        return CGRect(origin: position, size: size)
    }

    private func adjustedInteractionFrame(from windowFrame: CGRect) -> CGRect {
        let titleBarHeight = max(24.0, min(36.0, windowFrame.height * 0.06))
        let rightSidebarWidth = max(42.0, min(64.0, windowFrame.width * 0.045))
        let horizontalInset: CGFloat = 4.0
        let adjustedHeight = max(1.0, windowFrame.height - titleBarHeight)
        let adjustedWidth = max(1.0, windowFrame.width - rightSidebarWidth - horizontalInset)
        return CGRect(
            x: windowFrame.minX + horizontalInset,
            y: windowFrame.minY + titleBarHeight,
            width: adjustedWidth,
            height: adjustedHeight
        )
    }

    private func frontWindowFrame(for pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windows {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            return bounds
        }

        return nil
    }

    private func axPointValue(of element: AXUIElement, attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let typedValue = axValue as! AXValue
        var point = CGPoint.zero
        return AXValueGetValue(typedValue, .cgPoint, &point) ? point : nil
    }

    private func axSizeValue(of element: AXUIElement, attribute: String) -> CGSize? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID() else {
            return nil
        }

        let typedValue = axValue as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(typedValue, .cgSize, &size) ? size : nil
    }
}

private func loadBlueStacksInstances() -> [BlueStacksInstance] {
    guard let contents = try? String(contentsOfFile: blueStacksConfigPath, encoding: .utf8) else {
        return []
    }

    let pattern = #"bst\.instance\.([^.]+)\.adb_port="(\d+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return []
    }

    let range = NSRange(contents.startIndex..., in: contents)
    return regex.matches(in: contents, range: range).compactMap { match in
        guard let nameRange = Range(match.range(at: 1), in: contents),
              let portRange = Range(match.range(at: 2), in: contents),
              let port = Int(contents[portRange]) else {
            return nil
        }
        return BlueStacksInstance(name: String(contents[nameRange]), adbPort: port)
    }
}

func runningBlueStacksPortsByPID() -> [pid_t: Int] {
    let configuredPorts = Set(loadBlueStacksInstances().map(\.adbPort))
    let blueStacksPIDs = Set(discoverCandidates().map(\.pid))

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-iTCP", "-sTCP:LISTEN", "-n", "-P"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return [:]
    }

    guard process.terminationStatus == 0,
          let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
        return [:]
    }

    var result: [pid_t: Int] = [:]
    for line in output.split(separator: "\n").dropFirst() {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 9,
              let pid = Int32(parts[1]),
              blueStacksPIDs.contains(pid_t(pid)),
              let endpoint = parts[8...].first(where: { $0.contains(":") }),
              let portString = endpoint.split(separator: ":").last,
              let port = Int(portString) else {
            continue
        }

        if !configuredPorts.isEmpty && !configuredPorts.contains(port) {
            continue
        }

        result[pid_t(pid)] = port
    }
    return result
}

func adbSerial(for targetPID: pid_t) -> String? {
    let portsByPID = runningBlueStacksPortsByPID()
    if let port = portsByPID[targetPID] {
        return "127.0.0.1:\(port)"
    }

    let blueStacksPIDs = discoverCandidates().map(\.pid).sorted()
    let sortedPorts = Array(portsByPID.values).sorted()
    if let pidIndex = blueStacksPIDs.firstIndex(of: targetPID),
       pidIndex < sortedPorts.count {
        return "127.0.0.1:\(sortedPorts[pidIndex])"
    }

    let instances = loadBlueStacksInstances()
    let sortedInstancePorts = instances.map(\.adbPort).sorted()
    if let pidIndex = blueStacksPIDs.firstIndex(of: targetPID),
       pidIndex < sortedInstancePorts.count {
        return "127.0.0.1:\(sortedInstancePorts[pidIndex])"
    }

    if instances.count == 1, let only = instances.first {
        return "127.0.0.1:\(only.adbPort)"
    }

    return nil
}

func foregroundPackage(serial: String) -> String? {
    guard let adbPath = blueStacksADBPath() else {
        return nil
    }
    let commands: [[String]] = [
        [adbPath, "-s", serial, "shell", "-T", "dumpsys", "window", "windows"],
        [adbPath, "-s", serial, "shell", "-T", "dumpsys", "activity", "activities"]
    ]

    let patterns = [
        #"mCurrentFocus.+ ([A-Za-z0-9._]+)\/"#,
        #"mFocusedApp.+ ([A-Za-z0-9._]+)\/"#,
        #"topResumedActivity.+ ([A-Za-z0-9._]+)\/"#,
        #"ResumedActivity.+ ([A-Za-z0-9._]+)\/"#
    ]

    for command in commands {
        guard let result = runProcess(command), result.status == 0 else {
            continue
        }
        let text = result.stdout
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let packageRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            return String(text[packageRange])
        }
    }

    return nil
}

func autoSelectMappingFile(serial: String, verbose: Bool) -> String? {
    let launcherPackages: Set<String> = ["com.uncube.launcher3", "com.bluestacks.gamecenter"]

    if let package = foregroundPackage(serial: serial) {
        let directPath = URL(fileURLWithPath: blueStacksMappingDir).appendingPathComponent("\(package).cfg").path
        if launcherPackages.contains(package) {
            if FileManager.default.fileExists(atPath: directPath) {
                if verbose {
                    print("Detected foreground package \(package)")
                    print("Using launcher/system mapping file \(directPath)")
                }
                return directPath
            }
        } else if FileManager.default.fileExists(atPath: directPath) {
            if verbose {
                print("Detected foreground package \(package)")
                print("Using mapping file \(directPath)")
            }
            return directPath
        }
        if verbose {
            print("Detected foreground package \(package), but no matching cfg was found")
        }
    } else if verbose {
        print("Unable to detect foreground package over ADB, falling back to latest cfg")
    }

    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: URL(fileURLWithPath: blueStacksMappingDir),
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    let filtered = entries.filter { url in
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".cfg") && !name.contains("gamecenter") && !name.contains("launcher")
    }

    let sorted = filtered.sorted { lhs, rhs in
        let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return l > r
    }

    return sorted.first?.path
}

func loadTapMappings(from path: String) -> [String: TapMapping] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let schemes = object["ControlSchemes"] as? [[String: Any]] else {
        return [:]
    }

    let selectedScheme =
        schemes.first(where: { ($0["Selected"] as? Bool) == true })
        ?? schemes.first(where: { (($0["GameControls"] as? [[String: Any]]) ?? []).contains(where: { ($0["Type"] as? String) == "Tap" }) })
        ?? schemes.first

    guard let controls = selectedScheme?["GameControls"] as? [[String: Any]] else {
        return [:]
    }

    var mappings: [String: TapMapping] = [:]
    for control in controls {
        guard let type = control["Type"] as? String, type == "Tap",
              let key = control["Key"] as? String, !key.isEmpty,
              let x = control["X"] as? Double,
              let y = control["Y"] as? Double else {
            continue
        }
        let mapping = TapMapping(key: key, xPercent: x, yPercent: y)
        for normalized in equivalentKeys(for: normalizeBlueStacksKey(key)) {
            mappings[normalized] = mapping
        }
    }
    return mappings
}

func normalizeBlueStacksKey(_ key: String) -> String {
    let lower = key.lowercased()
    switch lower {
    case "space": return "space"
    case "ctrl", "control": return "ctrl"
    case "shift": return "shift"
    case "tab": return "tab"
    case "mouserbutton": return "mouserbutton"
    case "oem3": return "oem3"
    case "oemminus": return "oemminus"
    case "oemplus": return "oemplus"
    default: return lower
    }
}

func equivalentKeys(for normalizedKey: String) -> Set<String> {
    for group in equivalentKeyGroups where group.contains(normalizedKey) {
        return group
    }
    return [normalizedKey]
}

func parseSynchronizerArguments(_ args: [String]) -> Config? {
    var sourcePID: pid_t?
    var targetPID: pid_t?
    var verbose = false
    var mappingFilePath: String?
    var triggerKey: String?
    var targetADBSerialOverride: String?
    var dragMode = DragMode.coalescedSwipe

    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--source-pid":
            index += 1
            guard index < args.count, let value = Int32(args[index]) else { return nil }
            sourcePID = pid_t(value)
        case "--target-pid":
            index += 1
            guard index < args.count, let value = Int32(args[index]) else { return nil }
            targetPID = pid_t(value)
        case "--mapping-file":
            index += 1
            guard index < args.count else { return nil }
            mappingFilePath = args[index]
        case "--trigger-key":
            index += 1
            guard index < args.count else { return nil }
            triggerKey = args[index]
        case "--target-adb-serial":
            index += 1
            guard index < args.count else { return nil }
            targetADBSerialOverride = args[index]
        case "--verbose":
            verbose = true
        case "--drag-mode":
            index += 1
            guard index < args.count, let value = DragMode(rawValue: args[index]) else { return nil }
            dragMode = value
        case "--help":
            return nil
        default:
            print("Unknown argument: \(arg)")
            return nil
        }
        index += 1
    }

    if triggerKey != nil, sourcePID == nil, let targetPID, targetPID > 0 {
        sourcePID = targetPID
    }

    guard let sourcePID, let targetPID,
          triggerKey != nil || sourcePID != targetPID else {
        return nil
    }

    let targetADBSerial = targetADBSerialOverride ?? adbSerial(for: targetPID)
    guard let targetADBSerial else {
        print("Unable to determine ADB serial for target PID \(targetPID).")
        print("Make sure BlueStacks instance ADB ports are listening.")
        return nil
    }

    return Config(
        sourcePID: sourcePID,
        targetPID: targetPID,
        targetADBSerial: targetADBSerial,
        verbose: verbose,
        mappingFilePathOverride: mappingFilePath,
        triggerKey: triggerKey,
        dragMode: dragMode
    )
}

func printSynchronizerUsage() {
    print("""
    Usage:
      BlueStacksSynchronizer --run-bundled-helper --source-pid 12345 --target-pid 12346 [--mapping-file /path/to/BlueStacks.cfg] [--verbose]
      BlueStacksSynchronizer --run-bundled-helper --target-pid 12346 --trigger-key 1 [--mapping-file /path/to/BlueStacks.cfg] [--target-adb-serial 127.0.0.1:5565]
    """)
}

let fallbackKeyMap: [Int: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 17: "t", 31: "o",
    32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k", 45: "n",
    46: "m", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6",
    26: "7", 28: "8", 25: "9", 29: "0", 48: "tab", 49: "space",
    56: "shift", 60: "shift",
    59: "ctrl", 62: "ctrl",
    123: "left", 124: "right", 125: "down", 126: "up"
]

func runBundledSynchronizer(with arguments: [String]) -> Never {
    guard let config = parseSynchronizerArguments(arguments) else {
        printSynchronizerUsage()
        exit(1)
    }
    ADBSynchronizer(config: config).run()
    exit(0)
}
