//
//  ab6a-timeShift — menubar controller for multiple WSJT-X instances.
//
//  Each instance is launched from one re-signed WSJT-X bundle with its own
//  --rig-name and its own timeshift control file, so their clocks move
//  independently and in real time.
//

import AppKit
import AVFoundation
import Foundation

// MARK: - Control file

/// Mirrors ts_control_t in src/timeshift.c. Field offsets are fixed by that
/// struct and verified against it: magic 0, version 4, offset_ns 8,
/// rate_bits 16, flags 24, generation 32, total 64 bytes.
final class ControlFile {
    static let size = 64
    static let magic: UInt32 = 0x5453_4846   // 'TSHF'
    static let version: UInt32 = 1
    static let flagMonotonic: UInt32 = 1

    let path: String
    private let base: UnsafeMutableRawPointer

    init?(path: String) {
        self.path = path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var st = stat()
        if fstat(fd, &st) != 0 { return nil }
        let fresh = st.st_size < off_t(ControlFile.size)
        if fresh && ftruncate(fd, off_t(ControlFile.size)) != 0 { return nil }

        guard let m = mmap(nil, ControlFile.size, PROT_READ | PROT_WRITE,
                           MAP_SHARED, fd, 0), m != MAP_FAILED else { return nil }
        self.base = m

        if fresh || base.load(fromByteOffset: 0, as: UInt32.self) != ControlFile.magic {
            base.storeBytes(of: ControlFile.magic, toByteOffset: 0, as: UInt32.self)
            base.storeBytes(of: ControlFile.version, toByteOffset: 4, as: UInt32.self)
            offsetNanos = 0
            rate = 1.0
            monotonic = false
            base.storeBytes(of: UInt64(1), toByteOffset: 32, as: UInt64.self)
        }
    }

    var offsetNanos: Int64 {
        get { base.load(fromByteOffset: 8, as: Int64.self) }
        set {
            base.storeBytes(of: newValue, toByteOffset: 8, as: Int64.self)
            bump()
        }
    }

    var offsetSeconds: Double {
        get { Double(offsetNanos) / 1e9 }
        set { offsetNanos = Int64((newValue * 1e9).rounded()) }
    }

    var rate: Double {
        get { Double(bitPattern: base.load(fromByteOffset: 16, as: UInt64.self)) }
        set {
            base.storeBytes(of: newValue.bitPattern, toByteOffset: 16, as: UInt64.self)
            bump()
        }
    }

    var monotonic: Bool {
        get { base.load(fromByteOffset: 24, as: UInt32.self) & ControlFile.flagMonotonic != 0 }
        set {
            base.storeBytes(of: newValue ? ControlFile.flagMonotonic : 0,
                            toByteOffset: 24, as: UInt32.self)
            bump()
        }
    }

    private func bump() {
        let g = base.load(fromByteOffset: 32, as: UInt64.self)
        base.storeBytes(of: g &+ 1, toByteOffset: 32, as: UInt64.self)
    }
}

// MARK: - Configuration

struct InstanceConfig: Codable {
    var name: String
    var rigName: String
}

struct AppConfig: Codable {
    var wsjtxApp: String
    var dylib: String
    var rangeSeconds: Double
    var stepSeconds: Double
    var instances: [InstanceConfig]
    var showPanel: Bool?

    static let `default` = AppConfig(
        wsjtxApp: "/Applications/wsjtx shift.app",
        dylib: NSHomeDirectory() + "/Developer/timeShift/lib/libtimeshift.dylib",
        rangeSeconds: 5.0,
        stepSeconds: 0.1,
        instances: [
            InstanceConfig(name: "Rig 1", rigName: "rig1"),
            InstanceConfig(name: "Rig 2", rigName: "rig2"),
        ],
        showPanel: false)
}

enum Support {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ab6a-timeShift", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var configURL: URL { directory.appendingPathComponent("config.json") }

