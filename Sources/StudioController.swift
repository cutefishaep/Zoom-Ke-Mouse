import Foundation
import AppKit
import SwiftUI
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import CoreGraphics
import CoreMedia
import CoreImage
import IOSurface

public struct DisplayTarget: Identifiable, Equatable {
    public let id: CGDirectDisplayID
    public let name: String
    public let frame: CGRect
    public let pixelSize: CGSize
}

public struct AppWindowTarget: Identifiable, Equatable {
    public let id: CGWindowID
    public let appName: String
    public let windowTitle: String
    public var quartzFrame: CGRect

    public var displayName: String {
        if windowTitle.isEmpty || windowTitle == appName {
            return appName
        }
        let trimmed = windowTitle.count > 30 ? String(windowTitle.prefix(30)) + "…" : windowTitle
        return "\(appName) — \(trimmed)"
    }
}

public enum StudioMode: Equatable {
    case livePreview
    case recording
}

@MainActor
public final class TransportTelemetryModel: ObservableObject {
    @Published public var displayedZoomFactor: CGFloat = 1.0
    @Published public var recordingElapsed: TimeInterval = 0.0
    public init() {}
}

@MainActor
public final class StudioController: NSObject, ObservableObject {

    // MARK: - Published UI State (Persisted to UserDefaults)

    private static let captureModeStorageKey = "com.cutefishaep.zoomkmouse.CaptureTargetMode.v1"
    private static let excludeOwnWindowStorageKey = "com.cutefishaep.zoomkmouse.ExcludeOwnAppWindow.v1"

    @Published public var settings: StudioSettings = StudioSettings.loadSaved() {
        didSet {
            if settings != oldValue {
                settings.save()
                AudioCaptureManager.shared.updateVolumes(
                    systemAudioVolume: settings.systemAudioVolume,
                    micVolume: settings.micAudioVolume
                )
            }
        }
    }
    @Published public var mode: StudioMode = .livePreview
    @Published public var captureTargetMode: CaptureTargetMode = {
        if let raw = UserDefaults.standard.string(forKey: "com.cutefishaep.zoomkmouse.CaptureTargetMode.v1"),
           let saved = CaptureTargetMode(rawValue: raw) {
            return saved
        }
        return .fullScreen
    }() {
        didSet {
            if captureTargetMode != oldValue {
                UserDefaults.standard.set(captureTargetMode.rawValue, forKey: Self.captureModeStorageKey)
            }
        }
    }

    @Published public var availableDisplays: [DisplayTarget] = []
    @Published public var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()

    @Published public var availableAppWindows: [AppWindowTarget] = []
    @Published public var selectedWindowID: CGWindowID = 0

