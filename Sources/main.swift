// DockPin — keeps the macOS Dock on the displays you choose.
//
// How it works: the Dock jumps to another display when the cursor is pushed
// against that display's Dock edge (bottom, or left/right). An event tap
// watches mouse movement and, on displays where the Dock is not allowed, keeps
// the cursor a couple of points away from that edge so the Dock never moves.

import Cocoa
import ServiceManagement

// MARK: - Display model

struct DisplayInfo {
    let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let bounds: CGRect      // global CG coordinates (top-left origin)
    var allowed: Bool
}

enum DockEdge: String { case bottom, left, right }

// State read by the event tap callback (runs on the main run loop).
var gDisplays: [DisplayInfo] = []
var gEnabled = true
var gSuspended = false      // true while we are deliberately moving the Dock
var gEdge: DockEdge = .bottom
var gTap: CFMachPort?

let kSyntheticMarker: Int64 = 0x444F_434B   // "DOCK", tags our own posted events

// MARK: - Settings

enum Prefs {
    static let d = UserDefaults.standard
    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var autoRelocate: Bool {
        get { d.object(forKey: "autoRelocate") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoRelocate") }
    }
    static var allowed: [String] {   // ordered; first = preferred Dock display
        get { d.stringArray(forKey: "allowedDisplays") ?? [] }
        set { d.set(newValue, forKey: "allowedDisplays") }
    }
    static var known: Set<String> {
        get { Set(d.stringArray(forKey: "knownDisplays") ?? []) }
        set { d.set(Array(newValue), forKey: "knownDisplays") }
    }
}

func displayUUID(_ id: CGDirectDisplayID) -> String {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "id-\(id)" }
    return CFUUIDCreateString(nil, u) as String
}

func readDockEdge() -> DockEdge {
    let o = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
    return DockEdge(rawValue: o) ?? .bottom
}

// MARK: - Edge clamping (the actual "lock")

func anyDisplayContains(_ p: CGPoint) -> Bool {
    gDisplays.contains { $0.bounds.contains(p) }
}

/// Returns a corrected cursor position if `p` is touching the Dock edge of a
/// display where the Dock is not allowed, otherwise nil.
func clampedPoint(_ p: CGPoint) -> CGPoint? {
    guard let d = gDisplays.first(where: { $0.bounds.insetBy(dx: -1, dy: -1).contains(p) }),
          !d.allowed else { return nil }
    let b = d.bounds
    switch gEdge {
    case .bottom:
        // Only an outer edge counts; a display stacked below must stay reachable.
        if p.y >= b.maxY - 1, !anyDisplayContains(CGPoint(x: p.x, y: b.maxY + 1)) {
            return CGPoint(x: p.x, y: b.maxY - 2)
        }
    case .left:
        if p.x <= b.minX + 1, !anyDisplayContains(CGPoint(x: b.minX - 1, y: p.y)) {
            return CGPoint(x: b.minX + 2, y: p.y)
        }
    case .right:
        if p.x >= b.maxX - 1, !anyDisplayContains(CGPoint(x: b.maxX + 1, y: p.y)) {
            return CGPoint(x: b.maxX - 2, y: p.y)
        }
    }
    return nil
}

func tapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard gEnabled, !gSuspended,
          event.getIntegerValueField(.eventSourceUserData) != kSyntheticMarker,
          let q = clampedPoint(event.location) else {
        return Unmanaged.passUnretained(event)
    }
    event.location = q
    switch gEdge {
    case .bottom: event.setIntegerValueField(.mouseEventDeltaY, value: 0)
    case .left, .right: event.setIntegerValueField(.mouseEventDeltaX, value: 0)
    }
    CGWarpMouseCursorPosition(q)
    CGAssociateMouseAndMouseCursorPosition(1)   // avoid the post-warp freeze
    return Unmanaged.passUnretained(event)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var screenChangeWork: DispatchWorkItem?
    var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        gEnabled = Prefs.enabled
        gEdge = readDockEdge()
        refreshDisplays()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // Dock orientation can be changed in System Settings at any time.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(dockPrefsMaybeChanged),
            name: NSNotification.Name("com.apple.dock.prefchanged"), object: nil)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in gEdge = readDockEdge() }

        if !installTap() {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            // Keep retrying until the user grants Accessibility access.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if self?.installTap() == true { t.invalidate(); self?.updateIcon() }
            }
        }
        updateIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.relocateIfNeeded() }
    }

    // MARK: Event tap

    @discardableResult
    func installTap() -> Bool {
        if gTap != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: tapCallback, userInfo: nil) else { return false }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        gTap = tap
        return true
    }

    // MARK: Displays

    func refreshDisplays() {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var names: [CGDirectDisplayID: String] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[n.uint32Value] = s.localizedName
            }
        }
        // Skip mirrored secondaries; they share the primary's space.
        let active = ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        var allowed = Prefs.allowed
        var known = Prefs.known
        let uuids = active.map(displayUUID)
        // A display we've never seen: allow it only if nothing connected is allowed yet,
        // so a fresh install doesn't leave the Dock with nowhere to go.
        for (id, u) in zip(active, uuids) where !known.contains(u) {
            known.insert(u)
            let noneAllowed = !uuids.contains { allowed.contains($0) }
            if noneAllowed && (CGDisplayIsMain(id) != 0 || active.count == 1) { allowed.append(u) }
        }
        Prefs.known = known
        Prefs.allowed = allowed

        gDisplays = zip(active, uuids).map { id, u in
            DisplayInfo(id: id, uuid: u,
                        name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display \(id)"),
                        bounds: CGDisplayBounds(id), allowed: allowed.contains(u))
        }
    }

    /// The display currently hosting the Dock, inferred from which screen's
    /// visible frame is inset on the Dock edge.
    func currentDockDisplay() -> CGDirectDisplayID? {
        var best: (CGDirectDisplayID, CGFloat)?
        for s in NSScreen.screens {
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let f = s.frame, v = s.visibleFrame
            let inset: CGFloat
            switch gEdge {
            case .bottom: inset = v.minY - f.minY
            case .left:   inset = v.minX - f.minX
            case .right:  inset = f.maxX - v.maxX
            }
            if inset > 0, inset > (best?.1 ?? 0) { best = (n.uint32Value, inset) }
        }
        return best?.0
    }

    // MARK: Moving the Dock

    /// Moves the Dock by briefly pushing the cursor against the target's Dock edge.
    func moveDock(to id: CGDirectDisplayID, completion: (() -> Void)? = nil) {
        let b = CGDisplayBounds(id)
        let original = CGEvent(source: nil)?.location ?? CGPoint(x: b.midX, y: b.midY)
        let edgePoint: CGPoint
        var dx: Int64 = 0, dy: Int64 = 0
        switch gEdge {
        case .bottom: edgePoint = CGPoint(x: b.midX, y: b.maxY - 1); dy = 8
        case .left:   edgePoint = CGPoint(x: b.minX, y: b.midY);     dx = -8
        case .right:  edgePoint = CGPoint(x: b.maxX - 1, y: b.midY); dx = 8
        }
        gSuspended = true
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0
        src?.userData = kSyntheticMarker
        CGWarpMouseCursorPosition(edgePoint)

        var step = 0
        func pump() {
            if step < 30 {
                if let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                                   mouseCursorPosition: edgePoint, mouseButton: .left) {
                    e.setIntegerValueField(.mouseEventDeltaX, value: dx)
                    e.setIntegerValueField(.mouseEventDeltaY, value: dy)
                    e.post(tap: .cghidEventTap)
                }
                step += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: pump)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    CGWarpMouseCursorPosition(original)
                    CGAssociateMouseAndMouseCursorPosition(1)
                    gSuspended = false
                    completion?()
                }
            }
        }
        pump()
    }

    func relocateIfNeeded() {
        guard gEnabled, Prefs.autoRelocate, gDisplays.count > 1,
              let current = currentDockDisplay(),
              let here = gDisplays.first(where: { $0.id == current }), !here.allowed,
              let targetUUID = Prefs.allowed.first(where: { u in gDisplays.contains { $0.uuid == u } }),
              let target = gDisplays.first(where: { $0.uuid == targetUUID }) else { return }
        moveDock(to: target.id)
    }

    // MARK: Notifications

    @objc func screensChanged() {
        screenChangeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            self?.refreshDisplays()
            self?.relocateIfNeeded()
        }
        screenChangeWork = w
        refreshDisplays()   // update bounds immediately so the clamp stays correct
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    @objc func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refreshDisplays()
            self?.relocateIfNeeded()
        }
    }

    @objc func dockPrefsMaybeChanged() { gEdge = readDockEdge() }

    // MARK: Menu

    func updateIcon() {
        let symbol = gTap == nil ? "exclamationmark.triangle" : (gEnabled ? "dock.rectangle" : "rectangle.dashed")
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "DockPin")
        img?.isTemplate = true
        statusItem?.button?.image = img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        gEdge = readDockEdge()
        refreshDisplays()
        menu.removeAllItems()

        if gTap == nil {
            let warn = NSMenuItem(title: "⚠️ Grant Accessibility Access…", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Enable Dock Locking", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        toggle.state = gEnabled ? .on : .off
        menu.addItem(toggle)
        menu.addItem(.separator())

        let current = currentDockDisplay()
        menu.addItem(header("Allow Dock on Display"))
        for d in gDisplays {
            let it = NSMenuItem(title: d.name + (d.id == current ? "  (Dock here)" : ""),
                                action: #selector(toggleAllowed(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = d.uuid
            it.state = d.allowed ? .on : .off
            it.indentationLevel = 1
            menu.addItem(it)
        }
        if !gDisplays.contains(where: { $0.allowed }) {
            let w = header("⚠️ No display allowed — Dock can't appear")
            w.indentationLevel = 1
            menu.addItem(w)
        }
        menu.addItem(.separator())

        let move = NSMenuItem(title: "Move Dock to Display", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for d in gDisplays {
            let it = NSMenuItem(title: d.name, action: #selector(moveDockItem(_:)), keyEquivalent: "")
            it.target = self
            it.tag = Int(d.id)
            it.state = d.id == current ? .on : .off
            sub.addItem(it)
        }
        move.submenu = sub
        menu.addItem(move)

        let auto = NSMenuItem(title: "Auto-Relocate Dock on Wake / Display Change",
                              action: #selector(toggleAutoRelocate), keyEquivalent: "")
        auto.target = self
        auto.state = Prefs.autoRelocate ? .on : .off
        menu.addItem(auto)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(header("Dock position: \(gEdge.rawValue)"))
        let quit = NSMenuItem(title: "Quit DockPin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func header(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    @objc func toggleEnabled() {
        gEnabled.toggle()
        Prefs.enabled = gEnabled
        updateIcon()
        if gEnabled { relocateIfNeeded() }
    }

    @objc func toggleAllowed(_ sender: NSMenuItem) {
        guard let u = sender.representedObject as? String else { return }
        var allowed = Prefs.allowed
        if let i = allowed.firstIndex(of: u) { allowed.remove(at: i) } else { allowed.append(u) }
        Prefs.allowed = allowed
        refreshDisplays()
        relocateIfNeeded()
    }

    @objc func moveDockItem(_ sender: NSMenuItem) {
        // Let the menu close before we move the cursor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.moveDock(to: CGDirectDisplayID(sender.tag))
        }
    }

    @objc func toggleAutoRelocate() {
        Prefs.autoRelocate.toggle()
        if Prefs.autoRelocate { relocateIfNeeded() }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