    static func loadConfig() -> AppConfig {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: configURL),
           let cfg = try? decoder.decode(AppConfig.self, from: data) {
            return cfg
        }
        let cfg = AppConfig.default
        saveConfig(cfg)
        return cfg
    }

    static func saveConfig(_ cfg: AppConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(cfg) {
            try? data.write(to: configURL)
        }
    }
}

// MARK: - Instance

final class Instance {
    let config: InstanceConfig
    let control: ControlFile
    var process: Process?
    /// A matching WSJT-X that this app did not spawn — found by scanning the
    /// process table, so restarting the menu bar app does not lose track of
    /// instances that are still up.
    var adoptedPID: pid_t?

    var isRunning: Bool { runningPID != nil }

    /// The pid backing "running", whether we spawned it or adopted it.
    var runningPID: pid_t? {
        if let p = process, p.isRunning { return p.processIdentifier }
        if let pid = adoptedPID, kill(pid, 0) == 0 { return pid }
        return nil
    }

    /// True when the process was found in the process table rather than started
    /// here — an orphan from a previous run of this app, or a WSJT-X the user
    /// launched themselves.
    var isAdopted: Bool {
        if let p = process, p.isRunning { return false }
        return adoptedPID != nil
    }

    init?(config: InstanceConfig) {
        self.config = config
        // A blank rig name launches WSJT-X with no --rig-name, i.e. its default
        // configuration, so it needs a control file name of its own.
        let slug = config.rigName.isEmpty
            ? "default"
            : config.rigName.replacingOccurrences(of: "/", with: "_")
        let ctlPath = Support.directory
            .appendingPathComponent("\(slug).ctl").path
        guard let c = ControlFile(path: ctlPath) else { return nil }
        self.control = c
    }

    /// Launches the bundle's inner executable directly. Going through `open`
    /// would hand the request to launchd, which starts the app in a clean
    /// environment where DYLD_INSERT_LIBRARIES never arrives.
    func start(appConfig: AppConfig) throws {
        guard !isRunning else { return }

        let exe = URL(fileURLWithPath: appConfig.wsjtxApp)
            .appendingPathComponent("Contents/MacOS/wsjtx")
        guard FileManager.default.isExecutableFile(atPath: exe.path) else {
            throw NSError(domain: "AB6A TimeShift", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No WSJT-X executable at \(exe.path).\n\nMake an injectable copy first:\n"
                    + "  bin/timeshift-resign /Applications/wsjtx.app \"\(appConfig.wsjtxApp)\""
            ])
        }
        guard FileManager.default.fileExists(atPath: appConfig.dylib) else {
            throw NSError(domain: "AB6A TimeShift", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Shim not found at \(appConfig.dylib).\n\nBuild it with `make` in the timeShift project."
            ])
        }

        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = appConfig.dylib
        env["TIMESHIFT_CONTROL"] = control.path

        let p = Process()
        p.executableURL = exe
        p.arguments = config.rigName.isEmpty ? [] : ["--rig-name", config.rigName]
        p.environment = env
        adoptedPID = nil
        p.terminationHandler = { _ in
            DispatchQueue.main.async { NSApp.sendAction(#selector(AppDelegate.refresh), to: nil, from: nil) }
        }
        try p.run()
        process = p
    }

    func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            return
        }
        if let pid = adoptedPID, kill(pid, 0) == 0 {
            kill(pid, SIGTERM)
        }
    }

    /// argv for a WSJT-X started by this app is "<exe> --rig-name <rig>", or
    /// just "<exe>" for the default configuration. jt9 has its own argv[0] and
    /// so never matches.
    func matches(commandLine: String, exePath: String) -> Bool {
        guard commandLine.hasPrefix(exePath) else { return false }
        let tail = String(commandLine.dropFirst(exePath.count))
        if config.rigName.isEmpty {
            return !tail.contains("--rig-name")
        }
        return tail.contains("--rig-name \(config.rigName)")
    }
}

// MARK: - Menu row