    @Published public var excludeOwnAppWindow: Bool = UserDefaults.standard.bool(forKey: "com.cutefishaep.zoomkmouse.ExcludeOwnAppWindow.v1") {
        didSet {
            if excludeOwnAppWindow != oldValue {
                UserDefaults.standard.set(excludeOwnAppWindow, forKey: Self.excludeOwnWindowStorageKey)
            }
        }
    }
    @Published public var hasScreenCapturePermission: Bool = CGPreflightScreenCaptureAccess()
    @Published public var hasMicrophonePermission: Bool = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)

    @Published public var statusMessage: String = "Siap"
    @Published public var lastSavedVideoURL: URL? = nil

    public let telemetry = TransportTelemetryModel()

    // High-frequency render states (pushed directly to GPU CALayer canvas)
    public var currentFrameIOSurface: IOSurfaceRef? = nil
    public var currentFrameImage: CGImage? = nil
    public var currentSourcePixelSize: CGSize = CGSize(width: 1920, height: 1080)
    public var currentCameraState = CameraRenderState()
    public var currentCursorState = CursorRenderState()

    private weak var canvasView: StudioRenderNSView?

    // MARK: - Internal Engine Properties

    private let cameraEngine = ZoomCameraEngine()
    private let directRecorder = RealTimeDirectMovieRecorder()

    private var liveTimer: Timer?
    private var lastTickTimestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var lastUIUpdateTimestamp: TimeInterval = 0
    private var lastPermissionCheckTimestamp: TimeInterval = 0
    private var lastWindowBoundsUpdateTimestamp: TimeInterval = 0
    private var recordingStartUptime: TimeInterval = 0

    // Live tracked bounds of the currently selected App Window (in global Quartz coordinates)
    private var activeAppWindowQuartzBounds: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 800)

    // Live click history
    private var liveRecentClicks: [ClickEvent] = []
    private var wasLeftMouseDown: Bool = false
    private var wasRightMouseDown: Bool = false
    private var globalMouseMonitor: Any?

    // ScreenCaptureKit Zero-Copy IOSurface Stream
    private var scStream: SCStream?
    private let scOutputQueue = DispatchQueue(label: "com.cutefishaep.zoomkmouse.scstream", qos: .userInteractive)
    private var streamOutputHandler: SCStreamZeroCopyHandler?
    private var isSCStreamActive: Bool = false

    // CoreGraphics CGDisplayStream Zero-Copy GPU IOSurface Fallback
    private let displayStreamCapturer = CGDisplayStreamZeroCopyCapturer()

    // Single-Window Fallback Capturer (when SCStream is unavailable)
    private let windowFallbackCapturer = BackgroundWindowCapturer()

    public override init() {
        super.init()
        let preflight = CGPreflightScreenCaptureAccess()
        self.hasScreenCapturePermission = preflight
        if !preflight {
            CGRequestScreenCaptureAccess()
        }
        _ = DesktopWallpaperHelper.currentMacWallpaperImage()
        refreshDisplaysAndWindows()
        setupMouseMonitors()
        startLiveLoop()
        startScreenCaptureStream()
    }

    public func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    public func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    public func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    public func revealLastSavedVideo() {
        guard let url = lastSavedVideoURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func attachCanvasView(_ view: StudioRenderNSView) {
        self.canvasView = view
    }

    private func pushToGPUCanvas() {
        canvasView?.pushGPUFrame(
            ioSurface: currentFrameIOSurface,
            fallbackCGImage: currentFrameImage,
            pixelSize: currentSourcePixelSize,
            camera: currentCameraState,
            cursor: currentCursorState,
            settings: settings
        )
    }

    // MARK: - Display & Application Window Enumeration

    private func refreshDisplaysOnly() {
        var targets: [DisplayTarget] = []
        for (idx, screen) in NSScreen.screens.enumerated() {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = CGDirectDisplayID(num.uint32Value)
            let scale = screen.backingScaleFactor
            let pixelSize = CGSize(
                width: max(1280, screen.frame.width * scale),
                height: max(720, screen.frame.height * scale)
            )
            let name = screen.localizedName.isEmpty ? "Layar \(idx + 1)" : screen.localizedName
            targets.append(
                DisplayTarget(
                    id: displayID,
                    name: "\(name) (\(Int(screen.frame.width))×\(Int(screen.frame.height)))",
                    frame: screen.frame,
                    pixelSize: pixelSize
                )
            )
        }

        if targets.isEmpty {
            let mainID = CGMainDisplayID()
            let w = CGFloat(CGDisplayPixelsWide(mainID))
            let h = CGFloat(CGDisplayPixelsHigh(mainID))
            targets.append(
                DisplayTarget(
                    id: mainID,
                    name: "Main Display (\(Int(w))×\(Int(h)))",
                    frame: CGRect(x: 0, y: 0, width: w, height: h),
                    pixelSize: CGSize(width: max(1280, w), height: max(720, h))
                )
            )
        }

        self.availableDisplays = targets
        if !targets.contains(where: { $0.id == selectedDisplayID }), let first = targets.first {
            selectedDisplayID = first.id
        }
    }

    private func refreshCGWindowsFallback() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let skipApps: Set<String> = [
            "Window Server", "Dock", "Control Center", "SystemUIServer",
            "Notification Center", "Spotlight", "TextInputMenuAgent", "WindowManager"
        ]
        guard let infoList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        let regularPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.processIdentifier != myPID }
                .map { $0.processIdentifier }
        )

        var winTargets: [AppWindowTarget] = []
        var seenApps = Set<pid_t>()

        for entry in infoList {
            guard let pidNum = entry[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let ownerPID = pid_t(pidNum.int32Value)
            guard ownerPID != myPID else { continue }

            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }

            guard let winNum = entry[kCGWindowNumber as String] as? NSNumber else { continue }
            let winID = CGWindowID(winNum.uint32Value)

            let appName = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            guard !appName.isEmpty, !skipApps.contains(appName) else { continue }

            let isOnScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.05 else { continue }

            var rect = CGRect(x: 0, y: 0, width: 1280, height: 800)
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
               let parsed = CGRect(dictionaryRepresentation: boundsDict) {
                rect = parsed
            }
            guard rect.width >= 160 && rect.height >= 120 else { continue }

            if !isOnScreen && (!regularPIDs.contains(ownerPID) || seenApps.contains(ownerPID)) {
                continue
            }
            seenApps.insert(ownerPID)

            let title = (entry[kCGWindowName as String] as? String) ?? ""
            winTargets.append(
                AppWindowTarget(
                    id: winID,
                    appName: appName,
                    windowTitle: title,
                    quartzFrame: rect
                )
            )
        }

        if !winTargets.isEmpty {
            self.availableAppWindows = winTargets
            if !winTargets.contains(where: { $0.id == self.selectedWindowID }),
               let firstWin = winTargets.first {
                self.selectedWindowID = firstWin.id
                self.activeAppWindowQuartzBounds = firstWin.quartzFrame
            } else if let current = winTargets.first(where: { $0.id == self.selectedWindowID }) {
                self.activeAppWindowQuartzBounds = current.quartzFrame
            }
        }
    }

    /// Queries the live on-screen Quartz frame of `selectedWindowID` so even if the user moves/resizes the target app window, zoom & cursor stay 100% aligned!
    private func updateLiveSelectedWindowBounds() {
        guard captureTargetMode == .appWindow, selectedWindowID != 0 else { return }
        guard let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], selectedWindowID) as? [[String: Any]],
              let entry = infoList.first,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict),
              rect.width > 40, rect.height > 40 else {
            return
        }
        activeAppWindowQuartzBounds = rect
    }

    public func refreshDisplaysAndWindows() {
        refreshDisplaysOnly()
        refreshCGWindowsFallback()

        let myPID = ProcessInfo.processInfo.processIdentifier
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }
            if let content = content, error == nil {
                let winTargets = Self.extractAppWindowTargets(from: content, excludingPID: myPID)
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let wasDenied = !self.hasScreenCapturePermission
                    self.hasScreenCapturePermission = true
                    if !winTargets.isEmpty {
                        self.availableAppWindows = winTargets
                        if !winTargets.contains(where: { $0.id == self.selectedWindowID }),
                           let firstWin = winTargets.first {
                            self.selectedWindowID = firstWin.id
                            self.activeAppWindowQuartzBounds = firstWin.quartzFrame
                        } else if let current = winTargets.first(where: { $0.id == self.selectedWindowID }) {
                            self.activeAppWindowQuartzBounds = current.quartzFrame
                        }
                    }
                    if wasDenied && !self.isSCStreamActive && self.scStream == nil {
                        self.restartScreenCaptureStream()
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.hasScreenCapturePermission = CGPreflightScreenCaptureAccess()
                }
            }
        }
    }

    nonisolated private static func extractAppWindowTargets(from content: SCShareableContent, excludingPID myPID: pid_t) -> [AppWindowTarget] {
        let skipApps: Set<String> = ["Window Server", "Dock", "Control Center", "SystemUIServer", "Notification Center"]
        var winTargets: [AppWindowTarget] = []
        for win in content.windows {
            guard let app = win.owningApplication,
                  app.processID != myPID,
                  win.isOnScreen,
                  win.frame.width >= 200,
                  win.frame.height >= 140,
                  !app.applicationName.isEmpty,
                  !skipApps.contains(app.applicationName) else {
                continue
            }
            winTargets.append(
                AppWindowTarget(
                    id: win.windowID,
                    appName: app.applicationName,
                    windowTitle: win.title ?? "",
                    quartzFrame: win.frame
                )
            )
        }
        return winTargets
    }

    public func refreshDisplays() {
        refreshDisplaysAndWindows()
    }

    public func selectDisplay(_ displayID: CGDirectDisplayID) {
        guard selectedDisplayID != displayID else { return }
        selectedDisplayID = displayID
        DesktopWallpaperHelper.refreshCache()
        restartScreenCaptureStream()
    }

    public func selectCaptureTargetMode(_ newMode: CaptureTargetMode) {
        guard captureTargetMode != newMode else { return }
        captureTargetMode = newMode
        refreshCGWindowsFallback()
        updateLiveSelectedWindowBounds()
        restartScreenCaptureStream()
    }

    public func selectAppWindow(_ windowID: CGWindowID) {
        guard selectedWindowID != windowID else { return }
        selectedWindowID = windowID
        if let target = availableAppWindows.first(where: { $0.id == windowID }) {
            activeAppWindowQuartzBounds = target.quartzFrame
        }
        updateLiveSelectedWindowBounds()
        restartScreenCaptureStream()
    }

    // MARK: - Single Active Zero-Copy GPU IOSurface Capture

    public func restartScreenCaptureStream() {
        stopScreenCaptureStream()
        startScreenCaptureStream()
    }

    public func startScreenCaptureStream() {
        let targetDisplayID = selectedDisplayID
        let targetWindowID = selectedWindowID
        let targetMode = captureTargetMode
        let excludeSelf = excludeOwnAppWindow
        let myPID = ProcessInfo.processInfo.processIdentifier

        let dispBounds = CGDisplayBounds(targetDisplayID)
        let dispW = max(1280.0, dispBounds.width)
        let dispH = max(720.0, dispBounds.height)
        let hdScale = min(1.0, 1920.0 / max(dispW, dispH))
        let fullHDW = max(640, Int(round(dispW * hdScale / 2.0) * 2.0))
        let fullHDH = max(360, Int(round(dispH * hdScale / 2.0) * 2.0))

        let targetCapturerW: Int
        let targetCapturerH: Int
        switch settings.videoResolution {
        case .native:
            targetCapturerW = max(640, Int(round(dispW / 2.0) * 2.0))
            targetCapturerH = max(360, Int(round(dispH / 2.0) * 2.0))
        case .fhd1080p:
            targetCapturerW = fullHDW
            targetCapturerH = fullHDH
        }

        if targetMode == .appWindow {
            // Use CGWindowListCreateImage(.boundsIgnoreFraming) for App Window capture so there is ZERO shadow border around the window and zoom/cursor coordinates match the window 1:1!
            displayStreamCapturer.stop()
            windowFallbackCapturer.configure(windowID: targetWindowID)
            windowFallbackCapturer.setActive(true)
            return
        }

        // On NootedRed.kext (AMD Radeon RX Picasso 30-bit ARGB2101010 framebuffer), CGDisplayStream reads the
        // display framebuffer directly without forcing WindowServer to run a second offscreen desktop composition pass!
        if targetMode == .fullScreen && (!excludeSelf || !hasScreenCapturePermission) {
            windowFallbackCapturer.setActive(false)
            displayStreamCapturer.start(
                displayID: targetDisplayID,
                width: targetCapturerW,
                height: targetCapturerH
            )
            return
        }

        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            guard let self = self else { return }
            guard let content = content, error == nil else {
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.hasScreenCapturePermission = false
                    self.isSCStreamActive = false
                    if targetMode == .fullScreen && !self.displayStreamCapturer.isRunning {
                        self.displayStreamCapturer.start(
                            displayID: targetDisplayID,
                            width: targetCapturerW,
                            height: targetCapturerH
                        )
                    } else if targetMode == .appWindow {
                        self.windowFallbackCapturer.configure(windowID: targetWindowID)
                        self.windowFallbackCapturer.setActive(true)
                    }
                }
                return
            }

            let winTargets = Self.extractAppWindowTargets(from: content, excludingPID: myPID)

            let filter: SCContentFilter
            let rawWidth: CGFloat
            let rawHeight: CGFloat
            var chosenWinID: CGWindowID? = nil
            var chosenWinFrame: CGRect? = nil

            if targetMode == .appWindow,
               let scWin = content.windows.first(where: { $0.windowID == targetWindowID })
                ?? content.windows.first(where: { $0.frame.width >= 200 && $0.owningApplication?.processID != myPID }) {
                filter = SCContentFilter(desktopIndependentWindow: scWin)
                rawWidth = max(320, scWin.frame.width)
                rawHeight = max(240, scWin.frame.height)
                chosenWinID = scWin.windowID
                chosenWinFrame = scWin.frame
            } else {
                guard let scDisplay = content.displays.first(where: { $0.displayID == targetDisplayID }) ?? content.displays.first else {
                    return
                }
                let excludedApps: [SCRunningApplication] = excludeSelf
                    ? content.applications.filter { $0.processID == myPID }
                    : []
                filter = SCContentFilter(display: scDisplay, excludingApplications: excludedApps, exceptingWindows: [])
                rawWidth = CGFloat(scDisplay.width)
                rawHeight = CGFloat(scDisplay.height)
            }

            let captureW: Int
            let captureH: Int
            switch self.settings.videoResolution {
            case .native:
                captureW = max(320, Int(round(rawWidth / 2.0) * 2.0))
                captureH = max(240, Int(round(rawHeight / 2.0) * 2.0))
            case .fhd1080p:
                let maxCaptureEdge: CGFloat = 1920.0
                let scale = min(1.0, maxCaptureEdge / max(1.0, max(rawWidth, rawHeight)))
                captureW = max(320, Int(round(rawWidth * scale / 2.0) * 2.0))
                captureH = max(240, Int(round(rawHeight * scale / 2.0) * 2.0))
            }

            let fps = self.settings.videoFrameRate.rawValue
            let config = SCStreamConfiguration()
            config.width = captureW
            config.height = captureH
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            config.queueDepth = 4
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true

            let handler = SCStreamZeroCopyHandler()

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(handler, type: .screen, sampleHandlerQueue: self.scOutputQueue)
                try stream.addStreamOutput(handler, type: .audio, sampleHandlerQueue: self.scOutputQueue)
                stream.startCapture { [weak self] err in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let ok = (err == nil)
                        self.isSCStreamActive = ok
                        self.hasScreenCapturePermission = ok
                        if ok {
                            self.displayStreamCapturer.stop()
                            self.windowFallbackCapturer.setActive(false)
                        } else if targetMode == .fullScreen && !self.displayStreamCapturer.isRunning {
                            self.displayStreamCapturer.start(
                                displayID: targetDisplayID,
                                width: targetCapturerW,
                                height: targetCapturerH
                            )
                        } else if targetMode == .appWindow {
                            self.windowFallbackCapturer.configure(windowID: chosenWinID ?? targetWindowID)
                            self.windowFallbackCapturer.setActive(true)
                        }
                    }
                }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.hasScreenCapturePermission = true
                    if !winTargets.isEmpty {
                        self.availableAppWindows = winTargets
                    }
                    if let wid = chosenWinID {
                        self.selectedWindowID = wid
                    }
                    if let wFrame = chosenWinFrame {
                        self.activeAppWindowQuartzBounds = wFrame
                    }
                    self.streamOutputHandler = handler
                    self.scStream = stream
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.isSCStreamActive = false
                }
            }
        }
    }

    public func stopScreenCaptureStream() {
        isSCStreamActive = false
        displayStreamCapturer.stop()
        windowFallbackCapturer.setActive(false)
        if let stream = scStream {
            stream.stopCapture(completionHandler: nil)
        }
        scStream = nil
        streamOutputHandler = nil
    }

    // MARK: - Global Mouse Tracking (Never interferes with clicking UI buttons inside our own window!)

    private func setupMouseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self = self else { return }
            let isRight = (event.type == .rightMouseDown)
            Task { @MainActor in
                self.registerMouseClick(isRightClick: isRight)
            }
        }
    }

    private func currentNormalizedMousePosition() -> CGPoint {
        let mouseLoc = NSEvent.mouseLocation

        if captureTargetMode == .appWindow {
            let winBounds = activeAppWindowQuartzBounds
            guard winBounds.width > 10 && winBounds.height > 10 else {
                return CGPoint(x: 0.5, y: 0.5)
            }
            // Quartz global coordinates have (0,0) at top-left of the primary display (screen with origin 0,0)
            let primaryScreenHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                ?? NSScreen.screens.first?.frame.height
                ?? CGFloat(CGDisplayPixelsHigh(CGMainDisplayID()))

            let mouseQuartzX = mouseLoc.x
            let mouseQuartzY = primaryScreenHeight - mouseLoc.y

            let nx = (mouseQuartzX - winBounds.minX) / winBounds.width
            let ny = (mouseQuartzY - winBounds.minY) / winBounds.height
            return ZoomCameraEngine.clampNormalized(CGPoint(x: nx, y: ny))
        }

        let displayFrame: CGRect
        if let target = availableDisplays.first(where: { $0.id == selectedDisplayID }) {
            displayFrame = target.frame
        } else if let mainScreen = NSScreen.main {
            displayFrame = mainScreen.frame
        } else {
            displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        }

        guard displayFrame.width > 0 && displayFrame.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let nx = (mouseLoc.x - displayFrame.minX) / displayFrame.width
        let ny = (displayFrame.maxY - mouseLoc.y) / displayFrame.height
        return ZoomCameraEngine.clampNormalized(CGPoint(x: nx, y: ny))
    }

    public func registerMouseClick(at customLocation: CGPoint? = nil, isRightClick: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        if captureTargetMode == .appWindow && customLocation == nil {
            updateLiveSelectedWindowBounds()
        }
        let loc = customLocation ?? currentNormalizedMousePosition()

        if let last = liveRecentClicks.last, (now - last.timestamp) < 0.06 {
            return
        }

        let liveClick = ClickEvent(timestamp: now, location: loc, isRightClick: isRightClick)
        liveRecentClicks.append(liveClick)
        if liveRecentClicks.count > 20 {
            liveRecentClicks.removeFirst(liveRecentClicks.count - 20)
        }

        cameraEngine.triggerLiveClick(at: loc, now: now, settings: settings)
    }

    public func triggerDemoClick() {
        let samplePoints: [CGPoint] = [
            CGPoint(x: 0.25, y: 0.28),
            CGPoint(x: 0.75, y: 0.25),
            CGPoint(x: 0.30, y: 0.72),
            CGPoint(x: 0.72, y: 0.75),
            CGPoint(x: 0.50, y: 0.45)
        ]
        let chosen = samplePoints.randomElement() ?? CGPoint(x: 0.35, y: 0.35)
        registerMouseClick(at: chosen, isRightClick: false)
    }

    // MARK: - Main Studio Loop (Tuned for NootedRed.kext)

    private func startLiveLoop() {
        liveTimer?.invalidate()
        lastTickTimestamp = ProcessInfo.processInfo.systemUptime

        let timer = Timer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(handleLiveTimerTick(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    @objc private func handleLiveTimerTick(_ timer: Timer) {
        tickStudioLoop()
    }

    private func tickStudioLoop() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(1.0 / 240.0, min(0.05, now - lastTickTimestamp))
        lastTickTimestamp = now

        if !hasScreenCapturePermission && mode == .livePreview && (now - lastPermissionCheckTimestamp) >= 2.0 {
            lastPermissionCheckTimestamp = now
            refreshDisplaysAndWindows()
        }

        // Keep selected App Window bounds updated at 5Hz so moving the target window stays 100% aligned
        if captureTargetMode == .appWindow && (now - lastWindowBoundsUpdateTimestamp) >= 0.20 {
            lastWindowBoundsUpdateTimestamp = now
            updateLiveSelectedWindowBounds()
        }

        if let handler = streamOutputHandler, let (surface, size) = handler.pollLatestSurface() {
            if !isSCStreamActive {
                isSCStreamActive = true
                hasScreenCapturePermission = true
                displayStreamCapturer.stop()
                windowFallbackCapturer.setActive(false)
            }
            currentFrameIOSurface = surface
            currentSourcePixelSize = size
        } else if let (surface, size) = displayStreamCapturer.pollLatestSurface() {
            currentFrameIOSurface = surface
            currentSourcePixelSize = size
        } else if let (winImg, size) = windowFallbackCapturer.pollLatestImage() {
            currentFrameIOSurface = nil
            currentFrameImage = winImg
            currentSourcePixelSize = size
        }

        let pressedMask = NSEvent.pressedMouseButtons
        let isLeftDown = (pressedMask & 1) != 0
        let isRightDown = (pressedMask & 2) != 0

        // Do not trigger auto-zoom when clicking buttons inside our own ZoomKeMouse studio window!
        let ignoreOwnWindowClick = NSApp.isActive
        if !ignoreOwnWindowClick {
            if isLeftDown && !wasLeftMouseDown {
                registerMouseClick(isRightClick: false)
            } else if isRightDown && !wasRightMouseDown {
                registerMouseClick(isRightClick: true)
            }
        }
        wasLeftMouseDown = isLeftDown
        wasRightMouseDown = isRightDown

        let rawMouse = currentNormalizedMousePosition()
        liveRecentClicks.removeAll { (now - $0.timestamp) > 2.0 }

        let (cam, cur) = cameraEngine.stepLive(
            dt: dt,
            rawMouse: rawMouse,
            isLeftDown: isLeftDown,
            isRightDown: isRightDown,
            recentClicks: liveRecentClicks,
            now: now,
            settings: settings
        )
        currentCameraState = cam
        currentCursorState = cur

        pushToGPUCanvas()

        if mode == .recording {
            directRecorder.appendLiveCompositedFrame(
                ioSurface: currentFrameIOSurface,
                fallbackCGImage: currentFrameImage,
                uptime: now,
                camera: cam,
                cursor: cur,
                settings: settings
            )
        }

        if (now - lastUIUpdateTimestamp) >= 0.25 {
            lastUIUpdateTimestamp = now
            if abs(telemetry.displayedZoomFactor - cam.zoom) > 0.02 {
                telemetry.displayedZoomFactor = cam.zoom
            }
            if mode == .recording {
                telemetry.recordingElapsed = max(0.0, now - recordingStartUptime)
            }
        }
    }

    // MARK: - Real-Time Recording Control (Instant Save on Stop!)

    public func toggleRecording() {
        switch mode {
        case .recording:
            stopRecordingAndSaveImmediately()
        case .livePreview:
            startRecording()
        }
    }

    public func startRecording() {
        if scStream == nil && !displayStreamCapturer.isRunning {
            startScreenCaptureStream()
        }

        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        let saveFolder = moviesDir.appendingPathComponent("ZoomKeMouse", isDirectory: true)
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ext = settings.videoCodec.isMOV ? "mov" : "mp4"
        let fileName = "Rekaman_\(formatter.string(from: Date())).\(ext)"
        let outputURL = saveFolder.appendingPathComponent(fileName)

        let now = ProcessInfo.processInfo.systemUptime
        recordingStartUptime = now
        telemetry.recordingElapsed = 0.0

        let started = directRecorder.startRecording(
            outputURL: outputURL,
            sourceSize: currentSourcePixelSize,
            settings: settings,
            startUptime: now
        )

        guard started else {
            statusMessage = "Gagal memulai perekam"
            return
        }

        AudioCaptureManager.shared.delegate = directRecorder
        try? AudioCaptureManager.shared.startCapture(
            systemAudioEnabled: settings.isSystemAudioEnabled,
            systemAudioVolume: settings.systemAudioVolume,
            micAudioEnabled: settings.isMicAudioEnabled,
            micDeviceUID: settings.micDeviceUID,
            micVolume: settings.micAudioVolume
        )

        // Write initial frame at t = 0.0s
        directRecorder.appendLiveCompositedFrame(
            ioSurface: currentFrameIOSurface,
            fallbackCGImage: currentFrameImage,
            uptime: now,
            camera: currentCameraState,
            cursor: currentCursorState,
            settings: settings,
            force: true
        )

        mode = .recording
        statusMessage = "Merekam..."
    }

    public func stopRecordingAndSaveImmediately() {
        guard mode == .recording else { return }
        let now = ProcessInfo.processInfo.systemUptime

        AudioCaptureManager.shared.stopCapture()

        // Append final frame
        directRecorder.appendLiveCompositedFrame(
            ioSurface: currentFrameIOSurface,
            fallbackCGImage: currentFrameImage,
            uptime: now,
            camera: currentCameraState,
            cursor: currentCursorState,
            settings: settings,
            force: true
        )

        mode = .livePreview
        statusMessage = "Menyimpan..."

        directRecorder.stopRecording { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let url):
                    self.lastSavedVideoURL = url
                    self.statusMessage = "Tersimpan: \(url.lastPathComponent)"
                    // Immediately reveal the saved video in Finder!
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let err):
                    self.statusMessage = "Gagal: \(err.localizedDescription)"
                }
            }
        }
    }

    public func chooseCustomBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "Pilih Gambar Background"
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.customBackgroundImageURL = url
            settings.backgroundType = .customImage
            canvasView?.updateLayoutAndSettings(settings: settings, force: true)
        }
    }
}

