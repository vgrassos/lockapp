import AppKit
import SwiftUI
import ServiceManagement
import CryptoKit

// MARK: - Ρυθμίσεις

// MARK: - Κωδικός (ορίζεται από τον χρήστη την πρώτη φορά· αποθηκεύεται μόνο το hash)

enum Password {
    static let d = UserDefaults.standard

    static var isSet: Bool { d.string(forKey: "passwordHash") != nil }

    static func hash(_ p: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + p).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func set(_ p: String) {
        let salt = UUID().uuidString
        d.set(salt, forKey: "passwordSalt")
        d.set(hash(p, salt: salt), forKey: "passwordHash")
    }

    static func check(_ p: String?) -> Bool {
        guard let p, let h = d.string(forKey: "passwordHash"), let salt = d.string(forKey: "passwordSalt") else { return false }
        return hash(p, salt: salt) == h
    }
}

enum Mode: String { case lock, rest }

final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var mode: Mode
    @Published var workHours: Double
    @Published var breakHours: Double
    @Published var pin: String

    init() {
        mode = Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .lock
        workHours = d.object(forKey: "workHours") as? Double ?? 2.5
        breakHours = d.object(forKey: "breakHours") as? Double ?? 1.5
        pin = d.string(forKey: "pin") ?? ""
    }

    func save() {
        d.set(mode.rawValue, forKey: "mode")
        d.set(workHours, forKey: "workHours")
        d.set(breakHours, forKey: "breakHours")
        d.set(pin, forKey: "pin")
    }
}

// MARK: - Κλείδωμα οθόνης (login screen)

func lockScreen() {
    if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
       let sym = dlsym(h, "SACLockScreenImmediate") {
        typealias Fn = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: Fn.self)()
    } else {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}

// MARK: - Βγάζει τις άλλες εφαρμογές από πλήρη οθόνη και τις κρύβει (παιχνίδια, video κ.λπ.)

func hideOtherApps() {
    let me = ProcessInfo.processInfo.processIdentifier
    for app in NSWorkspace.shared.runningApplications
    where app.activationPolicy == .regular && app.processIdentifier != me && !app.isHidden {
        // Έξοδος από full screen μέσω Accessibility (αν έχει δοθεί άδεια).
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                for w in windows {
                    var fs: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, "AXFullScreen" as CFString, &fs) == .success, fs as? Bool == true {
                        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanFalse)
                    }
                }
            }
        }
        app.hide()
    }
}

// MARK: - Παύση media και σίγαση ήχου

// Στέλνει "Pause" (όχι toggle) στην εφαρμογή που παίζει media (Music, Spotify, browsers...).
func pauseMedia() {
    guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
          let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return }
    typealias Fn = @convention(c) (Int32, CFDictionary?) -> Bool
    _ = unsafeBitCast(sym, to: Fn.self)(1, nil)   // 1 = kMRPause
}

func runAppleScript(_ src: String) -> String? {
    var err: NSDictionary?
    return NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue
}

func isMuted() -> Bool { runAppleScript("output muted of (get volume settings)") == "true" }

// Σίγαση· θυμάται αν τη σίγαση την έκανε η εφαρμογή, για να την αναιρέσει μετά.
func muteAudio() {
    if !isMuted() {
        _ = runAppleScript("set volume with output muted")
        UserDefaults.standard.set(true, forKey: "mutedByApp")
    }
}

func restoreAudio() {
    guard UserDefaults.standard.bool(forKey: "mutedByApp") else { return }
    _ = runAppleScript("set volume without output muted")
    UserDefaults.standard.set(false, forKey: "mutedByApp")
}

func silence() {
    pauseMedia()
    muteAudio()
}

func requestAccessibility() {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
}

