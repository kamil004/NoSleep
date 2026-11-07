import AppKit
import IOKit
import ServiceManagement

enum PowerManager {
    /// Czy kernel ma ustawioną flagę SleepDisabled (blokada snu przy zamkniętej klapie).
    static func sleepDisabled() -> Bool {
        guard let output = try? run("/usr/bin/pmset -g") else { return false }
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("disabledleep") else { continue }
            let tokens = trimmed.split(whereSeparator: \.isWhitespace)
            return tokens.last == "1"
        }
        return false
    }

    /// Włącza/wyłącza SleepDisabled. Gdy reguła sudoers jest zainstalowana - bez hasła.
    static func setSleepDisabled(_ on: Bool) throws {
        let value = on ? "1" : "0"
        if hasPasswordlessPrivileges() {
            _ = try run("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep \(value)")
        } else {
            _ = try runAppleScript(
                "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"
            )
        }
    }

    /// Czy reguła sudoers pozwala przełączać disablesleep bez podawania hasła.
    /// Sprawdzamy wykonując neszkodliwe sudo -n z tą samą wartością flagi.
    static func hasPasswordlessPrivileges() -> Bool {
        let current = sleepDisabled() ? "1" : "0"
        return (try? run("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep \(current)")) != nil
    }

    /// Jednorazowo instaluje wąską regułę sudoers pozwalającą wyłącznie na
    /// `pmset -a disablesleep 0|1` bez hasła. Wymaga potwierdzenia admina (prompt).
    static func installPasswordlessRule() throws {
        let username = NSUserName()
        guard username.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
            throw NSError(
                domain: "NoSleep.sudoers",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Nieprawidłowa nazwa użytkownika"]
            )
        }
        let rule = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
        let rootScript = """
        printf '%s\\n' '\(rule)' > /etc/sudoers.d/nosleep && chown root:wheel /etc/sudoers.d/nosleep && chmod 0440 /etc/sudoers.d/nosleep && if ! /usr/sbin/visudo -cf /etc/sudoers.d/nosleep 2>/dev/null; then rm -f /etc/sudoers.d/nosleep; exit 1; fi
        """
        _ = try runAppleScript("do shell script \"\(rootScript)\" with administrator privileges")
    }

    /// Czy klapa laptopa jest fizycznie zamknięta (AppleClamshellState).
    static func clamshellClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        guard
            let unmanaged = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        else { return false }
        let prop = unmanaged.takeRetainedValue()
        guard CFGetTypeID(prop) == CFBooleanGetTypeID() else { return false }
        return CFBooleanGetValue(unsafeBitCast(prop, to: CFBoolean.self))
    }

    /// Natychmiast usypia ekran (nie wymaga uprawnień administratora).
    static func displaySleepNow() {
        runProcess("/usr/bin/pmset", ["displaysleepnow"])
    }

    /// Budzi ekran symulując aktywność użytkownika na krótką chwilę.
    static func wakeDisplay() {
        runProcess("/usr/bin/caffeinate", ["-u", "-t", "1"])
    }

    private static func runProcess(_ path: String, _ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        try? process.run()
    }

    private static func runAppleScript(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "NoSleep.osascript",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Anulowano"]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func run(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "NoSleep.command",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Nieznany błąd"]
            )
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

@MainActor
final class NoSleepController {
    enum SleepMode {
        case off
        case systemOnly
        case systemAndDisplay
    }

    private let statusItem: NSStatusItem
    private let statusMenu = NSMenu()

    private let systemSleepItem = NSMenuItem(
        title: "Nie usypiaj systemu",
        action: #selector(toggleSystemSleep),
        keyEquivalent: ""
    )
    private let displaySleepItem = NSMenuItem(
        title: "Nie usypiaj ekranu",
        action: #selector(toggleDisplaySleep),
        keyEquivalent: ""
    )
    private let lidSleepItem = NSMenuItem(
        title: "Nie usypiaj po zamknięciu klapy",
        action: #selector(toggleLidSleep),
        keyEquivalent: ""
    )
    private let autoStartItem = NSMenuItem(
        title: "Uruchamiaj przy logowaniu",
        action: #selector(toggleAutoStart),
        keyEquivalent: ""
    )

