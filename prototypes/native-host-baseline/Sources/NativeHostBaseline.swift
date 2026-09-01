import AppKit
import Carbon
import Darwin.Mach

private let processEntry = ContinuousClock.now
private let menuItemCount = 8
private let menuDiameter: CGFloat = 320

private struct Arguments {
    enum Mode: String { case benchmark, interactive }

    var mode: Mode = .interactive
    var iterations = 200
    var warmups = 20
    var outputDirectory = "measurements/manual-latest"

    init() {
        var values = Array(CommandLine.arguments.dropFirst())
        if let first = values.first, let parsed = Mode(rawValue: first) {
            mode = parsed
            values.removeFirst()
        }

        var index = 0
        while index < values.count {
            switch values[index] {
            case "--iterations" where index + 1 < values.count:
                iterations = Int(values[index + 1]) ?? iterations
                index += 2
            case "--warmups" where index + 1 < values.count:
                warmups = Int(values[index + 1]) ?? warmups
                index += 2
            case "--output" where index + 1 < values.count:
                outputDirectory = values[index + 1]
                index += 2
            default:
                fputs("Unknown argument: \(values[index])\n", stderr)
                exit(64)
            }
        }

        guard iterations > 0, warmups >= 0 else {
            fputs("--iterations must be positive and --warmups must not be negative\n", stderr)
            exit(64)
        }
    }
}

private struct Sample {
    let sequence: Int
    let phase: String
    let iteration: Int
    let metric: String
    let value: Double
    let unit: String
    let automated: Bool
    let measuredAt: String

    var json: [String: Any] {
        [
            "schema_version": 1,
            "record_type": "sample",
            "sequence": sequence,
            "phase": phase,
            "iteration": iteration,
            "metric": metric,
            "value": value,
            "unit": unit,
            "automated": automated,
            "measured_at": measuredAt
        ]
    }
}

private final class Measurements {
    private let rawURL: URL
    private let summaryURL: URL
    private var samples: [Sample] = []
    private let iso8601 = ISO8601DateFormatter()
    private let mode: String
    private let automated: Bool

    init(outputDirectory: String, mode: String, automated: Bool) {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directory = URL(fileURLWithPath: outputDirectory, relativeTo: currentDirectory).standardizedFileURL
        rawURL = directory.appendingPathComponent("raw.jsonl")
        summaryURL = directory.appendingPathComponent("summary.json")
        self.mode = mode
        self.automated = automated

        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: rawURL.path, contents: nil)
    }

    func record(phase: String, iteration: Int, metric: String, value: Double, unit: String) {
        let sample = Sample(
            sequence: samples.count + 1,
            phase: phase,
            iteration: iteration,
            metric: metric,
            value: value,
            unit: unit,
            automated: automated,
            measuredAt: iso8601.string(from: Date())
        )
        samples.append(sample)

        let data = try! JSONSerialization.data(withJSONObject: sample.json, options: [.sortedKeys])
        let handle = try! FileHandle(forWritingTo: rawURL)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: data)
        try! handle.write(contentsOf: Data([0x0a]))
        try! handle.close()
    }

    func writeSummary(iterations: Int, warmups: Int, automationScope: String) {
        var metrics: [String: Any] = [:]
        let groups = Dictionary(grouping: samples) { "\($0.phase).\($0.metric)" }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let values = group.map(\.value).sorted()
            metrics[key] = [
                "count": values.count,
                "unit": group[0].unit,
                "min": values.first!,
                "mean": values.reduce(0, +) / Double(values.count),
                "p50": percentile(values, 0.50),
                "p95": percentile(values, 0.95),
                "max": values.last!
            ]
        }

        let process = ProcessInfo.processInfo
        let displayMode = CGDisplayCopyDisplayMode(CGMainDisplayID())
        var loadAverage = [Double](repeating: 0, count: 3)
        _ = getloadavg(&loadAverage, 3)
        let summary: [String: Any] = [
            "schema_version": 1,
            "record_type": "summary",
            "generated_at": iso8601.string(from: Date()),
            "mode": mode,
            "automated": automated,
            "iterations": iterations,
            "warmups": warmups,
            "sample_count": samples.count,
            "metrics": metrics,
            "automation_scope": automationScope,
            "measurement_method": [
                "latency_clock": "mach_continuous_time via ContinuousClock",
                "render_boundary": "NSView.displayIfNeeded plus CATransaction.flush; process-side, not photon latency",
                "private_memory": "TASK_VM_INFO.phys_footprint; physical-footprint proxy, not uniquely private dirty pages"
            ],
            "conditions": [
                "operating_system": process.operatingSystemVersionString,
                "hardware_model": shell("/usr/sbin/sysctl", ["-n", "hw.model"]),
                "cpu": shell("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
                "kernel": shell("/usr/bin/uname", ["-a"]),
                "swift_compiler": shell("/usr/bin/xcrun", ["swiftc", "--version"]),
                "physical_memory_bytes": process.physicalMemory,
                "active_processor_count": process.activeProcessorCount,
                "session_manager": shell("/bin/launchctl", ["managername"]),
                "screen_count": NSScreen.screens.count,
                "main_screen_backing_scale": NSScreen.main?.backingScaleFactor ?? 0,
                "main_display_pixels_wide": CGDisplayPixelsWide(CGMainDisplayID()),
                "main_display_pixels_high": CGDisplayPixelsHigh(CGMainDisplayID()),
                "main_display_refresh_hz": displayMode?.refreshRate ?? 0,
                "thermal_state": process.thermalState.rawValue,
                "low_power_mode": process.isLowPowerModeEnabled,
                "load_average_at_summary": loadAverage,
                "power": shell("/usr/bin/pmset", ["-g", "batt"])
            ]
        ]

        let data = try! JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: summaryURL, options: .atomic)
        print("raw=\(rawURL.path)")
        print("summary=\(summaryURL.path)")
    }

    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
    }
}

