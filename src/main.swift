// main.swift: menu bar app entry point (top-level code must live in main.swift when building with Pro/ProStub).
// AkiGuard — menu bar app. Writes the config file; the root daemon (akiguard) applies it.
import Cocoa

let confDir = "/Library/Application Support/AkiGuard"
let confPath = confDir + "/akiguard.conf"
let statusPath = confDir + "/status"
let logPath = "/Library/Logs/AkiGuard.log"
let dayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

// MARK: - Config (key=value, comment lines preserved)

final class Config {
    private(set) var lines: [String] = []

    init() { load() }

    func load() {
        let text = (try? String(contentsOfFile: confPath, encoding: .utf8)) ?? ""
        lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
    }

    private func keyOf(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
        return t[..<eq].trimmingCharacters(in: .whitespaces)
    }

    private func valueOf(_ line: String) -> String {
        guard let eq = line.firstIndex(of: "=") else { return "" }
        return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    }

    func get(_ key: String) -> String? {
        lines.first(where: { keyOf($0) == key }).map(valueOf)
    }

    func int(_ key: String, _ def: Int) -> Int { Int(get(key) ?? "") ?? def }

    func set(_ key: String, _ value: String) {
        if let i = lines.firstIndex(where: { keyOf($0) == key }) {
            lines[i] = "\(key)=\(value)"
        } else if let i = lines.firstIndex(where: { keyOf($0) == "schedule" }) {
            lines.insert("\(key)=\(value)", at: i)
        } else {
            lines.append("\(key)=\(value)")
        }
    }

    var schedules: [String] { lines.filter { keyOf($0) == "schedule" }.map(valueOf) }

    func addSchedule(_ s: String) { lines.append("schedule=\(s)") }

    func removeSchedule(at index: Int) {
        var n = -1
        if let i = lines.firstIndex(where: { line in
            if keyOf(line) == "schedule" { n += 1; return n == index }
            return false
        }) { lines.remove(at: i) }
    }

    func save() throws {
        try (lines.joined(separator: "\n") + "\n").write(toFile: confPath, atomically: true, encoding: .utf8)
    }
}

func readStatus() -> [String: String] {
    guard let text = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return [:] }
    var d: [String: String] = [:]
    for line in text.components(separatedBy: "\n") {
        guard let eq = line.firstIndex(of: "=") else { continue }
        d[String(line[..<eq])] = String(line[line.index(after: eq)...])
    }
    return d
}

func modeLabel(_ mode: String, _ value: Int?) -> String {
    switch mode {
    case "limit": return "Hold at \(value ?? 80)%"
    case "discharge": return "Discharge to \(value ?? 50)%"
    case "full": return "Charge to 100%"
    default: return "Normal charging"
    }
}

func scheduleLabel(_ s: String) -> String {
    let p = s.split(separator: " ").map(String.init)
    guard p.count >= 3 else { return s }
    let days: String
    if p[1] == "*" || p[1] == "1234567" { days = "Every day" }
    else if p[1] == "12345" { days = "Mon–Fri" }
    else if p[1] == "67" { days = "Sat–Sun" }
    else { days = p[1].compactMap { Int(String($0)) }.filter { (1...7).contains($0) }.map { dayNames[$0 - 1] }.joined(separator: ",") }
    let value = p.count >= 4 ? Int(p[3]) : nil
    return "\(p[0].replacingOccurrences(of: "-", with: "–")) · \(days) · \(modeLabel(p[2], value))"
}

// MARK: - Menu item with closure

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) not used") }
    @objc private func fire() { handler() }
}