/// One instance's controls: status, readout, slider, and fine steps.
final class InstanceRow: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let slider = NSSlider()
    private let instance: Instance
    private let step: Double
    private let onChange: () -> Void
    private let onAction: (Action) -> Void
    private let startButton = NSButton()
    /// External refreshes must not fight a drag in progress.
    private var lastLocalChange = Date.distantPast

    enum Action { case toggle, configure, remove }

    init(instance: Instance, range: Double, step: Double,
         onChange: @escaping () -> Void, onAction: @escaping (Action) -> Void) {
        self.instance = instance
        self.step = step
        self.onChange = onChange
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 74))

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right

        slider.minValue = -range
        slider.maxValue = range
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        // One tick per second for reference. Snapping to `step` is done in
        // sliderMoved: a tick per 0.1 s would render as a dotted smear.
        slider.numberOfTickMarks = Int(range * 2) + 1
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .below
        // The default fill runs from the minimum, which reads as "mostly on"
        // on a bipolar control whose neutral value is the centre.
        slider.trackFillColor = .clear

        let header = NSStackView(views: [nameLabel, NSView(), valueLabel])
        header.orientation = .horizontal

        // Start / Config / Remove, one line.
        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small
        startButton.font = .systemFont(ofSize: 11)
        startButton.target = self
        startButton.action = #selector(startTapped)

        // Fixed width so the row does not shuffle when Start becomes Stop.
        startButton.widthAnchor.constraint(equalToConstant: 58).isActive = true

        // A trailing spacer absorbs the slack, which left-justifies the buttons
        // instead of stretching them across the row.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionsStack = NSStackView(views: [
            startButton,
            actionButton("Config", #selector(configTapped)),
            actionButton("Remove", #selector(removeTapped)),
            spacer,
        ])
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 6
        actionsStack.distribution = .fill
        actionsStack.alignment = .centerY

        let stack = NSStackView(views: [header, slider, actionsStack])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sync()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    @objc private func startTapped()  { onAction(.toggle) }
    @objc private func configTapped() { onAction(.configure) }
    @objc private func removeTapped() { onAction(.remove) }

    @objc private func sliderMoved() {
        lastLocalChange = Date()
        let snapped = (slider.doubleValue / step).rounded() * step
        slider.doubleValue = snapped
        instance.control.offsetSeconds = snapped
        sync()
        onChange()
    }

    func sync() {
        let running = instance.isRunning
        let rig = instance.config.rigName.isEmpty ? "default config" : instance.config.rigName
        let text = "\(running ? "●" : "○")  \(instance.config.name)  (\(rig)) — \(running ? "running" : "stopped")"
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttribute(.foregroundColor,
                                value: running ? NSColor.systemGreen : NSColor.tertiaryLabelColor,
                                range: NSRange(location: 0, length: 1))
        attributed.addAttribute(.foregroundColor,
                                value: running ? NSColor.labelColor : NSColor.secondaryLabelColor,
                                range: NSRange(location: 1, length: text.count - 1))
        nameLabel.attributedStringValue = attributed
        startButton.title = running ? "Stop" : "Start"

        // "Is it really running?" should be answerable without reaching for ps.
        if let pid = instance.runningPID {
            toolTip = instance.isAdopted
                ? "pid \(pid) — adopted, not started by this app. Stop will send it SIGTERM."
                : "pid \(pid) — started by this app"
        } else {
            toolTip = "not running"
        }
        let secs = instance.control.offsetSeconds
        valueLabel.stringValue = String(format: "%+.3f s", secs)
        valueLabel.textColor = secs == 0 ? .secondaryLabelColor : .controlAccentColor
        if Date().timeIntervalSince(lastLocalChange) > 1.0 {
            slider.doubleValue = secs
        }
    }
}


// MARK: - Floating control panel