// MARK: - CoreGraphics CGDisplayStream 60fps Zero-Copy GPU IOSurface Capturer

private final class CGDisplayStreamZeroCopyCapturer {
    private let queue = DispatchQueue(label: "com.zoomkemouse.cgdisplaystream", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: CGDisplayStream?
    private var latestSurface: IOSurfaceRef?
    private var latestSize: CGSize = .zero
    private var hasUnreadSurface: Bool = false
    private(set) var isRunning: Bool = false

    func start(displayID: CGDirectDisplayID, width: Int, height: Int) {
        stop()

        let props: [CFString: Any] = [
            CGDisplayStream.showCursor: false,
            CGDisplayStream.minimumFrameTime: 1.0 / 60.0,
            CGDisplayStream.queueDepth: 4
        ]

        let newStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: width,
            outputHeight: height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: props as CFDictionary,
            queue: queue
        ) { [weak self] status, _, frameSurface, _ in
            guard let self = self,
                  status == .frameComplete,
                  let surface = frameSurface else {
                return
            }

            let size = CGSize(
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface)
            )
            self.lock.lock()
            self.latestSurface = surface
            self.latestSize = size
            self.hasUnreadSurface = true
            self.lock.unlock()
        }

        if let s = newStream, s.start() == .success {
            lock.lock()
            self.stream = s
            self.isRunning = true
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        let oldStream = stream
        stream = nil
        isRunning = false
        hasUnreadSurface = false
        lock.unlock()

        oldStream?.stop()
    }