private func shell(_ executable: String, _ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
}

private func physicalFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

private func milliseconds(since start: ContinuousClock.Instant) -> Double {
    let duration = start.duration(to: .now)
    return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
}

private final class RadialMenuView: NSView {
    var acceptsEventPointerInput = true
    var selectedMenuItem: Int? { didSet { needsDisplay = true } }
    var pointerInputStarted: (() -> Void)?
    var pointerChanged: (() -> Void)?
    var selectionInputStarted: (() -> Void)?
    var primaryActionSelected: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard acceptsEventPointerInput else { return }
        updatePointer(convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard acceptsEventPointerInput else { return }
        updatePointer(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        selectedMenuItem = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        selectCurrentMenuItem()
    }

    func updatePointer(_ point: CGPoint) {
        pointerInputStarted?()
        selectedMenuItem = menuItem(at: point)
        pointerChanged?()
    }

    func selectCurrentMenuItem() {
        guard let selectedMenuItem else { return }
        selectionInputStarted?()
        primaryActionSelected?(selectedMenuItem)
    }

    private func menuItem(at point: CGPoint) -> Int? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = hypot(dx, dy)
        guard distance >= 38, distance <= 142 else { return nil }
        var angle = atan2(dy, dx) + (.pi / 2)
        if angle < 0 { angle += 2 * .pi }
        return Int((angle / (2 * .pi)) * CGFloat(menuItemCount)) % menuItemCount
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let step = 360 / CGFloat(menuItemCount)

        for index in 0..<menuItemCount {
            let path = NSBezierPath()
            path.appendArc(
                withCenter: center,
                radius: 142,
                startAngle: 90 - CGFloat(index + 1) * step + 2,
                endAngle: 90 - CGFloat(index) * step - 2
            )
            path.appendArc(
                withCenter: center,
                radius: 38,
                startAngle: 90 - CGFloat(index) * step - 2,
                endAngle: 90 - CGFloat(index + 1) * step + 2,
                clockwise: true
            )
            path.close()
            (selectedMenuItem == index
                ? NSColor.systemBlue.withAlphaComponent(0.92)
                : NSColor.windowBackgroundColor.withAlphaComponent(0.93)).setFill()
            path.fill()

            let label = "\(index + 1)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: selectedMenuItem == index ? NSColor.white : NSColor.labelColor
            ]
            let angle = (90 - (CGFloat(index) + 0.5) * step) * .pi / 180
            let point = CGPoint(x: center.x + cos(angle) * 92, y: center.y + sin(angle) * 92)
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2),
                withAttributes: attributes
            )
        }
    }
}

