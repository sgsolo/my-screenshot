import AppKit
import AVFoundation
import Carbon
import CoreGraphics
import ImageIO
import OSLog
import QuartzCore
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

private let appName = "Мой Скриншот"
private let screenPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
private let saveDirectoryKey = "captureSaveDirectory"
private let screenshotFormatKey = "screenshotFormat"
private let loginDefaultConfiguredKey = "didConfigureDefaultLoginItem"

enum CaptureError: LocalizedError {
    case displayUnavailable, invalidSelection, imageWriteFailed, emptyRecording, invalidSaveFolder

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "Не удалось найти выбранный дисплей."
        case .invalidSelection: "Не удалось вырезать выделенную область."
        case .imageWriteFailed: "Не удалось сохранить изображение."
        case .emptyRecording: "Видео не сохранилось."
        case .invalidSaveFolder: String(localized: "storage.folder.unavailable")
        }
    }
}

private enum ScreenshotFormat: String, CaseIterable {
    case png = "PNG"
    case jpeg = "JPEG"
    case pdf = "PDF"

    var type: UTType {
        switch self {
        case .png: .png
        case .jpeg: .jpeg
        case .pdf: .pdf
        }
    }

    var fileExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .pdf: "pdf"
        }
    }

    func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        if self == .pdf {
            var page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &page, nil) else {
                throw CaptureError.imageWriteFailed
            }
            context.beginPDFPage(nil)
            context.draw(image, in: page)
            context.endPDFPage()
            context.closePDF()
            return data as Data
        }
        guard let writer = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CaptureError.imageWriteFailed
        }
        let options = self == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary : nil
        CGImageDestinationAddImage(writer, image, options)
        guard CGImageDestinationFinalize(writer) else { throw CaptureError.imageWriteFailed }
        return data as Data
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static var underPointer: NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main
    }

    var captureRect: CGRect {
        guard let displayID else { return .zero }
        return CGDisplayBounds(displayID)
    }
}