/// macOS shows a status item only on the display that owns the menu bar, and
/// there is no API to put one on every screen. This panel is the way around
/// that: it joins all Spaces, floats above full-screen apps, and can be dragged
/// to whichever display you are working on.
///
/// It is a non-activating panel on purpose — clicking a slider adjusts the rig
/// without taking focus away from WSJT-X.
@MainActor
final class ControlPanel: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let rowStack = NSStackView()
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private(set) var rows: [InstanceRow] = []

    var isVisible: Bool { panel.isVisible }

    init(onAddRig: @escaping () -> Void,
         onStartAll: @escaping () -> Void,
         onStopAll: @escaping () -> Void) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 404, height: 240),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.title = "AB6A TimeShift"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        rowStack.orientation = .vertical
        rowStack.spacing = 0
        rowStack.alignment = .leading
        rowStack.translatesAutoresizingMaskIntoConstraints = false

        // An NSScrollView document view that is not flipped anchors its content
        // to the BOTTOM of the clip view, which leaves the panel looking empty
        // with the rows crushed into a corner. The document view has to be
        // flipped for top-down layout.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(rowStack)

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 200)

        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            rowStack.topAnchor.constraint(equalTo: document.topAnchor),
            rowStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 392),
            scrollHeight,
        ])

        func footerButton(_ title: String, _ handler: @escaping () -> Void) -> NSButton {
            let b = NSButton(title: title,
                             target: ActionProxy.shared,
                             action: #selector(ActionProxy.fire(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            ActionProxy.shared.register(b, handler)
            return b
        }

        let footer = NSStackView(views: [
            footerButton("Add Rig…", onAddRig),
            footerButton("Start All", onStartAll),
            footerButton("Stop All", onStopAll),
        ])
        footer.orientation = .horizontal
        footer.distribution = .fillEqually
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView()
        host.addSubview(scroll)
        host.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            scroll.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 10),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
        ])

        panel.contentView = host
        super.init()
        panel.delegate = self
    }

    /// Rebuilt whenever the rig list changes; rows are the same view class the
    /// menu uses, so both stay in step through the shared control files.
    func rebuild(instances: [Instance], range: Double, step: Double,
                 onChange: @escaping () -> Void,
                 onAction: @escaping (Int, InstanceRow.Action) -> Void) {
        for view in rowStack.arrangedSubviews {
            rowStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows.removeAll()

        for (idx, inst) in instances.enumerated() {
            if idx > 0 {
                let rule = NSBox()
                rule.boxType = .separator
                rowStack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalToConstant: 380).isActive = true
            }
            let row = InstanceRow(instance: inst, range: range, step: step,
                                  onChange: onChange,
                                  onAction: { action in onAction(idx, action) })
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 380).isActive = true
            rows.append(row)
        }
        // Grow to fit the rigs, but never past what the screen can show.
        rowStack.layoutSubtreeIfNeeded()
        let wanted = rowStack.fittingSize.height
        let ceiling = (NSScreen.main?.visibleFrame.height ?? 900) - 160
        scrollHeight.constant = max(140, min(wanted, ceiling))
        panel.contentView?.layoutSubtreeIfNeeded()
        let fitted = panel.contentView?.fittingSize ?? NSSize(width: 404, height: 260)
        panel.setContentSize(NSSize(width: 404, height: fitted.height))
    }

    /// Only the origin is persisted. The height follows the rig count, so
    /// restoring a whole saved frame would fight the content size.
    private static let originKey = "ab6a-timeShift.panelOrigin"

    func windowDidMove(_ note: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin),
                                  forKey: ControlPanel.originKey)
    }

    /// Keeps the whole panel inside one display. Without this it can be placed
    /// so that it spans the gap between two screens, which is how it first
    /// landed here.
    private func clamped(_ origin: NSPoint, size: NSSize, to screen: NSScreen?) -> NSPoint {
        guard let v = (screen ?? NSScreen.main)?.visibleFrame else { return origin }
        return NSPoint(x: min(max(origin.x, v.minX), max(v.minX, v.maxX - size.width)),
                       y: min(max(origin.y, v.minY), max(v.minY, v.maxY - size.height)))
    }

    /// `screen` is whichever display currently owns the menu bar, so a first
    /// open lands next to the status item rather than on the other monitor.
    func show(on screen: NSScreen?) {
        let size = panel.frame.size
        var target: NSPoint?
        var host = screen

        if let saved = UserDefaults.standard.string(forKey: ControlPanel.originKey) {
            let origin = NSPointFromString(saved)
            let frame = NSRect(origin: origin, size: size)
            // A saved origin is honoured only if it still lands on a connected
            // display — monitors get unplugged.
            if let onScreen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(frame) }) {
                target = origin
                host = onScreen
            }
        }

        if target == nil, let v = (screen ?? NSScreen.main)?.visibleFrame {
            target = NSPoint(x: v.maxX - size.width - 24, y: v.maxY - size.height - 12)
        }

        if let t = target {
            panel.setFrameOrigin(clamped(t, size: size, to: host))
        }
        panel.orderFrontRegardless()
    }

    func close() { panel.orderOut(nil) }

    func sync() { for r in rows { r.sync() } }
}