    private let headerItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private var systemAssertion: NSObjectProtocol?
    private var displayAssertion: NSObjectProtocol?

    private var lastClamshellClosed = PowerManager.clamshellClosed()
    private var clamshellTimer: Timer?

    private var mode: SleepMode {
        switch (systemSleepItem.state, displaySleepItem.state) {
        case (.on, .on):
            return .systemAndDisplay
        case (.on, .off):
            return .systemOnly
        default:
            return .off
        }
    }

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
        }
        statusItem.sendAction(on: [.leftMouseUp, .rightMouseUp, .rightMouseDown])

        let titleItem = headerItem
        titleItem.isEnabled = false

        systemSleepItem.target = self
        systemSleepItem.state = .off
        systemSleepItem.toolTip = "Zapobiega uśpieniu całego Maca z powodu bezczynności (ekran może gasnąć)."
        displaySleepItem.target = self
        displaySleepItem.state = .off
        displaySleepItem.toolTip = "Zapobiega wyłączaniu się ekranu z powodu bezczynności."
        lidSleepItem.target = self
        lidSleepItem.state = .off
        lidSleepItem.toolTip = "Pozwala pracować z zamkniętą pokrywą (ekran gaśnie po zamknięciu)."
        autoStartItem.target = self
        autoStartItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        autoStartItem.toolTip = "Uruchamia NoSleep automatycznie po zalogowaniu."

        // Wszystkie opcje startują wyłączone. Jeśli kernelowa flaga SleepDisabled
        // została po poprzedniej sesji (np. po terminacji pkill), wyzeruj ją po
        // cichu - ale tylko wtedy, gdy reguła sudoers pozwala bez hasła.
        if PowerManager.sleepDisabled(), PowerManager.hasPasswordlessPrivileges() {
            try? PowerManager.setSleepDisabled(false)
        }

        let quitItem = NSMenuItem(
            title: "Zakończ",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp

        statusMenu.addItem(titleItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(systemSleepItem)
        statusMenu.addItem(displaySleepItem)
        statusMenu.addItem(lidSleepItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(autoStartItem)
        statusMenu.addItem(.separator())
        statusMenu.addItem(quitItem)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(restoreSleepDisabled),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        let timer = Timer(timeInterval: 2.0, target: self, selector: #selector(clamshellTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        clamshellTimer = timer

        refreshAssertions()
        updateIcon()
        updateHeader()
    }

    deinit {
        clamshellTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Assertions

    private func refreshAssertions() {
        if systemSleepItem.state == .on, systemAssertion == nil {
            systemAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "NoSleep: zapobieganie usypianiu systemu"
            )
        } else if systemSleepItem.state == .off, let assertion = systemAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            systemAssertion = nil
        }

        if displaySleepItem.state == .on, displayAssertion == nil {
            displayAssertion = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "NoSleep: zapobieganie usypianiu ekranu"
            )
        } else if displaySleepItem.state == .off, let assertion = displayAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            displayAssertion = nil
        }
    }

    @objc private func toggleSystemSleep() {
        systemSleepItem.state = systemSleepItem.state == .on ? .off : .on
        refreshAssertions()
        updateIcon()
        updateHeader()
    }

    @objc private func toggleDisplaySleep() {
        displaySleepItem.state = displaySleepItem.state == .on ? .off : .on
        refreshAssertions()
        updateIcon()
        updateHeader()
    }

    @objc private func toggleLidSleep() {
        let desired = lidSleepItem.state == .off
        let previousState = lidSleepItem.state

        DispatchQueue.global(qos: .userInitiated).async {
            // Pierwszy raz (w dowolną stronę): zainstaluj regułę sudoers - pojedynczy prompt,
            // kolejne przełączenia idą bez hasła.
            if !PowerManager.hasPasswordlessPrivileges() {
                _ = try? PowerManager.installPasswordlessRule()
            }
            do {
                try PowerManager.setSleepDisabled(desired)
            } catch {
                DispatchQueue.main.async {
                    NSSound.beep()
                    self.lidSleepItem.state = previousState
                    self.updateIcon()
                    self.updateHeader()
                }
                return
            }
            DispatchQueue.main.async {
                self.lidSleepItem.state = desired ? .on : .off
                if desired, PowerManager.clamshellClosed() {
                    PowerManager.displaySleepNow()
                }
                self.updateIcon()
                self.updateHeader()
            }
        }
    }

    @objc private func toggleAutoStart() {
        let desired = autoStartItem.state == .off
        do {
            if desired {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            autoStartItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            NSSound.beep()
        }
    }

    @objc private func restoreSleepDisabled() {
        if lidSleepItem.state == .on {
            try? PowerManager.setSleepDisabled(false)
        }
    }

    @objc private func clamshellTick() {
        let closed = PowerManager.clamshellClosed()
        guard closed != lastClamshellClosed else { return }
        lastClamshellClosed = closed
        guard lidSleepItem.state == .on else { return }
        // Przy zamkniętej klapie ekran ma nie świecić - usypiamy go.
        // Po otwarciu klapy budzimy wyświetlacz.
        if closed {
            PowerManager.displaySleepNow()
        } else {
            PowerManager.wakeDisplay()
        }
    }

    // MARK: - Clicks

    @objc private func handleClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.type == .rightMouseDown {
            cycleSleepMode()
        } else {
            statusItem.popUpMenu(statusMenu)
        }
    }

    // MARK: - Right-click cycle

    private func cycleSleepMode() {
        switch mode {
        case .off:
            systemSleepItem.state = .on
            displaySleepItem.state = .off
        case .systemOnly:
            systemSleepItem.state = .on
            displaySleepItem.state = .on
        case .systemAndDisplay:
            systemSleepItem.state = .off
            displaySleepItem.state = .off
        }
        refreshAssertions()
        updateIcon()
        updateHeader()
    }

    // MARK: - Icon & status

    private func updateHeader() {
        if lidSleepItem.state == .on {
            headerItem.title = "NoSleep — nie usypiaj po zamknięciu klapy"
        } else if systemSleepItem.state == .on, displaySleepItem.state == .on {
            headerItem.title = "NoSleep — nie usypiaj systemu i ekranu"
        } else if systemSleepItem.state == .on {
            headerItem.title = "NoSleep — nie usypiaj systemu"
        } else if displaySleepItem.state == .on {
            headerItem.title = "NoSleep — nie usypiaj ekranu"
        } else {
            headerItem.title = "NoSleep — wszystko wyłączone"
        }
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: "NoSleep"
        )
        image?.isTemplate = true
        return image
    }

    private func tintedSymbol(_ name: String, color: NSColor, size: NSSize) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }
        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        color.set()
        NSRect(origin: .zero, size: size).fill()
        symbol.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .destinationIn,
            fraction: 1.0
        )
        return result
    }

    private func glowingMoonImage() -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        image.isTemplate = false

        let center = NSPoint(x: size.width / 2, y: size.height / 2)
        let glowRadius: CGFloat = 10
        NSGradient(
            starting: NSColor.white.withAlphaComponent(0.6),
            ending: NSColor.white.withAlphaComponent(0.0)
        )?.draw(
            fromCenter: center,
            radius: 0,
            toCenter: center,
            radius: glowRadius,
            options: []
        )

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let moonColor = isDark ? NSColor.white : NSColor.black
        if let moon = tintedSymbol(
            "moon.zzz.fill",
            color: moonColor,
            size: NSSize(width: 16, height: 16)
        ) {
            moon.draw(
                in: NSRect(
                    x: (size.width - 16) / 2,
                    y: (size.height - 16) / 2,
                    width: 16,
                    height: 16
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        return image
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        if lidSleepItem.state == .on {
            button.image = symbolImage("laptopcomputer")
            return
        }
        switch mode {
        case .off:
            button.image = symbolImage("moon.zzz")
        case .systemOnly:
            button.image = symbolImage("moon.zzz.fill")
        case .systemAndDisplay:
            button.image = glowingMoonImage()
        }
    }
}

@main
@MainActor
struct NoSleepMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let controller = NoSleepController()
        _ = controller

        app.run()
    }
}