    func pollLatestSurface() -> (IOSurfaceRef, CGSize)? {
        lock.lock()
        defer { lock.unlock() }
        guard hasUnreadSurface, let surf = latestSurface else { return nil }
        hasUnreadSurface = false
        return (surf, latestSize)
    }
}

// MARK: - ScreenCaptureKit Zero-Copy IOSurface Handler

private final class SCStreamZeroCopyHandler: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var latestSurface: IOSurfaceRef?
    private var latestSize: CGSize = .zero
    private var hasUnreadSurface: Bool = false

    func pollLatestSurface() -> (IOSurfaceRef, CGSize)? {
        lock.lock()
        defer { lock.unlock() }
        guard hasUnreadSurface, let surf = latestSurface else { return nil }
        hasUnreadSurface = false
        return (surf, latestSize)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid {
                AudioCaptureManager.shared.handleSystemAudioSampleBuffer(sampleBuffer)
            }
            return
        }

        guard type == .screen,
              sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let ioSurface = CVPixelBufferGetIOSurface(imageBuffer)?.takeUnretainedValue() else {
            return
        }

        let size = CGSize(
            width: IOSurfaceGetWidth(ioSurface),
            height: IOSurfaceGetHeight(ioSurface)
        )
        lock.lock()
        latestSurface = ioSurface
        latestSize = size
        hasUnreadSurface = true
        lock.unlock()
    }
}