func infoItem(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let config = Config()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshTitle() }
        Pro.startBackgroundCheck()
    }

    private func refreshTitle() {
        let s = readStatus()
        let pct = s["pct"].flatMap(Int.init) ?? -1
        let stale = (Double(s["updated"] ?? "") ?? 0) < Date().timeIntervalSince1970 - 90
        var icon = "battery.100"
        if pct >= 0 { icon = pct > 87 ? "battery.100" : pct > 62 ? "battery.75" : pct > 37 ? "battery.50" : pct > 12 ? "battery.25" : "battery.0" }
        var badge = ""
        if stale { badge = "⚠︎" }
        else if s["adapter_disabled"] == "1" { badge = "↓" }
        else if s["charging"] == "1" { badge = "⚡︎" }
        else if s["charge_inhibited"] == "1" { badge = "⏸" }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: "AkiGuard")
            button.imagePosition = .imageLeading
            button.title = pct >= 0 ? " \(pct)%\(badge)" : " AkiGuard"
        }
    }

    // Menu is rebuilt every time it opens so it always reflects the latest status
    func menuNeedsUpdate(_ menu: NSMenu) {
        config.load()
        let s = readStatus()
        menu.removeAllItems()

        let stale = (Double(s["updated"] ?? "") ?? 0) < Date().timeIntervalSince1970 - 90
        if stale {
            menu.addItem(infoItem("⚠︎ Background service not running — reinstall AkiGuard"))
        } else {
            let pct = s["pct"] ?? "?"
            var state = s["charging"] == "1" ? "charging" : (s["ac"] == "1" ? "plugged in" : "on battery")
            if s["adapter_disabled"] == "1" { state = "discharging (adapter off)" }
            else if s["charge_inhibited"] == "1" { state = "charging paused" }
            menu.addItem(infoItem("Battery \(pct)% · \(state)"))
            let src = (s["source"] ?? "").replacingOccurrences(of: "utama", with: "main").replacingOccurrences(of: "jadwal", with: "schedule")
            menu.addItem(infoItem("Active rule: \(modeLabel(s["mode"] ?? "", Int(s["value"] ?? ""))) (\(src))"))
            if let note = s["note"], !note.isEmpty { menu.addItem(infoItem("Note: \(note)")) }
        }
        menu.addItem(.separator())

        let mode = config.get("mode") ?? "limit"
        let limit = config.int("limit", 80)
        let dischargeTo = config.int("discharge_to", 50)

        // Charge limit
        let limitItem = NSMenuItem(title: "Charge limit", action: nil, keyEquivalent: "")
        let limitMenu = NSMenu()
        for v in [50, 60, 70, 75, 80, 85, 90, 95, 100] {
            limitMenu.addItem(ActionItem("\(v)%", checked: mode == "limit" && limit == v) { [weak self] in
                self?.update { $0.set("mode", "limit"); $0.set("limit", "\(v)") }
            })
        }
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)

        // Discharge: only shown if this Mac supports it (or support is unknown yet)
        let canDischarge = s["can_discharge"] != "0"
        if canDischarge {
            let disItem = NSMenuItem(title: "Discharge to", action: nil, keyEquivalent: "")
            let disMenu = NSMenu()
            for v in [30, 40, 50, 60, 70, 80] {
                disMenu.addItem(ActionItem("\(v)%, then hold", checked: mode == "discharge" && dischargeTo == v) { [weak self] in
                    self?.update { $0.set("mode", "discharge"); $0.set("discharge_to", "\(v)") }
                })
            }
            disItem.submenu = disMenu
            menu.addItem(disItem)

            let autoDis = config.int("auto_discharge", 0) == 1
            menu.addItem(ActionItem("Auto-discharge when above limit", checked: autoDis) { [weak self] in
                self?.update { $0.set("auto_discharge", autoDis ? "0" : "1") }
            })
        }

        let sail = config.int("sail", 5)
        let sailItem = NSMenuItem(title: "Sailing (resume charging after drop)", action: nil, keyEquivalent: "")
        let sailMenu = NSMenu()
        for v in [2, 3, 5, 8, 10] {
            sailMenu.addItem(ActionItem("\(v)% below limit", checked: sail == v) { [weak self] in
                self?.update { $0.set("sail", "\(v)") }
            })
        }
        sailItem.submenu = sailMenu
        menu.addItem(sailItem)

        menu.addItem(ActionItem("Pause — normal charging", checked: mode == "off") { [weak self] in
            self?.update { $0.set("mode", "off") }
        })
        menu.addItem(.separator())

        // Temporary top up
        let until = Double(config.get("override_until") ?? "") ?? 0
        let now = Date().timeIntervalSince1970
        if config.get("override") == "full" && until > now {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            menu.addItem(infoItem("Top up to 100% active until \(f.string(from: Date(timeIntervalSince1970: until)))"))
            menu.addItem(ActionItem("Cancel top up") { [weak self] in
                self?.update { $0.set("override", "off"); $0.set("override_until", "0") }
            })
        } else {
            for h in [2, 4, 8] {
                menu.addItem(ActionItem("Top up to 100% for \(h) hours") { [weak self] in
                    let t = Int(Date().timeIntervalSince1970) + h * 3600
                    self?.update { $0.set("override", "full"); $0.set("override_until", "\(t)") }
                })
            }
        }
        menu.addItem(.separator())

        // Schedules
        let schedItem = NSMenuItem(title: "Schedules", action: nil, keyEquivalent: "")
        let schedMenu = NSMenu()
        schedMenu.autoenablesItems = false
        let list = config.schedules
        if list.isEmpty { schedMenu.addItem(infoItem("No schedules yet")) }
        for (i, s) in list.enumerated() {
            schedMenu.addItem(ActionItem("✕  " + scheduleLabel(s)) { [weak self] in self?.confirmDelete(i, s) })
        }
        schedMenu.addItem(.separator())
        schedMenu.addItem(ActionItem("Add schedule…") { [weak self] in self?.addScheduleDialog() })
        schedMenu.addItem(infoItem("Click a schedule to delete it. The top one wins."))
        schedItem.submenu = schedMenu
        menu.addItem(schedItem)

        Pro.addMenuItems(menu, config: config, status: s) { [weak self] change in self?.update(change) }
        menu.addItem(.separator())

        menu.addItem(ActionItem("Edit config file…") {
            self.openWith(["-e", confPath])
        })
        menu.addItem(ActionItem("View log") { self.openWith(["-a", "Console", logPath]) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("About AkiGuard") { self.openWith(["https://wildan17.gumroad.com"]) })
        menu.addItem(ActionItem("Uninstall AkiGuard…") { [weak self] in self?.confirmUninstall() })
        menu.addItem(ActionItem("Quit menu bar (service keeps running)") { NSApp.terminate(nil) })
    }

    private func confirmUninstall() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Uninstall AkiGuard?"
        a.informativeText = "This stops the background service, restores normal charging and removes AkiGuard. You will be asked for your admin password."
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let script = Bundle.main.path(forResource: "uninstall", ofType: "sh") else {
            alert("Uninstall", "Run ./uninstall.sh from the AkiGuard folder you installed from."); return
        }
        let src = "do shell script \"/bin/bash '" + script + "' \" & quoted form of (POSIX path of (path to home folder)) with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if err == nil { NSApp.terminate(nil) }
    }

    private func openWith(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        try? p.run()
    }

    private func update(_ change: (Config) -> Void) {
        config.load()
        change(config)
        do {
            try config.save()
        } catch {
            alert("Could not save settings", "The folder \(confDir) is not writable. Please reinstall AkiGuard.\n\n\(error.localizedDescription)")
        }
        refreshTitle()
    }

    private func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func confirmDelete(_ index: Int, _ s: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Delete this schedule?"
        a.informativeText = scheduleLabel(s)
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            update { $0.removeSchedule(at: index) }
        }
    }

    private func timePicker(hour: Int) -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerElements = .hourMinute
        p.datePickerStyle = .textFieldAndStepper
        p.dateValue = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return p
    }

    private func row(_ label: String, _ views: [NSView]) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let r = NSStackView(views: [l as NSView] + views)
        r.orientation = .horizontal
        r.spacing = 6
        return r
    }

    private func addScheduleDialog() {
        NSApp.activate(ignoringOtherApps: true)
        let start = timePicker(hour: 6)
        let end = timePicker(hour: 8)
        let checks = dayNames.enumerated().map { i, n -> NSButton in
            let b = NSButton(checkboxWithTitle: n, target: nil, action: nil)
            b.state = i < 5 ? .on : .off
            return b
        }
        var choices: [(title: String, mode: String)] = [
            ("Hold at %", "limit"), ("Discharge to %", "discharge"),
            ("Charge to 100%", "full"), ("Normal charging", "off"),
        ]
        if readStatus()["can_discharge"] == "0" { choices.removeAll { $0.mode == "discharge" } }
        let modePop = NSPopUpButton()
        modePop.addItems(withTitles: choices.map { $0.title })
        let value = NSTextField(string: "80")
        value.widthAnchor.constraint(equalToConstant: 50).isActive = true

        let stack = NSStackView(views: [
            row("Start", [start]),
            row("End", [end]),
            row("Days", checks),
            row("Action", [modePop]),
            row("Value %", [value, NSTextField(labelWithString: "(for hold / discharge)")]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 470, height: 170)

        let a = NSAlert()
        a.messageText = "Add schedule"
        a.informativeText = "During this time window the schedule replaces your main rule. Windows can cross midnight (e.g. 22:00–06:00)."
        a.accessoryView = stack
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let cal = Calendar.current
        func hm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let days = checks.enumerated().filter { $0.element.state == .on }.map { "\($0.offset + 1)" }.joined()
        let m = choices[max(0, modePop.indexOfSelectedItem)].mode
        let v = Int(value.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0

        if days.isEmpty { alert("Schedule not saved", "Pick at least one day."); return }
        if hm(start.dateValue) == hm(end.dateValue) { alert("Schedule not saved", "Start and end time can't be the same."); return }
        if (m == "limit" || m == "discharge") && !(20...100).contains(v) {
            alert("Schedule not saved", "Value must be between 20 and 100."); return
        }
        var line = "\(hm(start.dateValue))-\(hm(end.dateValue)) \(days) \(m)"
        if m == "limit" || m == "discharge" { line += " \(v)" }
        update { $0.addSchedule(line) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
