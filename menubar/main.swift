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

    static let `default` = AppConfig(
        wsjtxApp: "/Applications/wsjtx shift.app",
        dylib: NSHomeDirectory() + "/Developer/timeShift/lib/libtimeshift.dylib",
        rangeSeconds: 5.0,
        stepSeconds: 0.1,
        instances: [
            InstanceConfig(name: "Rig 1", rigName: "rig1"),
            InstanceConfig(name: "Rig 2", rigName: "rig2"),
        ])
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

    var isRunning: Bool { process?.isRunning ?? false }

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
            throw NSError(domain: "ab6a-timeShift", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "No WSJT-X executable at \(exe.path).\n\nMake an injectable copy first:\n"
                    + "  bin/timeshift-resign /Applications/wsjtx.app \"\(appConfig.wsjtxApp)\""
            ])
        }
        guard FileManager.default.fileExists(atPath: appConfig.dylib) else {
            throw NSError(domain: "ab6a-timeShift", code: 2, userInfo: [
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
        p.terminationHandler = { _ in
            DispatchQueue.main.async { NSApp.sendAction(#selector(AppDelegate.refresh), to: nil, from: nil) }
        }
        try p.run()
        process = p
    }

    func stop() {
        process?.terminate()
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

    enum Action { case toggle, configure, remove }

    init(instance: Instance, range: Double, step: Double,
         onChange: @escaping () -> Void, onAction: @escaping (Action) -> Void) {
        self.instance = instance
        self.step = step
        self.onChange = onChange
        self.onAction = onAction
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 96))

        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right

        slider.minValue = -range
        slider.maxValue = range
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.numberOfTickMarks = Int(range * 2 / step) + 1
        slider.allowsTickMarkValuesOnly = true

        let stepsStack = NSStackView(views: [
            button("−1s", -1.0), button("−\(fmt(step))", -step),
            button("0", nil),
            button("+\(fmt(step))", step), button("+1s", 1.0),
        ])
        stepsStack.orientation = .horizontal
        stepsStack.spacing = 4
        stepsStack.distribution = .fillEqually

        let header = NSStackView(views: [nameLabel, NSView(), valueLabel])
        header.orientation = .horizontal

        // Start / Config / Remove, one line.
        startButton.title = "Start"
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small
        startButton.font = .systemFont(ofSize: 11)
        startButton.target = self
        startButton.action = #selector(startTapped)

        let actionsStack = NSStackView(views: [
            startButton,
            actionButton("Config", #selector(configTapped)),
            actionButton("Remove", #selector(removeTapped)),
        ])
        actionsStack.orientation = .horizontal
        actionsStack.spacing = 4
        actionsStack.distribution = .fillEqually

        let stack = NSStackView(views: [header, slider, stepsStack, actionsStack])
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

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(format: "%.0fs", v) : String(format: "%.1fs", v)
    }

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

    private func button(_ title: String, _ delta: Double?) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(stepTapped(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.tag = delta == nil ? 9999 : Int((delta! * 1000).rounded())
        return b
    }

    @objc private func stepTapped(_ sender: NSButton) {
        if sender.tag == 9999 {
            instance.control.offsetNanos = 0
        } else {
            let deltaNs = Int64(sender.tag) * 1_000_000
            instance.control.offsetNanos += deltaNs
        }
        sync()
        onChange()
    }

    @objc private func sliderMoved() {
        instance.control.offsetSeconds = slider.doubleValue
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
        let secs = instance.control.offsetSeconds
        valueLabel.stringValue = String(format: "%+.3f s", secs)
        valueLabel.textColor = secs == 0 ? .secondaryLabelColor : .controlAccentColor
        slider.doubleValue = secs
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
    static let maxInstances = 6

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "clock.arrow.2.circlepath",
                                   accessibilityDescription: "ab6a-timeShift")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        reload()
        requestMicrophoneAccess()
        updateStatusIcon()

        // Instances can exit on their own; poll so the icon stays truthful even
        // when the menu is closed and no row is around to refresh itself.
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            DispatchQueue.main.async { self.updateStatusIcon() }
        }
    }

    /// Green whenever at least one instance is up, default tint otherwise.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let running = instances.filter { $0.isRunning }.count
        button.contentTintColor = running > 0 ? .systemGreen : nil
        button.toolTip = running > 0
            ? "ab6a-timeShift — \(running) instance\(running == 1 ? "" : "s") running"
            : "ab6a-timeShift — stopped"
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
        updateStatusIcon()
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

    @objc private func addRig() {
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
        alert.messageText = "ab6a-timeShift"
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        rows.removeAll()

        let header = NSMenuItem(title: "ab6a-timeShift", action: nil, keyEquivalent: "")
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
        let mic = NSMenuItem(title: microphoneStatusText,
                             action: #selector(openMicrophoneSettings), keyEquivalent: "")
        mic.target = self
        menu.addItem(mic)
        addItem(menu, "Check WSJT-X Copy…", #selector(checkCopy))
        addItem(menu, "Edit Configuration…", #selector(editConfig))
        addItem(menu, "Reload Configuration", #selector(reloadConfig))
        menu.addItem(.separator())
        addItem(menu, "Quit", #selector(quit))
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

    @objc private func startAll() {
        for i in instances where !i.isRunning {
            do { try i.start(appConfig: config) } catch { present(error); return }
        }
        refresh()
    }

    @objc private func stopAll() {
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "ab6a-timeShift"
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