func fmt(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, working, waitingUnlock, onBreak }

    let settings = Settings()
    var state = State.idle
    var deadline = Date()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var overlays: [NSWindow] = []
    var ticker: Timer?
    var pausedAt: Date?            // πότε έκλεισε/κλείδωσε το Mac κατά την εργασία
    var pausedRemaining: TimeInterval = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏱"
        let menu = NSMenu()
        menu.addItem(withTitle: "Σχετικά με το LockApp", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ρυθμίσεις…", action: #selector(openSettingsProtected), keyEquivalent: "")
        menu.addItem(withTitle: "Μηδενισμός μετρητή…", action: #selector(resetProtected), keyEquivalent: "")
        menu.addItem(withTitle: "Αλλαγή κωδικού…", action: #selector(changePassword), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Έξοδος", action: #selector(quitProtected), keyEquivalent: "")
        statusItem.menu = menu

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked), name: .init("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(self, selector: #selector(screenLocked), name: NSWorkspace.willSleepNotification, object: nil)
        wnc.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        if !Password.isSet || !restoreSession() { showSettings(needsPassword: true) }
    }

    // MARK: Αποθήκευση μετρητή (για logout/login, επανεκκίνηση, έξοδο)

    let d = UserDefaults.standard

    func saveSession() {
        guard settings.mode == .rest else { d.removeObject(forKey: "session.state"); return }
        switch state {
        case .working:
            d.set("working", forKey: "session.state")
            d.set(pausedAt == nil ? deadline.timeIntervalSinceNow : pausedRemaining, forKey: "session.remaining")
            d.set(pausedAt ?? Date(), forKey: "session.at")
        case .onBreak:
            d.set("onBreak", forKey: "session.state")
            d.set(deadline, forKey: "session.breakEnd")
        default:
            d.removeObject(forKey: "session.state")
        }
    }

    // Σε mode Διάλειμμα συνεχίζει από εκεί που είχε μείνει, χωρίς να ζητάει κωδικό.
    func restoreSession() -> Bool {
        guard settings.mode == .rest else { return false }
        switch d.string(forKey: "session.state") {
        case "working":
            guard let at = d.object(forKey: "session.at") as? Date else { return false }
            pausedAt = at
            pausedRemaining = d.double(forKey: "session.remaining")
            state = .working
            screenUnlocked()   // ίδιος κανόνας με το ξεκλείδωμα (απουσία ≥ διάλειμμα → νέα περίοδος)
        case "onBreak":
            guard let end = d.object(forKey: "session.breakEnd") as? Date else { return false }
            if end > Date() { startBreak(until: end) } else { startWork() }
        default:
            return false
        }
        return true
    }

    // Όσο το Mac είναι κλειδωμένο ή σε ύπνο, ο χρόνος εργασίας παγώνει.
    @objc func screenLocked() {
        guard state == .working, pausedAt == nil else { return }
        pausedAt = Date()
        pausedRemaining = deadline.timeIntervalSinceNow
    }

    @objc func screenUnlocked() {
        if state == .waitingUnlock { restoreAudio(); startWork(); return }   // μετά από αναγκαστικό κλείδωμα: νέα περίοδος
        guard state == .working, let at = pausedAt else { return }
        pausedAt = nil
        // Αν έλειψες τουλάχιστον όσο ένα διάλειμμα, μετράει ως διάλειμμα: νέα περίοδος.
        if settings.mode == .rest && Date().timeIntervalSince(at) >= settings.breakHours * 3600 {
            startWork()
        } else {
            deadline = Date().addingTimeInterval(pausedRemaining)
            tick()
        }
    }

    // Ξύπνημα χωρίς κωδικό (δεν θα έρθει ειδοποίηση ξεκλειδώματος).
    @objc func didWake() {
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        if !locked { screenUnlocked() }
    }

    func startWork() {
        state = .working
        pausedAt = nil
        deadline = Date().addingTimeInterval(settings.workHours * 3600)
        tick()
    }

    func tick() {
        let remaining = deadline.timeIntervalSinceNow
        switch state {
        case .idle:
            statusItem.button?.title = "⏱ —"
        case .waitingUnlock:
            statusItem.button?.title = "⏱ 🔒"
        case .working where pausedAt != nil:
            statusItem.button?.title = "⏱ ⏸ " + fmt(pausedRemaining)
        case .working:
            statusItem.button?.title = "⏱ " + fmt(remaining)
            if remaining <= 0 { workFinished() }
        case .onBreak:
            statusItem.button?.title = "☕ " + fmt(remaining)
            if remaining <= 0 { endBreak() } else { keepOverlayOnTop() }
        }
        saveSession()
    }

    func workFinished() {
        switch settings.mode {
        case .lock:
            state = .waitingUnlock
            hideOtherApps()
            silence()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { lockScreen() }
        case .rest:
            startBreak(until: Date().addingTimeInterval(settings.breakHours * 3600))
        }
    }

    // MARK: Διάλειμμα (πλήρης οθόνη)

    func startBreak(until end: Date) {
        state = .onBreak
        deadline = end
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching,
                                     .disableForceQuit, .disableSessionTermination, .disableHideApplication]
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: max(NSWindow.Level.screenSaver.rawValue, Int(CGShieldingWindowLevel())))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            let isMain = screen == NSScreen.main
            w.contentView = NSHostingView(rootView: BreakView(app: self, showPin: isMain))
            w.setFrame(screen.frame, display: true)
            w.makeKeyAndOrderFront(nil)
            overlays.append(w)
        }
        hideOtherApps()
        silence()
        tick()
    }

    func keepOverlayOnTop() {
        hideOtherApps()
        muteAudio()   // αν ξαναενεργοποιηθεί ο ήχος από το πληκτρολόγιο
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        overlays.forEach { $0.orderFrontRegardless() }
    }

    func endBreak() {
        overlays.forEach { $0.close() }
        overlays.removeAll()
        NSApp.presentationOptions = []
        NSApp.setActivationPolicy(.accessory)
        restoreAudio()
        startWork()
    }

    func tryPin(_ pin: String) -> Bool {
        guard !settings.pin.isEmpty, pin == settings.pin else { return false }
        endBreak()
        return true
    }

    // MARK: Ρυθμίσεις / έξοδος με κωδικό

    func askPassword() -> Bool { Password.check(promptSecret("Κωδικός")) }

    func promptSecret(_ title: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Άκυρο")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // Μηδενισμός μόνο με τον κωδικό ή το PIN.
    @objc func resetProtected() {
        guard state != .onBreak, let s = promptSecret("Κωδικός ή PIN") else { return }
        if Password.check(s) || (!settings.pin.isEmpty && s == settings.pin) { startWork() }
    }

    @objc func openSettingsProtected() {
        if state == .onBreak { return }
        if askPassword() { showSettings(needsPassword: false) }
    }

    @objc func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let credits = NSMutableAttributedString(string: "Δημιουργός: Vagelis Grassos\nWebsite: ",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11)])
        credits.append(NSAttributedString(string: "https://www.octo.gr", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://www.octo.gr")!]))
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        credits.addAttribute(.paragraphStyle, value: center, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "LockApp",
            .applicationVersion: "Έκδοση \(version)",
            .version: "",
            .credits: credits,
        ])
    }

    @objc func changePassword() {
        guard state != .onBreak, askPassword(),
              let p1 = promptSecret("Νέος κωδικός"), !p1.isEmpty,
              let p2 = promptSecret("Επανάληψη νέου κωδικού") else { return }
        let alert = NSAlert()
        if p1 == p2 { Password.set(p1); alert.messageText = "Ο κωδικός άλλαξε." }
        else { alert.messageText = "Οι κωδικοί δεν ταιριάζουν. Δεν έγινε αλλαγή." }
        alert.runModal()
    }

    @objc func quitProtected() {
        if askPassword() { NSApp.terminate(nil) }
    }

    func showSettings(needsPassword: Bool) {
        settingsWindow?.close()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "LockApp"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(app: self, settings: settings, unlocked: !needsPassword))
        w.center()
        settingsWindow = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func applySettings() {
        requestAccessibility()
        settings.save()
        settingsWindow?.close()
        startWork()
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Views

struct SettingsView: View {
    let app: AppDelegate
    @ObservedObject var settings: Settings
    @State var unlocked: Bool
    @State private var password = ""
    @State private var confirm = ""
    @State private var error = false
    @State private var hasPassword = Password.isSet
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Group {
            if !hasPassword { passwordSetup } else if unlocked { form } else { passwordPrompt }
        }
        .padding(20)
        .frame(width: 380)
    }

    var passwordPrompt: some View {
        VStack(spacing: 12) {
            Text("Κωδικός").font(.headline)
            SecureField("Κωδικός", text: $password, onCommit: check)
            if error { Text("Λάθος κωδικός").foregroundColor(.red) }
            Button("Συνέχεια", action: check).keyboardShortcut(.defaultAction)
        }
    }

    func check() {
        if Password.check(password) { unlocked = true } else { error = true; password = "" }
    }

    // Πρώτη εκτέλεση: ο χρήστης ορίζει τον δικό του κωδικό.
    var passwordSetup: some View {
        VStack(spacing: 12) {
            Text("Ορισμός κωδικού").font(.headline)
            Text("Θα χρειάζεται για ρυθμίσεις, μηδενισμό και έξοδο.").font(.caption)
            SecureField("Νέος κωδικός", text: $password)
            SecureField("Επανάληψη κωδικού", text: $confirm, onCommit: setup)
            if error { Text("Οι κωδικοί δεν ταιριάζουν ή είναι κενοί").foregroundColor(.red) }
            Button("Αποθήκευση", action: setup).keyboardShortcut(.defaultAction)
        }
    }

    func setup() {
        guard !password.isEmpty, password == confirm else { error = true; confirm = ""; return }
        Password.set(password)
        error = false; password = ""; confirm = ""
        hasPassword = true
        unlocked = true
    }

    var form: some View {
        Form {
            Picker("Λειτουργία", selection: $settings.mode) {
                Text("Κλείδωμα").tag(Mode.lock)
                Text("Διάλειμμα").tag(Mode.rest)
            }
            .pickerStyle(.segmented)

            Stepper("Εργασία: \(settings.workHours, specifier: "%.2f") ώρες",
                    value: $settings.workHours, in: 0.25...12, step: 0.25)

            if settings.mode == .rest {
                Stepper("Διάλειμμα: \(settings.breakHours, specifier: "%.2f") ώρες",
                        value: $settings.breakHours, in: 0.25...12, step: 0.25)
                SecureField("PIN παράκαμψης", text: $settings.pin)
            }

            Toggle("Εκκίνηση με το άνοιγμα του Mac", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        NSLog("Login item error: \(error)")
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                Spacer()
                Button("Έναρξη") { app.applySettings() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

struct BreakView: View {
    let app: AppDelegate
    let showPin: Bool
    @State private var now = Date()
    @State private var pin = ""
    @State private var wrong = false
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 24) {
            Text("Διάλειμμα").font(.system(size: 48, weight: .semibold))
            Text(fmt(app.deadline.timeIntervalSince(now)))
                .font(.system(size: 96, weight: .light, design: .monospaced))
            if showPin {
                SecureField("PIN", text: $pin, onCommit: submit)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                if wrong { Text("Λάθος PIN").foregroundColor(.red) }
            }
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onReceive(timer) { now = $0 }
    }

    func submit() {
        wrong = !app.tryPin(pin)
        pin = ""
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