/// Top-down layout inside an NSScrollView.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// NSButton needs a target/action pair; this keeps closures alive for them.
@MainActor
final class ActionProxy: NSObject {
    static let shared = ActionProxy()
    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    func register(_ control: NSControl, _ handler: @escaping () -> Void) {
        handlers[ObjectIdentifier(control)] = handler
    }

    @objc func fire(_ sender: NSControl) {
        handlers[ObjectIdentifier(sender)]?()
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var config = AppConfig.default
    private var instances: [Instance] = []
    private var rows: [InstanceRow] = []
    private var statusTimer: Timer?
    private var controlPanel: ControlPanel?
    static let maxInstances = 6

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = baseIcon
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        reload()
        requestMicrophoneAccess()
        updateStatusIcon()
        if config.showPanel == true { setPanelVisible(true) }

        // Instances can exit on their own; poll so the icon stays truthful even
        // when the menu is closed and no row is around to refresh itself.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async {
                self.updateStatusIcon()
                self.controlPanel?.sync()
            }
        }
    }

    /// Green while any instance is up, grey otherwise. The status bar draws a
    /// template image with its own tint and ignores contentTintColor, so both
    /// states use a palette-coloured, non-template copy of the symbol.
    private var baseIcon: NSImage? {
        NSImage(systemSymbolName: "clock.arrow.2.circlepath",
                accessibilityDescription: "AB6A TimeShift")
    }

    /// Attaches instances to WSJT-X processes this app did not spawn.
    private func adoptRunningInstances() {
        let exePath = URL(fileURLWithPath: config.wsjtxApp)
            .appendingPathComponent("Contents/MacOS/wsjtx").path

        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return }

        for inst in instances where inst.process == nil {
            inst.adoptedPID = nil
        }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[trimmed.startIndex..<space]) else { continue }
            let args = String(trimmed[trimmed.index(after: space)...])
                .trimmingCharacters(in: .whitespaces)
            for inst in instances where inst.process == nil {
                if inst.matches(commandLine: args, exePath: exePath) {
                    inst.adoptedPID = pid
                    break
                }
            }
        }
    }

    private func updateStatusIcon() {
        adoptRunningInstances()
        guard let button = statusItem.button else { return }
        let running = instances.filter { $0.isRunning }.count

        let tint: NSColor = running > 0 ? .systemGreen : .systemGray
        let tinted = baseIcon?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [tint]))
        tinted?.isTemplate = false
        button.image = tinted
        button.contentTintColor = nil
        button.toolTip = running > 0
            ? "AB6A TimeShift — \(running) instance\(running == 1 ? "" : "s") running"
            : "AB6A TimeShift — stopped"
    }

    /// WSJT-X is launched as a child of this app, so macOS attributes its
    /// microphone request to this app as the responsible process — not to the
    /// WSJT-X bundle. The grant therefore has to live here, which means this
    /// app needs its own NSMicrophoneUsageDescription and has to ask for it.
    private func requestMicrophoneAccess() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.refresh() }
        }
    }

    private var microphoneStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:     return "Microphone: granted"
        case .denied:         return "Microphone: DENIED — click to open Settings"
        case .restricted:     return "Microphone: restricted by policy"
        case .notDetermined:  return "Microphone: not yet requested"
        @unknown default:     return "Microphone: unknown"
        }
    }

    @objc private func openMicrophoneSettings() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestMicrophoneAccess()
            return
        }
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    func applicationWillTerminate(_ note: Notification) {
        for i in instances where i.isRunning { i.stop() }
    }

    private func reload() {
        config = Support.loadConfig()
        instances = config.instances.compactMap { cfg in
            let existing = instances.first { $0.config.rigName == cfg.rigName && $0.isRunning }
            return existing ?? Instance(config: cfg)
        }
    }

    @objc func refresh() {
        for r in rows { r.sync() }
        controlPanel?.sync()
        updateStatusIcon()
    }

    // MARK: Control panel

    private func panelInstance() -> ControlPanel {
        if let existing = controlPanel { return existing }
        let created = ControlPanel(
            onAddRig:   { [weak self] in self?.addRig() },
            onStartAll: { [weak self] in self?.startAll() },
            onStopAll:  { [weak self] in self?.stopAll() })
        controlPanel = created
        return created
    }

    private func rebuildPanel() {
        guard let panel = controlPanel else { return }
        panel.rebuild(instances: instances,
                      range: config.rangeSeconds,
                      step: config.stepSeconds,
                      onChange: { [weak self] in self?.refresh() },
                      onAction: { [weak self] idx, action in
                          guard let self else { return }
                          switch action {
                          case .toggle:    self.toggleInstance(at: idx)
                          case .configure: self.editRig(at: idx)
                          case .remove:    self.removeRig(at: idx)
                          }
                      })
        panel.sync()
    }

    @objc private func toggleControlPanel() {
        setPanelVisible(!(controlPanel?.isVisible ?? false))
    }

    private func setPanelVisible(_ visible: Bool) {
        let panel = panelInstance()
        if visible {
            rebuildPanel()
            panel.show(on: statusItem.button?.window?.screen)
        } else {
            panel.close()
        }
        config.showPanel = visible
        Support.saveConfig(config)
    }

    // MARK: Instance configuration

    /// Saves the edited configuration and rebuilds, preserving running instances.
    private func persist(_ updated: AppConfig) {
        config = updated
        Support.saveConfig(updated)
        instances = updated.instances.compactMap { cfg in
            instances.first { $0.config.rigName == cfg.rigName && $0.isRunning }
                ?? Instance(config: cfg)
        }
        rebuildPanel()
        refresh()
    }

    /// WSJT-X refuses to run two instances under the same rig name, so the name
    /// has to be unique here too. Blank is a legal value — it means the default
    /// configuration — but only one instance can claim it.
    private func rigNameTaken(_ rigName: String, excluding index: Int?) -> Bool {
        let candidate = rigName.trimmingCharacters(in: .whitespaces).lowercased()
        for (i, inst) in config.instances.enumerated() where i != index {
            if inst.rigName.trimmingCharacters(in: .whitespaces).lowercased() == candidate {
                return true
            }
        }
        return false
    }

    private func promptForInstance(title: String, name: String, rigName: String) -> InstanceConfig? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The rig name is passed to WSJT-X as --rig-name and must be "
            + "unique. Leave it blank to launch WSJT-X with its default configuration."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 92))
        func label(_ text: String, y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = NSRect(x: 0, y: y, width: 320, height: 15)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        let nameField = NSTextField(frame: NSRect(x: 0, y: 48, width: 320, height: 22))
        nameField.stringValue = name
        nameField.placeholderString = "Rig 3"
        let rigField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        rigField.stringValue = rigName
        rigField.placeholderString = "blank = WSJT-X default configuration"

        container.addSubview(label("Display name", y: 72))
        container.addSubview(nameField)
        container.addSubview(label("Rig name (--rig-name)", y: 24))
        container.addSubview(rigField)
        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let finalRig = rigField.stringValue.trimmingCharacters(in: .whitespaces)
        let finalName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        return InstanceConfig(
            name: finalName.isEmpty ? (finalRig.isEmpty ? "Default" : finalRig) : finalName,
            rigName: finalRig)
    }

    @objc func addRig() {
        guard config.instances.count < AppDelegate.maxInstances else { return }
        guard let new = promptForInstance(title: "Add Rig", name: "", rigName: "") else { return }
        guard !rigNameTaken(new.rigName, excluding: nil) else {
            warn("A rig named \(new.rigName.isEmpty ? "(default)" : new.rigName) already exists.")
            return
        }
        var updated = config
        updated.instances.append(new)
        persist(updated)
    }

    private func editRig(at idx: Int) {
        guard idx < config.instances.count else { return }
        let current = config.instances[idx]
        guard let edited = promptForInstance(title: "Configure Rig",
                                             name: current.name,
                                             rigName: current.rigName) else { return }
        guard !rigNameTaken(edited.rigName, excluding: idx) else {
            warn("A rig named \(edited.rigName.isEmpty ? "(default)" : edited.rigName) already exists.")
            return
        }
        if instances.indices.contains(idx), instances[idx].isRunning {
            warn("Stop \(current.name) before renaming it — the rig name is fixed for the life of the process.")
            return
        }
        var updated = config
        updated.instances[idx] = edited
        persist(updated)
    }

    private func removeRig(at idx: Int) {
        guard idx < config.instances.count else { return }
        if instances.indices.contains(idx), instances[idx].isRunning {
            instances[idx].stop()
        }
        var updated = config
        updated.instances.remove(at: idx)
        persist(updated)
    }

    private func warn(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "AB6A TimeShift"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        rows.removeAll()

        let header = NSMenuItem(title: "AB6A TimeShift", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if instances.isEmpty {
            menu.addItem(NSMenuItem(title: "No instances configured", action: nil, keyEquivalent: ""))
        }

        for (idx, inst) in instances.enumerated() {
            let row = InstanceRow(
                instance: inst,
                range: config.rangeSeconds,
                step: config.stepSeconds,
                onChange: { [weak self] in self?.refresh() },
                onAction: { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .toggle:    self.toggleInstance(at: idx)
                    case .configure: self.editRig(at: idx)
                    case .remove:    self.removeRig(at: idx)
                    }
                    self.statusItem.menu?.cancelTracking()
                })
            rows.append(row)
            let item = NSMenuItem()
            item.view = row
            menu.addItem(item)
            menu.addItem(.separator())
        }

        let add = NSMenuItem(title: config.instances.count >= AppDelegate.maxInstances
                                ? "Add Rig (maximum \(AppDelegate.maxInstances) reached)"
                                : "Add Rig…",
                             action: #selector(addRig), keyEquivalent: "")
        add.target = self
        add.isEnabled = config.instances.count < AppDelegate.maxInstances
        menu.addItem(add)
        menu.addItem(.separator())
        addItem(menu, "Start All", #selector(startAll))
        addItem(menu, "Stop All", #selector(stopAll))
        menu.addItem(.separator())
        let panelItem = NSMenuItem(
            title: (controlPanel?.isVisible ?? false) ? "Hide Control Panel" : "Show Control Panel",
            action: #selector(toggleControlPanel), keyEquivalent: "")
        panelItem.target = self
        menu.addItem(panelItem)
        menu.addItem(.separator())

        let mic = NSMenuItem(title: microphoneStatusText,
                             action: #selector(openMicrophoneSettings), keyEquivalent: "")
        mic.target = self
        menu.addItem(mic)
        addItem(menu, "Check WSJT-X Copy…", #selector(checkCopy))
        addItem(menu, "Edit Configuration…", #selector(editConfig))
        addItem(menu, "Reload Configuration", #selector(reloadConfig))
        menu.addItem(.separator())
        addItem(menu, "About AB6A TimeShift\u{2026}", #selector(showAbout))
        addItem(menu, "Quit AB6A TimeShift", #selector(quit))
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func toggleInstance(at index: Int) {
        guard index < instances.count else { return }
        let inst = instances[index]
        if inst.isRunning {
            inst.stop()
        } else {
            do { try inst.start(appConfig: config) } catch { present(error) }
        }
        refresh()
    }

    @objc func startAll() {
        for i in instances where !i.isRunning {
            do { try i.start(appConfig: config) } catch { present(error); return }
        }
        refresh()
    }

    @objc func stopAll() {
        for i in instances where i.isRunning { i.stop() }
        refresh()
    }

    @objc private func checkCopy() {
        let checker = URL(fileURLWithPath: config.dylib)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bin/timeshift-check")
        let p = Process()
        p.executableURL = checker
        p.arguments = [config.wsjtxApp]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let alert = NSAlert()
            alert.messageText = "WSJT-X copy"
            alert.informativeText = String(data: data, encoding: .utf8) ?? "(no output)"
            alert.runModal()
        } catch {
            present(error)
        }
    }

    @objc private func editConfig() {
        _ = Support.loadConfig()
        NSWorkspace.shared.open(Support.configURL)
    }

    @objc private func reloadConfig() {
        reload()
        refresh()
    }

    @objc private func showAbout() {
        // the standard panel, with slightly larger text than its default
        let body = NSFont.systemFont(ofSize: 12)
        let heading = NSFont.boldSystemFont(ofSize: 12)
        let accent = NSColor(calibratedRed: 0.94, green: 0.55, blue: 0.13, alpha: 1)
        let credits = NSMutableAttributedString()

        credits.append(NSAttributedString(
            string: "Runs several WSJT-X instances at once, each on its own clock. "
                  + "Offsets are adjustable to the nanosecond while the instance is "
                  + "running, and the rest of the Mac keeps exact time.\n\n",
            attributes: [.font: body]))

        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "?"
        credits.append(NSAttributedString(string: "Versions  ", attributes: [.font: heading]))
        credits.append(NSAttributedString(
            string: "AB6A TimeShift \(appVersion)   \u{00B7}   \(wsjtxVersionSummary)\n",
            attributes: [.font: body]))

        credits.append(NSAttributedString(string: "Help  ", attributes: [.font: heading]))
        credits.append(NSAttributedString(
            string: "AB6A.US@gmail.com\n",
            attributes: [.font: body,
                         .link: URL(string: "mailto:AB6A.US@gmail.com")!,
                         .foregroundColor: accent]))

        credits.append(NSAttributedString(string: "Source  ", attributes: [.font: heading]))
        credits.append(NSAttributedString(
            string: "github.com/djsincla/ab6a-timeShift\n\n",
            attributes: [.font: body,
                         .link: URL(string: "https://github.com/djsincla/ab6a-timeShift")!,
                         .foregroundColor: accent]))

        credits.append(NSAttributedString(
            string: "GPL-2.0-or-later. WSJT-X is separate software under its own "
                  + "licence; this app links none of its code and never modifies your "
                  + "installed copy - timeshift-resign duplicates it alongside.",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "ApplicationName"): "AB6A TimeShift",
        ])
    }

    /// Reads the version out of the WSJT-X copy the rigs are launched from.
    private var wsjtxVersionSummary: String {
        let plist = URL(fileURLWithPath: config.wsjtxApp)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String
        else { return "WSJT-X copy not found" }
        return "WSJT-X \(version)"
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "AB6A TimeShift"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// NSApplication.delegate is a weak reference, so the delegate is held here.
private let sharedDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.delegate = sharedDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