private final class OverlayController {
    private let panel: NSPanel
    private let menuView: RadialMenuView
    private let measurements: Measurements
    private let automated: Bool
    private(set) var isOpen = false
    private var phase = "human"
    private var iteration = 0
    private var recording = true
    private var pointerStart: ContinuousClock.Instant?
    private var selectionStart: ContinuousClock.Instant?
    private var outsideClickMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    init(measurements: Measurements, automated: Bool) {
        self.measurements = measurements
        self.automated = automated
        menuView = RadialMenuView(frame: NSRect(x: 0, y: 0, width: menuDiameter, height: menuDiameter))
        panel = NSPanel(
            contentRect: menuView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = menuView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = automated
        panel.alphaValue = automated ? 0.001 : 1
        menuView.acceptsEventPointerInput = !automated

        menuView.pointerInputStarted = { [weak self] in self?.pointerStart = .now }
        menuView.pointerChanged = { [weak self] in self?.pointerDidChange() }
        menuView.selectionInputStarted = { [weak self] in self?.selectionStart = .now }
        menuView.primaryActionSelected = { [weak self] item in self?.selectPrimaryAction(menuItem: item) }
    }

    func open(at point: CGPoint, phase: String, iteration: Int, recording: Bool) {
        self.phase = phase
        self.iteration = iteration
        self.recording = recording
        menuView.selectedMenuItem = nil

        if recording {
            measurements.record(
                phase: phase,
                iteration: iteration,
                metric: "private_memory_before_open_bytes",
                value: Double(physicalFootprintBytes()),
                unit: "bytes"
            )
        }

        let start = ContinuousClock.now
        let proposed = NSRect(
            x: point.x - menuDiameter / 2,
            y: point.y - menuDiameter / 2,
            width: menuDiameter,
            height: menuDiameter
        )
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        panel.setFrame(screen.map { constrain(proposed, to: $0.visibleFrame) } ?? proposed, display: false)
        panel.orderFrontRegardless()
        menuView.displayIfNeeded()
        CATransaction.flush()
        isOpen = true

        guard recording else { return }
        measurements.record(phase: phase, iteration: iteration, metric: "menu_open_latency_ms", value: milliseconds(since: start), unit: "ms")
        measurements.record(phase: phase, iteration: iteration, metric: "private_memory_open_bytes", value: Double(physicalFootprintBytes()), unit: "bytes")
    }

    func automateSelectionAndDismissal() {
        menuView.updatePointer(CGPoint(x: menuDiameter / 2, y: menuDiameter - 70))
        menuView.selectCurrentMenuItem()
    }

    func dismiss(reason: String) {
        guard isOpen else { return }
        let start = ContinuousClock.now
        panel.orderOut(nil)
        CATransaction.flush()
        isOpen = false

        guard recording else { return }
        measurements.record(phase: phase, iteration: iteration, metric: "menu_close_latency_ms", value: milliseconds(since: start), unit: "ms")
        measurements.record(phase: phase, iteration: iteration, metric: "private_memory_closed_bytes", value: Double(physicalFootprintBytes()), unit: "bytes")
    }

    func installDismissalMonitors() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isOpen, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.dismiss(reason: "outside_click")
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.dismiss(reason: "escape") }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.dismiss(reason: "escape")
                return nil
            }
            return event
        }
    }

    private func pointerDidChange() {
        guard let start = pointerStart else { return }
        pointerStart = nil
        menuView.displayIfNeeded()
        CATransaction.flush()
        if recording {
            measurements.record(phase: phase, iteration: iteration, metric: "pointer_selection_latency_ms", value: milliseconds(since: start), unit: "ms")
        }
    }

    private func selectPrimaryAction(menuItem: Int) {
        let start = selectionStart ?? ContinuousClock.now
        if recording {
            measurements.record(phase: phase, iteration: iteration, metric: "primary_action_latency_ms", value: milliseconds(since: start), unit: "ms")
        }
        dismiss(reason: "primary_action_selected")
    }

    private func constrain(_ rect: NSRect, to visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: min(max(rect.minX, visibleFrame.minX), visibleFrame.maxX - rect.width),
            y: min(max(rect.minY, visibleFrame.minY), visibleFrame.maxY - rect.height),
            width: rect.width,
            height: rect.height
        )
    }
}