// MARK: - Single-Window Capturer Fallback

private final class BackgroundWindowCapturer {
    private let queue = DispatchQueue(label: "com.zoomkemouse.winfallback", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var windowID: CGWindowID = 0
    private var isActive: Bool = false
    private var latestImage: CGImage?
    private var latestSize: CGSize = .zero
    private var hasUnread: Bool = false

    init() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(33), leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in
            self?.captureTick()
        }
        t.resume()
        self.timer = t
    }

    func configure(windowID: CGWindowID) {
        lock.lock()
        self.windowID = windowID
        lock.unlock()
    }

    func setActive(_ active: Bool) {
        lock.lock()
        self.isActive = active
        lock.unlock()
    }

    func pollLatestImage() -> (CGImage, CGSize)? {
        lock.lock()
        defer { lock.unlock() }
        guard hasUnread, let img = latestImage else { return nil }
        hasUnread = false
        return (img, latestSize)
    }

    private func captureTick() {
        lock.lock()
        let active = isActive
        let winID = windowID
        lock.unlock()

        guard active, winID != 0 else { return }

        autoreleasepool {
            guard let cgImg = CGWindowListCreateImage(.null, .optionIncludingWindow, winID, [.boundsIgnoreFraming, .bestResolution]),
                  cgImg.width > 16, cgImg.height > 16 else {
                return
            }
            let size = CGSize(width: cgImg.width, height: cgImg.height)

            lock.lock()
            latestImage = cgImg
            latestSize = size
            hasUnread = true
            lock.unlock()
        }
    }
}

// MARK: - Audio Device Discovery Compatibility Extension
extension AudioCaptureManager {
    public func availableDevices() -> [AudioDeviceInfo] {
        return availableMicrophoneDevices()
    }
}