@MainActor
private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock)
        if modifiers == .command, event.keyCode == UInt16(kVK_ANSI_C),
           let canvas = contentView as? SelectionView, canvas.copyAndSave() {
            return true
        }
        guard modifiers == .command, let fieldEditor = firstResponder as? NSTextView, fieldEditor.isFieldEditor else {
            return super.performKeyEquivalent(with: event)
        }
        switch Int(event.keyCode) {
        case kVK_ANSI_A: fieldEditor.selectAll(nil)
        case kVK_ANSI_C: fieldEditor.copy(nil)
        case kVK_ANSI_V: fieldEditor.paste(nil)
        case kVK_ANSI_X: fieldEditor.cut(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

@MainActor
private final class CapturePreviewPanel: NSPanel {
    var onSwipeRight: (() -> Void)?
    private var scrollDistance = CGPoint.zero
    private var lastScrollTime: TimeInterval = 0
    private var swipeMonitor: Any?

    func startMonitoringSwipe(in edge: CGRect) {
        endMonitoringSwipe()
        swipeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                let continuingSwipe = event.type == .scrollWheel && !event.phase.contains(.began)
                    && self.scrollDistance.x > 0 && event.timestamp - self.lastScrollTime <= 0.25
                let location = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
                if continuingSwipe || edge.contains(location) {
                    self.handleSwipe(event)
                }
            }
        }
    }

    func endMonitoringSwipe() {
        if let swipeMonitor {
            NSEvent.removeMonitor(swipeMonitor)
            self.swipeMonitor = nil
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel || event.type == .swipe {
            handleSwipe(event)
        } else {
            super.sendEvent(event)
        }
    }

    private func handleSwipe(_ event: NSEvent) {
        guard onSwipeRight != nil, NSEvent.pressedMouseButtons & 1 == 0 else { return }
        switch event.type {
        case .swipe:
            let dx = event.isDirectionInvertedFromDevice ? event.deltaX : -event.deltaX
            if dx > 0 { dismissWithSwipe() }
        case .scrollWheel:
            guard event.momentumPhase.isEmpty else { return }
            if event.phase.contains(.began) || event.timestamp - lastScrollTime > 0.25 {
                scrollDistance = .zero
            }
            lastScrollTime = event.timestamp
            if !event.phase.intersection([.ended, .cancelled]).isEmpty {
                scrollDistance = .zero
                return
            }
            let dx = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            scrollDistance.x += dx
            scrollDistance.y += abs(event.scrollingDeltaY)
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 24 : 4
            if scrollDistance.x >= threshold && scrollDistance.x > 1.4 * scrollDistance.y {
                dismissWithSwipe()
            }
        default:
            break
        }
    }

    private func dismissWithSwipe() {
        let action = onSwipeRight
        onSwipeRight = nil
        action?()
    }
}

@MainActor
private final class CapturePreviewButton: NSButton, NSDraggingSource {
    enum DragResult { case dropped, dismissed, cancelled }

    var fileURL: URL?
    var imagePayload: (format: ScreenshotFormat, data: Data)?
    var onDragStarted: (() -> Void)?
    var onDragEnded: ((DragResult) -> Void)?
    private var pressEvent: NSEvent?
    private var didMove = false
    private var dragStart: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressEvent = event
        didMove = false
        highlight(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let press = pressEvent, let fileURL, let window else { return }
        let point = event.locationInWindow
        let start = press.locationInWindow
        let dx = point.x - start.x
        let dy = abs(point.y - start.y)
        guard hypot(dx, dy) >= 4 else { return }
        if !didMove {
            didMove = true
            onDragStarted?()
        }
        // Give a short rightward flick a chance to end before starting a file drag.
        if dx >= dy, dx < 48, bounds.contains(convert(point, from: nil)) { return }

        let payload = NSPasteboardItem()
        payload.setString(fileURL.absoluteString, forType: .fileURL)
        if let imagePayload {
            payload.setData(imagePayload.data, forType: .init(rawValue: imagePayload.format.type.identifier))
        }
        let item = NSDraggingItem(pasteboardWriter: payload)
        let size = image?.size ?? bounds.size
        let previewRect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                 width: size.width, height: size.height)
        item.setDraggingFrame(previewRect, contents: image)
        dragStart = window.convertPoint(toScreen: start)
        pressEvent = nil
        highlight(false)
        beginDraggingSession(with: [item], event: press, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let press = pressEvent else { return }
        pressEvent = nil
        highlight(false)
        let start = press.locationInWindow
        let point = event.locationInWindow
        if isRightwardDrag(from: start, to: point) {
            onDragEnded?(.dismissed)
        } else if didMove || hypot(point.x - start.x, point.y - start.y) >= 4 {
            onDragEnded?(.cancelled)
        } else if bounds.contains(convert(point, from: nil)) {
            performClick(nil)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        guard let dragStart else { return }
        session.animatesToStartingPositionsOnCancelOrFail = !isRightwardDrag(from: dragStart, to: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { dragStart = nil }
        if !operation.isEmpty {
            onDragEnded?(.dropped)
        } else if let dragStart, NSEvent.pressedMouseButtons & 1 == 0,
                  isRightwardDrag(from: dragStart, to: screenPoint) {
            onDragEnded?(.dismissed)
        } else {
            onDragEnded?(.cancelled)
        }
    }

    private func isRightwardDrag(from start: NSPoint, to point: NSPoint) -> Bool {
        let dx = point.x - start.x
        let dy = abs(point.y - start.y)
        return dx >= 16 && dx > 1.25 * dy
    }
}

@MainActor
private final class RecordingShadeView: NSView {
    private let region: CGRect
    override var isFlipped: Bool { true }

    init(size: CGSize, region: CGRect) {
        self.region = region
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        drawCaptureShade(in: bounds, excluding: region)
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    enum Event: Sendable {
        case started, finished, failed(String)
    }

    let notify: @Sendable (Event) -> Void

    init(notify: @escaping @Sendable (Event) -> Void) {
        self.notify = notify
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        notify(.started)
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        notify(.finished)
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        notify(.failed(error.localizedDescription))
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        notify(.failed(error.localizedDescription))
    }
}

@MainActor
private final class CaptureApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private enum VideoState { case idle, starting, recording, stopping }

    private let log = Logger(subsystem: "local.myscreenshot.app", category: "App")
    private let loginService = SMAppService.mainApp
    private let hotKeyID = EventHotKeyID(signature: 0x4D595343, id: 1)
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var escapeKey: EventHotKeyRef?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var videoState = VideoState.idle
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordingDelegate: RecordingDelegate?
    private var recordingID: UUID?
    private var recordingDisplayID: CGDirectDisplayID?
    private var recordingShade: NSPanel?
    private var recordingDisplayFilter: SCContentFilter?
    private var recordingURL: URL?
    private var terminationPending = false
    private var stopTimeout: Task<Void, Never>?
    private var savingScreenshot = false
    private var selectionWindow: SelectionWindow?
    private var previewPanel: CapturePreviewPanel?
    private var previewURL: URL?
    private var previewTimeout: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var guideWindow: NSWindow?
    private var guideStatus: NSTextField?
    private var settingsWindow: NSWindow?
    private var saveFolderPath: NSTextField?
    private var resetFolderButton: NSButton?
    private var alertVisible = false

    private var lastFile: URL? {
        get { UserDefaults.standard.string(forKey: "lastFile").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "lastFile") }
    }

    private var customSaveDirectory: URL? {
        UserDefaults.standard.string(forKey: saveDirectoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private var saveDirectory: URL {
        customSaveDirectory ?? URL.picturesDirectory.appendingPathComponent(appName, isDirectory: true)
    }

    private var screenshotFormat: ScreenshotFormat {
        UserDefaults.standard.string(forKey: screenshotFormatKey).flatMap(ScreenshotFormat.init(rawValue:)) ?? .png
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: 36)
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateStatusItem()

        registerHotKey()
        configureDefaultLoginItem()
        if !UserDefaults.standard.bool(forKey: "didOfferLogin") {
            UserDefaults.standard.set(true, forKey: "didOfferLogin")
            showGuide()
        }
        log.notice("Status item ready. Hotkey registered: \(self.hotKey != nil). Login status: \(self.loginService.status.rawValue).")
        log.notice("Menu icon: \(self.statusItem.button?.image?.size.width ?? 0) × \(self.statusItem.button?.image?.size.height ?? 0) pt. Screen capture authorized: \(CGPreflightScreenCaptureAccess()).")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showGuide()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard videoState != .idle else { return .terminateNow }
        terminationPending = true
        if videoState == .recording { stopVideo() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let escapeKey { UnregisterEventHotKey(escapeKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        guard let shade = recordingShade else { return }
        if let screen = NSScreen.screens.first(where: { $0.displayID == recordingDisplayID }),
           screen.frame.size == shade.frame.size {
            shade.setFrame(screen.frame, display: true)
        } else {
            shade.orderOut(nil)
            recordingShade = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === guideWindow {
            guideWindow = nil
            guideStatus = nil
        }
        if (notification.object as? NSWindow) === settingsWindow {
            settingsWindow = nil
            saveFolderPath = nil
            resetFolderButton = nil
        }
    }

    private func registerHotKey() {
        guard hotKey == nil else { return }
        if eventHandler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var key = EventHotKeyID()
                let result = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID),
                                               nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
                guard result == noErr, key.signature == 0x4D595343, key.id == 1 || key.id == 2 else {
                    return OSStatus(eventNotHandledErr)
                }
                let app = Unmanaged<CaptureApp>.fromOpaque(context).takeUnretainedValue()
                let keyID = key.id
                Task { @MainActor in
                    if keyID == 1 {
                        app.captureArea()
                    } else if app.selectionWindow != nil {
                        app.dismissSelection()
                    }
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard result == noErr else {
                log.error("Could not install hotkey handler: \(result).")
                return
            }
        }

        let result = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | shiftKey),
                                         hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            hotKey = nil
            log.error("Could not register Command–Shift–A: \(result).")
        }
    }

    @objc private func retryHotKey() {
        registerHotKey()
        refreshGuide()
        if hotKey == nil {
            showAlert("Сочетание ⌘⇧A занято", "Освободите это сочетание в другом приложении и повторите попытку.")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let canCapture = !savingScreenshot && selectionWindow == nil && !alertVisible
        add("Скриншот области", #selector(captureAreaFromMenu), enabled: canCapture,
            key: hotKey == nil ? "" : "a")
        add("Скриншот экрана", #selector(captureDisplay), enabled: canCapture)
        if hotKey == nil { add("Зарегистрировать ⌘⇧A ещё раз", #selector(retryHotKey)) }

        menu.addItem(.separator())
        switch videoState {
        case .idle:
            add("Записать область экрана", #selector(captureVideoAreaFromMenu), enabled: canCapture)
            add("Записать весь экран", #selector(startFullScreenVideo), enabled: canCapture)
        case .starting: add("Подготовка записи…", nil)
        case .recording: add("Остановить запись", #selector(stopVideo))
        case .stopping: add("Сохранение видео…", nil)
        }
        menu.addItem(.separator())
        let fileExists = lastFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        add("Показать последний файл", #selector(revealLastFile), enabled: fileExists)
        add(String(localized: "storage.folder.open"), #selector(openSaveFolder))
        let formats = add(String(localized: "storage.format.menu"), nil)
        let choices = NSMenu()
        choices.autoenablesItems = false
        for format in ScreenshotFormat.allCases {
            let item = NSMenuItem(title: format.rawValue, action: #selector(selectScreenshotFormat(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format.rawValue
            item.state = screenshotFormat == format ? .on : .off
            choices.addItem(item)
        }
        formats.submenu = choices
        formats.isEnabled = true
        menu.addItem(.separator())
        add(String(localized: "storage.settings.menu"), #selector(showSettings))
        let login = add("Запускать при входе", #selector(toggleLogin))
        login.state = loginService.status == .enabled ? .on : .off
        add("О приложении…", #selector(showGuide))
        add("Выйти", #selector(quit))
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector?, enabled: Bool = true, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled && action != nil
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command, .shift] }
        menu.addItem(item)
        return item
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let recording = videoState != .idle
        let symbol = recording ? "record.circle.fill" : "camera.fill"
        let description = recording ? "Мой Скриншот — запись экрана" : appName
        let baseImage = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        let image = baseImage?.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold))
        image?.isTemplate = true
        button.imageScaling = .scaleNone
        button.image = image
        button.contentTintColor = recording ? .systemRed : nil
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private func prepareSaveDirectory() throws -> URL {
        let directory = saveDirectory
        if customSaveDirectory == nil {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CaptureError.invalidSaveFolder
        }
        return directory
    }

    private func outputURL(prefix: String, ext: String) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
        return try prepareSaveDirectory()
            .appendingPathComponent("\(prefix) \(formatter.string(from: Date()))")
            .appendingPathExtension(ext)
    }

    @objc private func openSaveFolder() {
        do {
            NSWorkspace.shared.open(try prepareSaveDirectory())
        } catch {
            showAlert(String(localized: "storage.folder.unavailable"), error.localizedDescription)
        }
    }

    @objc private func selectScreenshotFormat(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let format = ScreenshotFormat(rawValue: value) else { return }
        UserDefaults.standard.set(format.rawValue, forKey: screenshotFormatKey)
    }

    @objc private func revealLastFile() {
        guard let lastFile, FileManager.default.fileExists(atPath: lastFile.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastFile])
    }

    private func configureDefaultLoginItem() {
        guard !UserDefaults.standard.bool(forKey: loginDefaultConfiguredKey) else { return }
        do {
            switch loginService.status {
            case .enabled, .requiresApproval: break
            case .notRegistered, .notFound: try loginService.register()
            @unknown default: return
            }
            UserDefaults.standard.set(true, forKey: loginDefaultConfiguredKey)
        } catch {
            log.error("Could not enable login by default: \(error.localizedDescription).")
        }
    }

    @objc private func toggleLogin() {
        do {
            switch loginService.status {
            case .enabled: try loginService.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default: try loginService.register()
            }
            UserDefaults.standard.set(true, forKey: loginDefaultConfiguredKey)
        } catch {
            showAlert("Не удалось изменить автозапуск", error.localizedDescription)
        }
        refreshGuide()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func checkCapturePermission() -> Bool {
        guard !alertVisible else { return false }
        if CGPreflightScreenCaptureAccess() { return true }
        log.notice("Capture command reached; Screen Recording permission is not enabled.")
        showAlert("Нужно разрешение на захват экрана",
                  "В настройках macOS включите «Мой Скриншот» в разделе «Запись экрана и системного звука». После этого может понадобиться перезапуск приложения.",
                  primary: "Запросить доступ") { [weak self] in
            self?.requestCapturePermission()
        }
        return false
    }

    @objc private func requestCapturePermission() {
        if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(screenPrivacy) }
        refreshGuide()
    }

    @objc private func captureAreaFromMenu() {
        selectAreaAfterMenu(for: .screenshot)
    }

    @objc private func captureVideoAreaFromMenu() {
        selectAreaAfterMenu(for: .recording)
    }

    private func selectAreaAfterMenu(for mode: SelectionMode) {
        // Finish menu tracking before showing a window that needs keyboard focus.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.selectArea(for: mode) }
        }
    }

    private func captureArea() {
        if selectionWindow != nil {
            dismissSelection()
        } else {
            selectArea(for: .screenshot)
        }
    }

    private func selectArea(for mode: SelectionMode) {
        guard !savingScreenshot, selectionWindow == nil,
              mode != .recording || videoState == .idle,
              let screen = NSScreen.underPointer, checkCapturePermission() else { return }
        let displayRect = screen.captureRect
        let windowRect = screen.frame
        guard !displayRect.isEmpty, !windowRect.isEmpty else { return }

        let waitForPreview = previewPanel != nil
        dismissCapturePreview()
        savingScreenshot = true
        Task { @MainActor in
            defer { savingScreenshot = false }
            do {
                if waitForPreview { try await Task.sleep(for: .milliseconds(60)) }
                let windows = windowSuggestions(in: displayRect, minimumSize: mode.minimumSize)
                let image = try await captureScreenImage(on: screen)
                guard let currentScreen = NSScreen.screens.first(where: { $0.displayID == screen.displayID }),
                      currentScreen.frame == windowRect else {
                    throw CaptureError.displayUnavailable
                }
                showSelection(FrozenFrame(image: image, size: windowRect.size), on: currentScreen, for: mode,
                              windows: windows)
            } catch {
                showAlert("Не удалось сделать скриншот", error.localizedDescription)
            }
        }
    }

    private func windowSuggestions(in display: CGRect, minimumSize: CGFloat) -> WindowSuggestions {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var bounds: [CGRect] = []
        var focused: CGRect?
        for info in windows {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0 > 0.05,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { continue }
            let clipped = rect.intersection(display)
            guard !clipped.isNull, clipped.width >= minimumSize, clipped.height >= minimumSize else { continue }
            let local = clipped.offsetBy(dx: -display.minX, dy: -display.minY)
            bounds.append(local)
            if focused == nil, let frontmostPID,
               (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == frontmostPID {
                focused = local
            }
        }
        return WindowSuggestions(bounds: bounds, focused: focused)
    }

    private func showSelection(_ frame: FrozenFrame, on screen: NSScreen, for mode: SelectionMode,
                               windows: WindowSuggestions) {
        previousApp = NSWorkspace.shared.frontmostApplication
        let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                     backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: true)
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = SelectionView(frame: frame, mode: mode, windows: windows) { [weak self] rect, annotations, copy in
            guard let self else { return }
            dismissSelection()
            guard let rect else { return }
            switch mode {
            case .screenshot:
                do {
                    try writeScreenshot(frame.render(rect, annotations: annotations), on: screen, copy: copy)
                } catch {
                    showAlert("Не удалось сделать скриншот", error.localizedDescription)
                }
            case .recording:
                guard let id = screen.displayID,
                      let currentScreen = NSScreen.screens.first(where: { $0.displayID == id }),
                      currentScreen.frame == screen.frame else {
                    showAlert("Не удалось начать запись", CaptureError.displayUnavailable.localizedDescription)
                    return
                }
                startVideo(on: id, region: rect)
            }
        }
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        selectionWindow = window
        let pointer = NSEvent.mouseLocation
        view.suggestInitialWindow(at: CGPoint(x: pointer.x - screen.frame.minX, y: screen.frame.maxY - pointer.y))
        // The menu or the previous app can still own keyboard focus while the overlay is visible.
        let escapeID = EventHotKeyID(signature: hotKeyID.signature, id: 2)
        let result = RegisterEventHotKey(UInt32(kVK_Escape), 0, escapeID, GetApplicationEventTarget(), 0, &escapeKey)
        if result != noErr { escapeKey = nil }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    private func dismissSelection() {
        if let escapeKey {
            UnregisterEventHotKey(escapeKey)
            self.escapeKey = nil
        }
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }

    @objc private func captureDisplay() {
        guard !savingScreenshot, selectionWindow == nil,
              let screen = NSScreen.underPointer, checkCapturePermission() else { return }
        saveScreenshot(on: screen)
    }

    private func saveScreenshot(on screen: NSScreen) {
        let rect = screen.captureRect
        guard !rect.isEmpty else { return }
        dismissCapturePreview()
        savingScreenshot = true
        Task { @MainActor in
            defer { savingScreenshot = false }
            do {
                // Let the menu close before capturing the entire display.
                try await Task.sleep(for: .milliseconds(120))
                let image = try await captureScreenImage(on: screen)
                try writeScreenshot(image, on: screen)
            } catch {
                showAlert("Не удалось сделать скриншот", error.localizedDescription)
            }
        }
    }

    private func captureScreenImage(on screen: NSScreen) async throws -> CGImage {
        guard let filter = recordingDisplayFilter, recordingShade != nil, screen.displayID == recordingDisplayID else {
            return try await SCScreenshotManager.captureImage(in: screen.captureRect)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func writeScreenshot(_ image: CGImage, on screen: NSScreen, copy: Bool = false) throws {
        let format = screenshotFormat
        let url = try outputURL(prefix: "Скриншот", ext: format.fileExtension)
        let data = try format.encode(image)
        try data.write(to: url, options: .atomic)
        var copiedToClipboard = false
        if copy, let png = format == .png ? data : try? ScreenshotFormat.png.encode(image) {
            NSPasteboard.general.clearContents()
            copiedToClipboard = NSPasteboard.general.setData(png, forType: .png)
        }
        markSaved(url)
        var thumbnail = image
        if format != .pdf, let source = CGImageSourceCreateWithData(data as CFData, nil),
           let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 360
           ] as CFDictionary) {
            thumbnail = scaled
        }
        showCapturePreview(NSImage(cgImage: thumbnail, size: .zero), at: url, on: screen,
                           imagePayload: (format, data), copiedToClipboard: copiedToClipboard)
    }

    private func prepareRecordingPreview(at url: URL, displayID: CGDirectDisplayID?) {
        Task { @MainActor [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.maximumSize = CGSize(width: 360, height: 360)
            generator.appliesPreferredTrackTransform = true
            let frame = try? await generator.image(at: .zero).image
            guard let self, self.lastFile == url, self.videoState == .idle, self.selectionWindow == nil,
                  let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.underPointer else {
                return
            }
            let image = frame.map { NSImage(cgImage: $0, size: .zero) } ?? NSWorkspace.shared.icon(forFile: url.path)
            self.showCapturePreview(image, at: url, on: screen)
        }
    }

    private func showCapturePreview(_ image: NSImage, at url: URL, on screen: NSScreen,
                                    imagePayload: (format: ScreenshotFormat, data: Data)? = nil,
                                    copiedToClipboard: Bool = false) {
        dismissCapturePreview()
        let isVideo = imagePayload == nil
        let scale = min(168 / image.size.width, 108 / image.size.height)
        let imageSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.size = imageSize
        let thumbnailSize = CGSize(width: max(62, imageSize.width + 10), height: max(48, imageSize.height + 10))
        let dragHelpKey = "didShowPreviewDragHelp"
        let showDragHelp = !UserDefaults.standard.bool(forKey: dragHelpKey)
        var notes: [NSView] = []
        if copiedToClipboard {
            notes.append(previewNote(symbol: "checkmark.circle.fill",
                                     title: String(localized: "preview.clipboard.title"),
                                     detail: String(localized: "preview.clipboard.detail")))
        }
        if showDragHelp {
            notes.append(previewNote(symbol: "cursorarrow.motionlines",
                                     title: String(localized: "preview.drag.title"),
                                     detail: String(localized: "preview.drag.detail")))
        }
        let notice = NSStackView(views: notes)
        notice.orientation = .vertical
        notice.alignment = .leading
        notice.spacing = 8
        let noticeSize = notice.fittingSize
        let size = notes.isEmpty ? thumbnailSize : CGSize(
            width: thumbnailSize.width + noticeSize.width + 28,
            height: max(thumbnailSize.height, noticeSize.height + 20)
        )
        let visible = screen.visibleFrame
        let rect = CGRect(x: visible.maxX - size.width - 18, y: visible.minY + 18,
                          width: size.width, height: size.height)

        let panel = CapturePreviewPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                                        backing: .buffered, defer: false, screen: screen)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.sharingType = .none
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.title = isVideo ? "Запись сохранена" : "Снимок сохранён"

        let backdrop = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        let thumbnailRect = CGRect(x: size.width - thumbnailSize.width, y: (size.height - thumbnailSize.height) / 2,
                                    width: thumbnailSize.width, height: thumbnailSize.height)
        let button = CapturePreviewButton(frame: thumbnailRect.insetBy(dx: 5, dy: 5))
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.fileURL = url
        button.imagePayload = imagePayload
        button.target = self
        button.action = #selector(openCapturePreview)
        button.toolTip = isVideo
            ? "Щелчок — открыть запись. Перетащите, чтобы вложить MP4."
            : "Щелчок — открыть снимок. Перетащите, чтобы вложить \(url.pathExtension.uppercased())."
        button.setAccessibilityLabel(isVideo ? "Открыть запись и показать в Finder" : "Открыть снимок и показать в Finder")
        if !notes.isEmpty {
            notice.frame = CGRect(x: 12, y: (size.height - noticeSize.height) / 2,
                                  width: noticeSize.width, height: noticeSize.height)
            backdrop.addSubview(notice)
        }
        backdrop.addSubview(button)
        panel.contentView = backdrop
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(animated ? rect.offsetBy(dx: 20, dy: 0) : rect, display: true)
        if animated { panel.alphaValue = 0 }
        previewURL = url
        previewPanel = panel
        panel.onSwipeRight = { [weak self] in
            self?.dismissCapturePreview(animated: animated, slidingRight: true)
        }
        button.onDragStarted = { [weak self] in
            self?.previewTimeout?.cancel()
            self?.previewTimeout = nil
        }
        button.onDragEnded = { [weak self, weak panel] result in
            guard let self, let panel, self.previewPanel === panel else { return }
            switch result {
            case .dropped:
                self.dismissCapturePreview()
            case .dismissed:
                self.dismissCapturePreview(animated: animated, slidingRight: true)
            case .cancelled:
                self.scheduleCapturePreviewDismissal(animated: animated)
            }
        }
        panel.orderFrontRegardless()
        let edge = CGRect(x: rect.maxX, y: rect.minY, width: screen.frame.maxX - rect.maxX, height: rect.height)
        panel.startMonitoringSwipe(in: edge)
        if showDragHelp { UserDefaults.standard.set(true, forKey: dragHelpKey) }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(rect.origin)
                panel.animator().alphaValue = 1
            }
        }
        scheduleCapturePreviewDismissal(animated: animated)
    }

    private func previewNote(symbol: String, title: String, detail: String) -> NSStackView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let caption = NSTextField(labelWithString: detail)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let text = NSStackView(views: [heading, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        return row
    }

    private func scheduleCapturePreviewDismissal(animated: Bool) {
        previewTimeout?.cancel()
        previewTimeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            dismissCapturePreview(animated: animated)
        }
    }

    @objc private func openCapturePreview() {
        guard let url = previewURL else { return }
        dismissCapturePreview()
        let workspace = NSWorkspace.shared
        workspace.activateFileViewerSelecting([url])
        workspace.open(url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    private func dismissCapturePreview(animated: Bool = false, slidingRight: Bool = false) {
        previewTimeout?.cancel()
        previewTimeout = nil
        guard let panel = previewPanel else { return }
        panel.endMonitoringSwipe()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                if slidingRight {
                    panel.animator().setFrameOrigin(NSPoint(x: panel.frame.maxX, y: panel.frame.minY))
                }
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self, weak panel] in
                Task { @MainActor in
                    guard let self, let panel, self.previewPanel === panel else { return }
                    self.dismissCapturePreview()
                }
            }
            return
        }
        panel.orderOut(nil)
        previewPanel = nil
        previewURL = nil
    }

    @objc private func startFullScreenVideo() {
        guard let id = NSScreen.underPointer?.displayID, checkCapturePermission() else { return }
        startVideo(on: id, region: nil)
    }

    private func showRecordingShade(on screen: NSScreen, excluding region: CGRect) {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false, screen: screen)
        panel.setFrame(screen.frame, display: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = RecordingShadeView(size: screen.frame.size, region: region)
        recordingShade = panel
        panel.orderFrontRegardless()
    }

    private func startVideo(on id: CGDirectDisplayID, region: CGRect?) {
        guard videoState == .idle else { return }
        dismissCapturePreview()
        videoState = .starting
        updateStatusItem()
        let session = UUID()
        recordingID = session
        recordingDisplayID = id

        Task { @MainActor in
            do {
                if let region {
                    guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
                        throw CaptureError.displayUnavailable
                    }
                    let bounds = CGRect(origin: .zero, size: screen.frame.size)
                    let selection = region.intersection(bounds)
                    guard !selection.isEmpty else { throw CaptureError.invalidSelection }
                    if selection != bounds { showRecordingShade(on: screen, excluding: selection) }
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == id }) else {
                    throw CaptureError.displayUnavailable
                }
                let excludedWindows = content.windows.filter { Int($0.windowID) == recordingShade?.windowNumber }
                let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                if !excludedWindows.isEmpty { recordingDisplayFilter = filter }
                let configuration = SCStreamConfiguration()
                let displayBounds = CGRect(origin: .zero, size: filter.contentRect.size)
                let source = region?.intersection(displayBounds) ?? displayBounds
                guard !source.isEmpty else { throw CaptureError.invalidSelection }
                if region != nil { configuration.sourceRect = source }
                let width = source.width * CGFloat(filter.pointPixelScale)
                let height = source.height * CGFloat(filter.pointPixelScale)
                let scale = min(1, 3_840 / max(width, height), 2_160 / min(width, height))
                configuration.width = max(2, Int(width * scale) / 2 * 2)
                configuration.height = max(2, Int(height * scale) / 2 * 2)
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                configuration.showsCursor = true
                configuration.capturesAudio = false
                configuration.captureMicrophone = false

                let url = try outputURL(prefix: "Запись экрана", ext: "mp4")
                let outputConfig = SCRecordingOutputConfiguration()
                outputConfig.outputURL = url
                outputConfig.outputFileType = .mp4
                outputConfig.videoCodecType = .h264

                let delegate = RecordingDelegate { [weak self] event in
                    Task { @MainActor in self?.handleRecording(event, session: session) }
                }
                let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
                let output = SCRecordingOutput(configuration: outputConfig, delegate: delegate)
                self.stream = stream
                recordingOutput = output
                recordingDelegate = delegate
                recordingURL = url
                try stream.addRecordingOutput(output)
                try await stream.startCapture()
                if recordingID == session, videoState == .starting {
                    handleRecording(.started, session: session)
                }
            } catch {
                handleRecording(.failed(error.localizedDescription), session: session)
            }
        }
    }

    @objc private func stopVideo() {
        guard videoState == .recording, let stream, let session = recordingID else { return }
        videoState = .stopping
        updateStatusItem()
        stopTimeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            handleRecording(.failed("macOS не подтвердила сохранение видео."), session: session)
        }
        Task { @MainActor in
            do {
                try await stream.stopCapture()
                // ScreenCaptureKit sends the recording delegate completion after finalizing the MP4.
            } catch {
                handleRecording(.failed(error.localizedDescription), session: session)
            }
        }
    }

    private func handleRecording(_ event: RecordingDelegate.Event, session: UUID) {
        guard recordingID == session else { return }
        switch event {
        case .started:
            guard videoState == .starting else { return }
            videoState = .recording
            updateStatusItem()
            if terminationPending { stopVideo() }
        case .finished:
            if let url = recordingURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                markSaved(url)
                let displayID = recordingDisplayID
                finishRecording()
                if !terminationPending { prepareRecordingPreview(at: url, displayID: displayID) }
            } else {
                finishRecording(error: CaptureError.emptyRecording.localizedDescription)
            }
        case .failed(let message):
            finishRecording(error: message)
        }
    }

    private func finishRecording(error: String? = nil) {
        stopTimeout?.cancel()
        stopTimeout = nil
        recordingShade?.orderOut(nil)
        recordingShade = nil
        recordingDisplayFilter = nil
        if let url = recordingURL, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 0 {
            try? FileManager.default.removeItem(at: url)
        }
        recordingID = nil
        recordingDisplayID = nil
        recordingURL = nil
        stream = nil
        recordingOutput = nil
        recordingDelegate = nil
        videoState = .idle
        updateStatusItem()
        if terminationPending {
            NSApp.reply(toApplicationShouldTerminate: true)
        } else if let error {
            showAlert("Ошибка записи экрана", error)
        }
    }

    private func markSaved(_ url: URL) {
        lastFile = url
        updateStatusItem()
        statusItem.button?.toolTip = "Сохранено: \(url.lastPathComponent)"
        log.notice("Capture saved successfully.")
    }

    private func showAlert(_ title: String, _ detail: String, primary: String? = nil, action: (() -> Void)? = nil) {
        guard !alertVisible else { return }
        alertVisible = true
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        if let primary { alert.addButton(withTitle: primary) }
        let close = alert.addButton(withTitle: primary == nil ? "ОК" : "Отмена")
        if primary != nil { close.keyEquivalent = "\u{1b}" }
        NSApp.activate()
        let response = alert.runModal()
        alertVisible = false
        if primary != nil, response == .alertFirstButtonReturn { action?() }
    }

    @objc private func showSettings() {
        if let settingsWindow {
            NSApp.activate()
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 460, height: 150),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = String(localized: "storage.settings.title")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let heading = NSTextField(labelWithString: String(localized: "storage.folder.title"))
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let path = NSTextField(labelWithString: "")
        path.font = .systemFont(ofSize: 13)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        saveFolderPath = path

        let choose = NSButton(title: String(localized: "storage.folder.choose"), target: self, action: #selector(chooseSaveFolder))
        let reset = NSButton(title: String(localized: "storage.folder.reset"), target: self, action: #selector(resetSaveFolder))
        resetFolderButton = reset
        let buttons = NSStackView(views: [choose, reset])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [heading, path, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: path)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            path.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        window.center()
        settingsWindow = window
        refreshSaveFolder()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func chooseSaveFolder() {
        guard let settingsWindow else { return }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = true
        picker.allowsMultipleSelection = false
        picker.directoryURL = saveDirectory
        picker.prompt = String(localized: "storage.folder.confirm")
        picker.beginSheetModal(for: settingsWindow) { [weak self] result in
            guard result == .OK, let directory = picker.url else { return }
            UserDefaults.standard.set(directory.path, forKey: saveDirectoryKey)
            self?.refreshSaveFolder()
        }
    }

    @objc private func resetSaveFolder() {
        UserDefaults.standard.removeObject(forKey: saveDirectoryKey)
        refreshSaveFolder()
    }

    private func refreshSaveFolder() {
        let path = saveDirectory.path
        saveFolderPath?.stringValue = (path as NSString).abbreviatingWithTildeInPath
        saveFolderPath?.toolTip = path
        resetFolderButton?.isEnabled = customSaveDirectory != nil
    }

    @objc private func showGuide() {
        if let guideWindow {
            refreshGuide()
            NSApp.activate()
            guideWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 278),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = appName
        window.isReleasedWhenClosed = false
        window.delegate = self

        let icon = NSImageView(image: NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 36, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        let title = NSTextField(labelWithString: appName)
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let caption = NSTextField(wrappingLabelWithString: "⌘⇧A — зафиксировать кадр и выделить область. Запись экрана и остальные команды — под значком камеры в строке меню.")
        caption.textColor = .secondaryLabelColor
        let storage = NSTextField(labelWithString: String(localized: "storage.guide"))
        storage.font = .systemFont(ofSize: 12, weight: .medium)
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        guideStatus = status

        let permission = NSButton(title: "Доступ к экрану…", target: self, action: #selector(requestCapturePermission))
        let settings = NSButton(title: String(localized: "storage.settings.menu"), target: self, action: #selector(showSettings))
        let buttons = NSStackView(views: [permission, settings])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [icon, title, caption, storage, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(14, after: caption)
        stack.setCustomSpacing(15, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 23),
            caption.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.contentView = content
        window.center()
        guideWindow = window
        refreshGuide()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func refreshGuide() {
        let login = loginService.status == .enabled ? "Автозапуск включён" : "Автозапуск выключен"
        let shortcut = hotKey == nil ? "⌘⇧A занято" : "⌘⇧A активно"
        guideStatus?.stringValue = "\(login)  ·  \(shortcut)"
    }
}

let app = NSApplication.shared
private let delegate = CaptureApp()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