private final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let arguments = Arguments()
    private var measurements: Measurements!
    private var overlay: OverlayController!
    private var hotKeyHandler: EventHandlerRef?
    private var invokeHotKey: EventHotKeyRef?
    private var quitHotKey: EventHotKeyRef?
    private var interactiveIteration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        measurements = Measurements(
            outputDirectory: arguments.outputDirectory,
            mode: arguments.mode.rawValue,
            automated: arguments.mode == .benchmark
        )
        overlay = OverlayController(measurements: measurements, automated: arguments.mode == .benchmark)
        measurements.record(phase: "cold", iteration: 0, metric: "host_ready_latency_ms", value: milliseconds(since: processEntry), unit: "ms")
        measurements.record(phase: "cold", iteration: 0, metric: "host_ready_private_memory_bytes", value: Double(physicalFootprintBytes()), unit: "bytes")

        switch arguments.mode {
        case .benchmark:
            DispatchQueue.main.async { [weak self] in self?.runColdCycle() }
        case .interactive:
            overlay.installDismissalMonitors()
            installGlobalHotKeys()
            print("Ready: Control-Option-Space opens or dismisses the Menu; Control-Option-Q saves and quits.")
            print("Move to a Menu Item and release to invoke its no-op Primary Action; outside click or Escape dismisses.")
        }
    }

    private func runColdCycle() {
        overlay.open(at: benchmarkPoint, phase: "cold", iteration: 0, recording: true)
        overlay.automateSelectionAndDismissal()
        DispatchQueue.main.async { [weak self] in self?.runWarmup(index: 0) }
    }

    private func runWarmup(index: Int) {
        guard index < arguments.warmups else {
            DispatchQueue.main.async { [weak self] in self?.runMeasuredCycle(index: 1) }
            return
        }
        overlay.open(at: benchmarkPoint, phase: "warmup", iteration: index + 1, recording: false)
        overlay.automateSelectionAndDismissal()
        DispatchQueue.main.async { [weak self] in self?.runWarmup(index: index + 1) }
    }

    private func runMeasuredCycle(index: Int) {
        guard index <= arguments.iterations else {
            measurements.writeSummary(
                iterations: arguments.iterations,
                warmups: arguments.warmups,
                automationScope: "Real AppKit panel lifecycle, synchronous Menu drawing, pointer geometry, no-op Primary Action acknowledgement, dismissal, and memory sampling. Direct in-process invocation; no synthetic global OS input and a nearly transparent panel."
            )
            NSApp.terminate(nil)
            return
        }
        overlay.open(at: benchmarkPoint, phase: "warm", iteration: index, recording: true)
        overlay.automateSelectionAndDismissal()
        DispatchQueue.main.async { [weak self] in self?.runMeasuredCycle(index: index + 1) }
    }

    private var benchmarkPoint: CGPoint {
        NSScreen.main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? CGPoint(x: 500, y: 500)
    }

    private func installGlobalHotKeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<ApplicationDelegate>.fromOpaque(context).takeUnretainedValue()
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr else { return status }
                delegate.handleHotKey(identifier.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        )

        let signature = OSType(0x53504E54) // SPNT
        let modifiers = UInt32(controlKey | optionKey)
        let invokeStatus = RegisterEventHotKey(
            UInt32(kVK_Space), modifiers, EventHotKeyID(signature: signature, id: 1),
            GetApplicationEventTarget(), 0, &invokeHotKey
        )
        let quitStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Q), modifiers, EventHotKeyID(signature: signature, id: 2),
            GetApplicationEventTarget(), 0, &quitHotKey
        )
        if handlerStatus != noErr || invokeStatus != noErr || quitStatus != noErr {
            fputs("Global hotkey registration failed: handler=\(handlerStatus), invoke=\(invokeStatus), quit=\(quitStatus)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func handleHotKey(_ identifier: UInt32) {
        switch identifier {
        case 1 where overlay.isOpen:
            overlay.dismiss(reason: "global_hotkey_toggle")
        case 1:
            interactiveIteration += 1
            overlay.open(at: NSEvent.mouseLocation, phase: "human", iteration: interactiveIteration, recording: true)
        case 2:
            if overlay.isOpen { overlay.dismiss(reason: "quit") }
            measurements.writeSummary(
                iterations: interactiveIteration,
                warmups: 0,
                automationScope: "None. Human global invocation, pointer interaction, and dismissal in a logged-in GUI session."
            )
            NSApp.terminate(nil)
        default:
            break
        }
    }
}

private let application = NSApplication.shared
private let delegate = ApplicationDelegate()
application.delegate = delegate
application.run()
