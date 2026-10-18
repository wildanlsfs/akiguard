// AkiGuard — aplikasi menu bar. Menulis konfigurasi; daemon root (akiguard) yang mengeksekusi.
import Cocoa

let confDir = "/Library/Application Support/AkiGuard"
let confPath = confDir + "/akiguard.conf"
let statusPath = confDir + "/status"
let logPath = "/Library/Logs/AkiGuard.log"
let dayNames = ["Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"]

// MARK: - Konfigurasi (format key=value, baris komentar dipertahankan)

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
    case "limit": return "Tahan di \(value ?? 80)%"
    case "discharge": return "Discharge ke \(value ?? 50)%"
    case "full": return "Isi penuh 100%"
    default: return "Charging normal"
    }
}

func scheduleLabel(_ s: String) -> String {
    let p = s.split(separator: " ").map(String.init)
    guard p.count >= 3 else { return s }
    let days: String
    if p[1] == "*" || p[1] == "1234567" { days = "Setiap hari" }
    else if p[1] == "12345" { days = "Sen–Jum" }
    else if p[1] == "67" { days = "Sab–Min" }
    else { days = p[1].compactMap { Int(String($0)) }.filter { (1...7).contains($0) }.map { dayNames[$0 - 1] }.joined(separator: ",") }
    let value = p.count >= 4 ? Int(p[3]) : nil
    return "\(p[0].replacingOccurrences(of: "-", with: "–")) · \(days) · \(modeLabel(p[2], value))"
}

// MARK: - Item menu dengan closure

final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError("init(coder:) tidak dipakai") }
    @objc private func fire() { handler() }
}

func infoItem(_ title: String) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    return i
}

// MARK: - Aplikasi

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

    // Menu dibangun ulang setiap kali dibuka, supaya selalu sesuai status terbaru
    func menuNeedsUpdate(_ menu: NSMenu) {
        config.load()
        let s = readStatus()
        menu.removeAllItems()

        let stale = (Double(s["updated"] ?? "") ?? 0) < Date().timeIntervalSince1970 - 90
        if stale {
            menu.addItem(infoItem("⚠︎ Daemon tidak berjalan — jalankan install.sh lagi"))
        } else {
            let pct = s["pct"] ?? "?"
            var state = s["charging"] == "1" ? "sedang charging" : (s["ac"] == "1" ? "adaptor terhubung" : "pakai baterai")
            if s["adapter_disabled"] == "1" { state = "discharge (adaptor dimatikan)" }
            else if s["charge_inhibited"] == "1" { state = "charging ditahan" }
            menu.addItem(infoItem("Baterai \(pct)% · \(state)"))
            let src = s["source"] ?? ""
            menu.addItem(infoItem("Aturan aktif: \(modeLabel(s["mode"] ?? "", Int(s["value"] ?? ""))) (\(src))"))
            if s["can_discharge"] == "0" { menu.addItem(infoItem("Mac ini tidak mendukung discharge paksa")) }
            if let note = s["note"], !note.isEmpty { menu.addItem(infoItem("Catatan: \(note)")) }
        }
        menu.addItem(.separator())

        let mode = config.get("mode") ?? "limit"
        let limit = config.int("limit", 80)
        let dischargeTo = config.int("discharge_to", 50)

        // Batas charging
        let limitItem = NSMenuItem(title: "Batas charging", action: nil, keyEquivalent: "")
        let limitMenu = NSMenu()
        for v in [50, 60, 70, 75, 80, 85, 90, 95, 100] {
            limitMenu.addItem(ActionItem("\(v)%", checked: mode == "limit" && limit == v) { [weak self] in
                self?.update { $0.set("mode", "limit"); $0.set("limit", "\(v)") }
            })
        }
        limitItem.submenu = limitMenu
        menu.addItem(limitItem)

        // Discharge
        let disItem = NSMenuItem(title: "Discharge sampai", action: nil, keyEquivalent: "")
        let disMenu = NSMenu()
        for v in [30, 40, 50, 60, 70, 80] {
            disMenu.addItem(ActionItem("\(v)% lalu tahan", checked: mode == "discharge" && dischargeTo == v) { [weak self] in
                self?.update { $0.set("mode", "discharge"); $0.set("discharge_to", "\(v)") }
            })
        }
        disItem.submenu = disMenu
        menu.addItem(disItem)

        let autoDis = config.int("auto_discharge", 0) == 1
        menu.addItem(ActionItem("Auto-discharge bila di atas batas", checked: autoDis) { [weak self] in
            self?.update { $0.set("auto_discharge", autoDis ? "0" : "1") }
        })

        let sail = config.int("sail", 5)
        let sailItem = NSMenuItem(title: "Sailing (charge lagi bila turun)", action: nil, keyEquivalent: "")
        let sailMenu = NSMenu()
        for v in [2, 3, 5, 8, 10] {
            sailMenu.addItem(ActionItem("\(v)% di bawah batas", checked: sail == v) { [weak self] in
                self?.update { $0.set("sail", "\(v)") }
            })
        }
        sailItem.submenu = sailMenu
        menu.addItem(sailItem)

        menu.addItem(ActionItem("Pause — charging normal", checked: mode == "off") { [weak self] in
            self?.update { $0.set("mode", "off") }
        })
        menu.addItem(.separator())

        // Top up sementara
        let until = Double(config.get("override_until") ?? "") ?? 0
        let now = Date().timeIntervalSince1970
        if config.get("override") == "full" && until > now {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            menu.addItem(infoItem("Top up 100% aktif sampai \(f.string(from: Date(timeIntervalSince1970: until)))"))
            menu.addItem(ActionItem("Batalkan top up") { [weak self] in
                self?.update { $0.set("override", "off"); $0.set("override_until", "0") }
            })
        } else {
            for h in [2, 4, 8] {
                menu.addItem(ActionItem("Top up ke 100% selama \(h) jam") { [weak self] in
                    let t = Int(Date().timeIntervalSince1970) + h * 3600
                    self?.update { $0.set("override", "full"); $0.set("override_until", "\(t)") }
                })
            }
        }
        menu.addItem(.separator())

        // Jadwal
        let schedItem = NSMenuItem(title: "Jadwal", action: nil, keyEquivalent: "")
        let schedMenu = NSMenu()
        schedMenu.autoenablesItems = false
        let list = config.schedules
        if list.isEmpty { schedMenu.addItem(infoItem("Belum ada jadwal")) }
        for (i, s) in list.enumerated() {
            schedMenu.addItem(ActionItem("✕  " + scheduleLabel(s)) { [weak self] in self?.confirmDelete(i, s) })
        }
        schedMenu.addItem(.separator())
        schedMenu.addItem(ActionItem("Tambah jadwal…") { [weak self] in self?.addScheduleDialog() })
        schedMenu.addItem(infoItem("Klik jadwal untuk menghapus. Jadwal teratas menang."))
        schedItem.submenu = schedMenu
        menu.addItem(schedItem)

        menu.addItem(ActionItem("Edit konfigurasi manual…") {
            self.openWith(["-e", confPath])
        })
        menu.addItem(ActionItem("Lihat log") { self.openWith(["-a", "Console", logPath]) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Tutup menu bar (daemon tetap jalan)") { NSApp.terminate(nil) })
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
            alert("Gagal menyimpan konfigurasi", "Folder \(confDir) tidak bisa ditulis. Jalankan install.sh lagi.\n\n\(error.localizedDescription)")
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
        a.messageText = "Hapus jadwal ini?"
        a.informativeText = scheduleLabel(s)
        a.addButton(withTitle: "Hapus")
        a.addButton(withTitle: "Batal")
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
        let modePop = NSPopUpButton()
        modePop.addItems(withTitles: ["Tahan di batas %", "Discharge sampai %", "Isi penuh 100%", "Charging normal"])
        let value = NSTextField(string: "80")
        value.widthAnchor.constraint(equalToConstant: 50).isActive = true

        let stack = NSStackView(views: [
            row("Mulai", [start]),
            row("Selesai", [end]),
            row("Hari", checks),
            row("Aksi", [modePop]),
            row("Nilai %", [value, NSTextField(labelWithString: "(untuk tahan / discharge)")]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 470, height: 170)

        let a = NSAlert()
        a.messageText = "Tambah jadwal"
        a.informativeText = "Selama rentang waktu ini aturan jadwal menggantikan aturan utama. Rentang boleh melewati tengah malam (mis. 22:00–06:00)."
        a.accessoryView = stack
        a.addButton(withTitle: "Simpan")
        a.addButton(withTitle: "Batal")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let cal = Calendar.current
        func hm(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        let days = checks.enumerated().filter { $0.element.state == .on }.map { "\($0.offset + 1)" }.joined()
        let modes = ["limit", "discharge", "full", "off"]
        let m = modes[max(0, modePop.indexOfSelectedItem)]
        let v = Int(value.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0

        if days.isEmpty { alert("Jadwal tidak disimpan", "Pilih minimal satu hari."); return }
        if hm(start.dateValue) == hm(end.dateValue) { alert("Jadwal tidak disimpan", "Jam mulai dan selesai tidak boleh sama."); return }
        if (m == "limit" || m == "discharge") && !(20...100).contains(v) {
            alert("Jadwal tidak disimpan", "Nilai harus antara 20 dan 100."); return
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
