import Foundation
import SwiftUI
import AppKit
import AVFoundation

// MARK: - Coordinate & Color Helpers

public struct RGBAColor: Equatable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public init(nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.r = Double(converted.redComponent)
        self.g = Double(converted.greenComponent)
        self.b = Double(converted.blueComponent)
        self.a = Double(converted.alphaComponent)
    }

    public var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
    }
}

// MARK: - App Language (Indonesian / English)

public enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case id = "id"
    case en = "en"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .id: return "🇮🇩 Indonesia"
        case .en: return "🇺🇸 English"
        }
    }

    public var shortLabel: String {
        switch self {
        case .id: return "ID"
        case .en: return "EN"
        }
    }
}

// MARK: - Enums & Presets

public enum BackgroundType: String, CaseIterable, Identifiable, Codable {
    case macWallpaper = "Wallpaper Mac"
    case gradient = "Gradasi"
    case solidColor = "Warna Solid"
    case customImage = "Gambar Lain"

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.macWallpaper, .id): return "Wallpaper Mac"
        case (.macWallpaper, .en): return "Mac Wallpaper"
        case (.gradient, .id): return "Gradasi"
        case (.gradient, .en): return "Gradient"
        case (.solidColor, .id): return "Warna Solid"
        case (.solidColor, .en): return "Solid Color"
        case (.customImage, .id): return "Gambar Lain"
        case (.customImage, .en): return "Custom Image"
        }
    }
}

public enum DesktopWallpaperHelper {
    private static var cachedImage: CGImage?
    private static var cachedURL: URL?

    public static func currentMacWallpaperImage(for displayID: CGDirectDisplayID = CGMainDisplayID()) -> CGImage? {
        let targetScreen = NSScreen.screens.first { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(num.uint32Value) == displayID
        } ?? NSScreen.main ?? NSScreen.screens.first

        if let screen = targetScreen,
           let url = NSWorkspace.shared.desktopImageURL(for: screen) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    if cachedURL == url, let img = cachedImage {
                        return img
                    }
                    if let nsImg = NSImage(contentsOf: url),
                       let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        cachedURL = url
                        cachedImage = cgImg
                        return cgImg
                    }
                } else {
                    // Directory path fallback: pick first image inside directory
                    if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        if let imgURL = items.first(where: { ["heic", "jpg", "jpeg", "png", "tiff"].contains($0.pathExtension.lowercased()) }) {
                            if cachedURL == imgURL, let img = cachedImage {
                                return img
                            }
                            if let nsImg = NSImage(contentsOf: imgURL),
                               let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                                cachedURL = imgURL
                                cachedImage = cgImg
                                return cgImg
                            }
                        }
                    }
                }
            }
        }

        if let img = cachedImage {
            return img
        }

        let fallbackPaths = [
            "/System/Library/Desktop Pictures/Ventura Graphic.heic",
            "/System/Library/Desktop Pictures/Monterey Graphic.heic",
            "/System/Library/Desktop Pictures/Big Sur Graphic.heic",
            "/System/Library/Desktop Pictures/Solid Colors/Stone.png"
        ]
        for path in fallbackPaths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path),
               let nsImg = NSImage(contentsOf: url),
               let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                cachedURL = url
                cachedImage = cgImg
                return cgImg
            }
        }
        return nil
    }

    public static func refreshCache() {
        cachedURL = nil
        cachedImage = nil
    }
}

public struct GradientPreset: Identifiable {
    public let id: Int
    public let name: String
    public let colors: [RGBAColor]
    public let startPoint: CGPoint // 0..1
    public let endPoint: CGPoint   // 0..1

    public static let allPresets: [GradientPreset] = [
        GradientPreset(
            id: 0,
            name: "Sonoma Aurora",
            colors: [
                RGBAColor(r: 0.16, g: 0.11, b: 0.48),
                RGBAColor(r: 0.42, g: 0.16, b: 0.65),
                RGBAColor(r: 0.89, g: 0.35, b: 0.54)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 1.0, y: 1.0)
        ),
        GradientPreset(
            id: 1,
            name: "Ocean Breeze",
            colors: [
                RGBAColor(r: 0.05, g: 0.22, b: 0.46),
                RGBAColor(r: 0.08, g: 0.56, b: 0.78),
                RGBAColor(r: 0.36, g: 0.88, b: 0.84)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.1),
            endPoint: CGPoint(x: 1.0, y: 0.9)
        ),
        GradientPreset(
            id: 2,
            name: "Sunset Flame",
            colors: [
                RGBAColor(r: 0.48, g: 0.09, b: 0.32),
                RGBAColor(r: 0.88, g: 0.25, b: 0.28),
                RGBAColor(r: 0.99, g: 0.68, b: 0.24)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 1.0, y: 1.0)
        ),
        GradientPreset(
            id: 3,
            name: "Midnight Studio",
            colors: [
                RGBAColor(r: 0.07, g: 0.08, b: 0.13),
                RGBAColor(r: 0.14, g: 0.17, b: 0.27),
                RGBAColor(r: 0.09, g: 0.10, b: 0.16)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 1.0, y: 1.0)
        ),
        GradientPreset(
            id: 4,
            name: "Emerald Forest",
            colors: [
                RGBAColor(r: 0.04, g: 0.27, b: 0.24),
                RGBAColor(r: 0.11, g: 0.58, b: 0.46),
                RGBAColor(r: 0.52, g: 0.89, b: 0.63)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 1.0, y: 1.0)
        ),
        GradientPreset(
            id: 5,
            name: "Cyber Neon",
            colors: [
                RGBAColor(r: 0.07, g: 0.03, b: 0.22),
                RGBAColor(r: 0.35, g: 0.08, b: 0.68),
                RGBAColor(r: 0.00, g: 0.82, b: 0.95)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.2),
            endPoint: CGPoint(x: 1.0, y: 0.8)
        ),
        GradientPreset(
            id: 6,
            name: "Warm Peach",
            colors: [
                RGBAColor(r: 0.95, g: 0.56, b: 0.67),
                RGBAColor(r: 0.98, g: 0.75, b: 0.58),
                RGBAColor(r: 0.99, g: 0.90, b: 0.76)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 1.0, y: 1.0)
        ),
        GradientPreset(
            id: 7,
            name: "Clean Silver",
            colors: [
                RGBAColor(r: 0.85, g: 0.88, b: 0.93),
                RGBAColor(r: 0.94, g: 0.95, b: 0.98),
                RGBAColor(r: 0.78, g: 0.82, b: 0.89)
            ],
            startPoint: CGPoint(x: 0.0, y: 0.0),
            endPoint: CGPoint(x: 1.0, y: 1.0)
        )
    ]
}

public enum CanvasAspectRatio: String, CaseIterable, Identifiable, Codable {
    case original = "Auto (Screen)"
    case widescreen16x9 = "16:9 (YouTube)"
    case mac16x10 = "16:10 (Mac)"
    case vertical9x16 = "9:16 (Reels/Shorts)"
    case square1x1 = "1:1 (Square)"
    case classic4x3 = "4:3 (Classic)"

    public var id: String { rawValue }

    public func outputSize(forSource sourceSize: CGSize, maxLongEdge: CGFloat = 1920) -> CGSize {
        let safeSource = CGSize(
            width: max(sourceSize.width, 640),
            height: max(sourceSize.height, 360)
        )
        let ratio: CGFloat
        switch self {
        case .original:
            ratio = safeSource.width / safeSource.height
        case .widescreen16x9:
            ratio = 16.0 / 9.0
        case .mac16x10:
            ratio = 16.0 / 10.0
        case .vertical9x16:
            ratio = 9.0 / 16.0
        case .square1x1:
            ratio = 1.0
        case .classic4x3:
            ratio = 4.0 / 3.0
        }

        if ratio >= 1.0 {
            let width = round(maxLongEdge / 2.0) * 2.0
            let height = round((width / ratio) / 2.0) * 2.0
            return CGSize(width: width, height: height)
        } else {
            let height = round(maxLongEdge / 2.0) * 2.0
            let width = round((height * ratio) / 2.0) * 2.0
            return CGSize(width: width, height: height)
        }
    }
}

public enum ZoomSpeedPreset: String, CaseIterable, Identifiable, Codable {
    case slow = "Slow & Cinematic"
    case mellow = "Smooth Studio"
    case snappy = "Snappy"
    case instant = "Rapid"

    public var id: String { rawValue }

    /// Transition duration in seconds for zoom in / zoom out
    public var transitionDuration: Double {
        switch self {
        case .slow: return 0.65
        case .mellow: return 0.42
        case .snappy: return 0.25
        case .instant: return 0.14
        }
    }

    /// Exponential smoothing rate for live camera
    public var liveSpringSpeed: CGFloat {
        switch self {
        case .slow: return 4.5
        case .mellow: return 7.5
        case .snappy: return 12.0
        case .instant: return 20.0
        }
    }
}

public enum CursorStyle: String, CaseIterable, Identifiable, Codable {
    case macOSPointer = "Panah macOS"
    case touchCircle = "iOS Pointer"
    case crosshair = "Crosshair"

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.macOSPointer, .id): return "Panah macOS"
        case (.macOSPointer, .en): return "macOS Pointer"
        case (.touchCircle, .id): return "iOS Pointer"
        case (.touchCircle, .en): return "iOS Pointer"
        case (.crosshair, _): return "Crosshair"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        switch str.lowercased() {
        case "panah macos", "macos pointer", "macospointer":
            self = .macOSPointer
        case "ios pointer", "lingkaran", "touch circle", "touchcircle":
            self = .touchCircle
        case "crosshair":
            self = .crosshair
        default:
            self = .macOSPointer
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ClickAnimationStyle: String, CaseIterable, Identifiable, Codable {
    case singleRipple = "Gelombang Tunggal"
    case doublePulse = "Gelombang Ganda (Double Pulse)"
    case softGlow = "Cincin Halus (iOS Pulse)"

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.singleRipple, .id): return "Gelombang Tunggal"
        case (.singleRipple, .en): return "Single Ripple"
        case (.doublePulse, .id): return "Gelombang Ganda (Double Pulse)"
        case (.doublePulse, .en): return "Double Pulse Ring"
        case (.softGlow, .id): return " Denyut Halus (iOS Pulse)"
        case (.softGlow, .en): return "Soft Glow (iOS Pulse)"
        }
    }
}

public enum ZoomFrameMode: String, CaseIterable, Identifiable, Codable {
    case wholeFrame = "Bingkai Zoom"
    case insideFrame = "Isi Zoom"

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.wholeFrame, .id): return "Bingkai Zoom"
        case (.wholeFrame, .en): return "Whole Frame"
        case (.insideFrame, .id): return "Isi Zoom"
        case (.insideFrame, .en): return "Inside Frame"
        }
    }
}

public enum CaptureTargetMode: String, CaseIterable, Identifiable, Codable {
    case fullScreen = "Selayar"
    case appWindow = "Aplikasi"

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.fullScreen, .id): return "Selayar"
        case (.fullScreen, .en): return "Full Screen"
        case (.appWindow, .id): return "Aplikasi"
        case (.appWindow, .en): return "App Window"
        }
    }
}

// MARK: - Video Output & Quality Presets (R2)

public enum VideoResolutionTarget: String, CaseIterable, Identifiable, Codable {
    case native = "Native (Layar Asli)"
    case fhd1080p = "1080p (Full HD)"

    public var id: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.native, .id): return "Native (Layar Asli)"
        case (.native, .en): return "Native (Original Screen)"
        case (.fhd1080p, _): return "1080p (Full HD)"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        switch str.lowercased() {
        case "native", "layar asli":
            self = .native
        case "fhd1080p", "1080p", "full hd", "p1080":
            self = .fhd1080p
        default:
            if let match = VideoResolutionTarget.allCases.first(where: { $0.rawValue == str }) {
                self = match
            } else {
                self = .native
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum VideoFrameRateTarget: Int, CaseIterable, Identifiable, Codable {
    case fps60 = 60
    case fps30 = 30

    public var id: Int { rawValue }
    public var displayName: String { "\(rawValue) FPS" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            switch intVal {
            case 60: self = .fps60
            case 30: self = .fps30
            default: self = .fps60
            }
        } else if let strVal = try? container.decode(String.self) {
            switch strVal {
            case "60", "fps60": self = .fps60
            case "30", "fps30": self = .fps30
            default: self = .fps60
            }
        } else {
            self = .fps60
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum VideoCodecPreset: String, CaseIterable, Identifiable, Codable {
    case proRes422 = "ProRes 422 (Studio, Halus 60 FPS)"
    case proRes422LT = "ProRes 422 LT (Efisien)"
    case h264 = "H.264 / MP4 (Kompatibel)"
    case hevc = "HEVC / H.265 (Kompresi Tinggi)"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public func label(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.proRes422, .id): return "ProRes 422 (Studio, Halus 60 FPS)"
        case (.proRes422, .en): return "ProRes 422 (Studio, Smooth 60 FPS)"
        case (.proRes422LT, .id): return "ProRes 422 LT / Proxy (Hemat, Halus 60 FPS)"
        case (.proRes422LT, .en): return "ProRes 422 LT / Proxy (Compact, Smooth 60 FPS)"
        case (.h264, .id): return "H.264 / MP4 (Ukuran Kecil, 60 FPS)"
        case (.h264, .en): return "H.264 / MP4 (Small File, 60 FPS)"
        case (.hevc, .id): return "HEVC / H.265 (MP4 Hemat, 60 FPS)"
        case (.hevc, .en): return "HEVC / H.265 (Compact MP4, 60 FPS)"
        }
    }

    public var isMOV: Bool {
        switch self {
        case .proRes422, .proRes422LT: return true
        case .h264, .hevc: return false
        }
    }

    public var avCodecType: AVVideoCodecType {
        switch self {
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422Proxy
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    public var recommendedFrameRate: VideoFrameRateTarget {
        return .fps60
    }

    public var isRecommendedFor60FPS: Bool {
        return true
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let str = try container.decode(String.self)
        switch str.lowercased() {
        case "prores422", "prores 422", "apcn":
            self = .proRes422
        case "prores422lt", "prores 422 lt", "apcs":
            self = .proRes422LT
        case "h264", "avc1", "mp4":
            self = .h264
        case "hevc", "h265", "hvc1":
            self = .hevc
        default:
            if let match = VideoCodecPreset.allCases.first(where: { $0.rawValue == str }) {
                self = match
            } else {
                self = .proRes422
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Audio Device Info

public struct AudioDeviceInfo: Identifiable, Hashable, Codable {
    public let id: String
    public let name: String
    public let channels: Int

    public init(id: String, name: String, channels: Int = 2) {
        self.id = id
        self.name = name
        self.channels = channels
    }
}

// MARK: - Studio Settings (Automatically Persisted to UserDefaults)

public struct StudioSettings: Equatable, Codable {
    private static let storageKey = "com.cutefishaep.zoomkmouse.StudioSettings.v1"

    // 0. Language Setting
    public var appLanguage: AppLanguage = .id

    // 1. Auto Zoom Settings
    public var autoZoomEnabled: Bool = true
    public var alwaysZoomWhenClickDisabled: Bool = false
    public var zoomFrameMode: ZoomFrameMode = .wholeFrame
    public var defaultZoomScale: CGFloat = 2.1
    public var zoomHoldDuration: Double = 1.8
    public var preClickLeadTime: Double = 0.22
    public var zoomSpeed: ZoomSpeedPreset = .mellow
    public var followMouseWhenZoomed: Bool = true
    public var panSmoothing: CGFloat = 0.16

    // 2. Background & Frame Settings
    public var backgroundType: BackgroundType = .macWallpaper
    public var selectedGradientIndex: Int = 0
    public var solidBackgroundColor: RGBAColor = RGBAColor(r: 0.12, g: 0.13, b: 0.18)
    public var customBackgroundImageURL: URL? = nil
    public var canvasPadding: CGFloat = 68.0
    public var cornerRadius: CGFloat = 18.0
    public var insetBorderOpacity: CGFloat = 0.30
    public var aspectRatio: CanvasAspectRatio = .widescreen16x9

    // 3. Drop Shadow Settings
    public var shadowEnabled: Bool = true
    public var shadowOpacity: CGFloat = 0.60
    public var shadowBlurRadius: CGFloat = 45.0
    public var shadowOffsetY: CGFloat = 24.0
    public var shadowOffsetX: CGFloat = 0.0
    public var shadowColor: RGBAColor = RGBAColor(r: 0.0, g: 0.0, b: 0.0)

    // 4. Mouse & Click Settings
    public var showCursor: Bool = true
    public var cursorStyle: CursorStyle = .macOSPointer
    public var cursorScale: CGFloat = 1.65
    public var smoothMouseMovement: Bool = true
    public var mouseSmoothingFactor: CGFloat = 0.24 // lower = smoother/more inertia
    public var scaleCursorWithZoom: Bool = true
    public var clickRippleEnabled: Bool = true
    public var clickAnimationStyle: ClickAnimationStyle = .singleRipple
    public var clickRippleColor: RGBAColor = RGBAColor(r: 1.0, g: 0.24, b: 0.42, a: 0.95)
    public var rightClickRippleColor: RGBAColor = RGBAColor(r: 0.22, g: 0.62, b: 1.0, a: 0.95)
    public var clickRippleMaxRadius: CGFloat = 44.0
    public var clickRippleDuration: Double = 0.50
    public var clickRippleLineWidth: CGFloat = 3.2
    public var clickSquishEffect: Bool = true
    public var hideCursorWhenIdle: Bool = false

    // 5. Audio Settings (R1)
    public var isSystemAudioEnabled: Bool = true
    public var systemAudioVolume: Float = 1.0
    public var isMicAudioEnabled: Bool = false
    public var micDeviceUID: String? = nil
    public var micAudioVolume: Float = 1.0

    // 6. Video Output Settings (R2)
    public var videoResolution: VideoResolutionTarget = .native
    public var videoFrameRate: VideoFrameRateTarget = .fps60
    public var videoCodec: VideoCodecPreset = .proRes422

    public enum CodingKeys: String, CodingKey {
        case appLanguage
        case autoZoomEnabled, alwaysZoomWhenClickDisabled, zoomFrameMode, defaultZoomScale, zoomHoldDuration
        case preClickLeadTime, zoomSpeed, followMouseWhenZoomed, panSmoothing
        case backgroundType, selectedGradientIndex, solidBackgroundColor, customBackgroundImageURL
        case canvasPadding, cornerRadius, insetBorderOpacity, aspectRatio
        case shadowEnabled, shadowOpacity, shadowBlurRadius, shadowOffsetY, shadowOffsetX, shadowColor
        case showCursor, cursorStyle, cursorScale, smoothMouseMovement, mouseSmoothingFactor
        case scaleCursorWithZoom, clickRippleEnabled, clickAnimationStyle, clickRippleColor, rightClickRippleColor
        case clickRippleMaxRadius, clickRippleDuration, clickRippleLineWidth, clickSquishEffect, hideCursorWhenIdle
        case isSystemAudioEnabled, systemAudioVolume, isMicAudioEnabled, micDeviceUID, micAudioVolume
        case videoResolution, videoFrameRate, videoCodec
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.appLanguage = try container.decodeIfPresent(AppLanguage.self, forKey: .appLanguage) ?? .id
        self.autoZoomEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoZoomEnabled) ?? true
        self.alwaysZoomWhenClickDisabled = try container.decodeIfPresent(Bool.self, forKey: .alwaysZoomWhenClickDisabled) ?? false
        self.zoomFrameMode = try container.decodeIfPresent(ZoomFrameMode.self, forKey: .zoomFrameMode) ?? .wholeFrame
        self.defaultZoomScale = try container.decodeIfPresent(CGFloat.self, forKey: .defaultZoomScale) ?? 2.1
        self.zoomHoldDuration = try container.decodeIfPresent(Double.self, forKey: .zoomHoldDuration) ?? 1.8
        self.preClickLeadTime = try container.decodeIfPresent(Double.self, forKey: .preClickLeadTime) ?? 0.22
        self.zoomSpeed = try container.decodeIfPresent(ZoomSpeedPreset.self, forKey: .zoomSpeed) ?? .mellow
        self.followMouseWhenZoomed = try container.decodeIfPresent(Bool.self, forKey: .followMouseWhenZoomed) ?? true
        self.panSmoothing = try container.decodeIfPresent(CGFloat.self, forKey: .panSmoothing) ?? 0.16

        self.backgroundType = try container.decodeIfPresent(BackgroundType.self, forKey: .backgroundType) ?? .macWallpaper
        self.selectedGradientIndex = try container.decodeIfPresent(Int.self, forKey: .selectedGradientIndex) ?? 0
        self.solidBackgroundColor = try container.decodeIfPresent(RGBAColor.self, forKey: .solidBackgroundColor) ?? RGBAColor(r: 0.12, g: 0.13, b: 0.18)
        self.customBackgroundImageURL = try container.decodeIfPresent(URL.self, forKey: .customBackgroundImageURL)
        self.canvasPadding = try container.decodeIfPresent(CGFloat.self, forKey: .canvasPadding) ?? 68.0
        self.cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 18.0
        self.insetBorderOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .insetBorderOpacity) ?? 0.30
        self.aspectRatio = try container.decodeIfPresent(CanvasAspectRatio.self, forKey: .aspectRatio) ?? .widescreen16x9

        self.shadowEnabled = try container.decodeIfPresent(Bool.self, forKey: .shadowEnabled) ?? true
        self.shadowOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOpacity) ?? 0.60
        self.shadowBlurRadius = try container.decodeIfPresent(CGFloat.self, forKey: .shadowBlurRadius) ?? 45.0
        self.shadowOffsetY = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetY) ?? 24.0
        self.shadowOffsetX = try container.decodeIfPresent(CGFloat.self, forKey: .shadowOffsetX) ?? 0.0
        self.shadowColor = try container.decodeIfPresent(RGBAColor.self, forKey: .shadowColor) ?? RGBAColor(r: 0.0, g: 0.0, b: 0.0)

        self.showCursor = try container.decodeIfPresent(Bool.self, forKey: .showCursor) ?? true
        self.cursorStyle = try container.decodeIfPresent(CursorStyle.self, forKey: .cursorStyle) ?? .macOSPointer
        self.cursorScale = try container.decodeIfPresent(CGFloat.self, forKey: .cursorScale) ?? 1.65
        self.smoothMouseMovement = try container.decodeIfPresent(Bool.self, forKey: .smoothMouseMovement) ?? true
        self.mouseSmoothingFactor = try container.decodeIfPresent(CGFloat.self, forKey: .mouseSmoothingFactor) ?? 0.24
        self.scaleCursorWithZoom = try container.decodeIfPresent(Bool.self, forKey: .scaleCursorWithZoom) ?? true
        self.clickRippleEnabled = try container.decodeIfPresent(Bool.self, forKey: .clickRippleEnabled) ?? true
        self.clickAnimationStyle = try container.decodeIfPresent(ClickAnimationStyle.self, forKey: .clickAnimationStyle) ?? .singleRipple
        self.clickRippleColor = try container.decodeIfPresent(RGBAColor.self, forKey: .clickRippleColor) ?? RGBAColor(r: 1.0, g: 0.24, b: 0.42, a: 0.95)
        self.rightClickRippleColor = try container.decodeIfPresent(RGBAColor.self, forKey: .rightClickRippleColor) ?? RGBAColor(r: 0.22, g: 0.62, b: 1.0, a: 0.95)
        self.clickRippleMaxRadius = try container.decodeIfPresent(CGFloat.self, forKey: .clickRippleMaxRadius) ?? 44.0
        self.clickRippleDuration = try container.decodeIfPresent(Double.self, forKey: .clickRippleDuration) ?? 0.50
        self.clickRippleLineWidth = try container.decodeIfPresent(CGFloat.self, forKey: .clickRippleLineWidth) ?? 3.2
        self.clickSquishEffect = try container.decodeIfPresent(Bool.self, forKey: .clickSquishEffect) ?? true
        self.hideCursorWhenIdle = try container.decodeIfPresent(Bool.self, forKey: .hideCursorWhenIdle) ?? false

        self.isSystemAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .isSystemAudioEnabled) ?? true
        self.systemAudioVolume = try container.decodeIfPresent(Float.self, forKey: .systemAudioVolume) ?? 1.0
        self.isMicAudioEnabled = try container.decodeIfPresent(Bool.self, forKey: .isMicAudioEnabled) ?? false
        self.micDeviceUID = try container.decodeIfPresent(String.self, forKey: .micDeviceUID)
        self.micAudioVolume = try container.decodeIfPresent(Float.self, forKey: .micAudioVolume) ?? 1.0

        self.videoResolution = try container.decodeIfPresent(VideoResolutionTarget.self, forKey: .videoResolution) ?? .native
        self.videoFrameRate = try container.decodeIfPresent(VideoFrameRateTarget.self, forKey: .videoFrameRate) ?? .fps60
        self.videoCodec = try container.decodeIfPresent(VideoCodecPreset.self, forKey: .videoCodec) ?? .proRes422
    }

    public static func loadSaved() -> StudioSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(StudioSettings.self, from: data) else {
            return StudioSettings()
        }
        return decoded
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Telemetry & Timeline Models

/// Normalized screen coordinates: (0,0) = Top-Left, (1,1) = Bottom-Right
public struct MouseSample: Codable, Equatable {
    public let timestamp: TimeInterval
    public let location: CGPoint
    public let isLeftDown: Bool
    public let isRightDown: Bool

    public init(timestamp: TimeInterval, location: CGPoint, isLeftDown: Bool, isRightDown: Bool) {
        self.timestamp = timestamp
        self.location = location
        self.isLeftDown = isLeftDown
        self.isRightDown = isRightDown
    }
}

public struct ClickEvent: Identifiable, Codable, Equatable {
    public let id: UUID
    public let timestamp: TimeInterval
    public let location: CGPoint // Normalized 0..1 (Top-Left origin)
    public let isRightClick: Bool

    public init(id: UUID = UUID(), timestamp: TimeInterval, location: CGPoint, isRightClick: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.location = location
        self.isRightClick = isRightClick
    }
}

public struct ZoomSegment: Identifiable, Codable, Equatable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var focusPoint: CGPoint // Normalized 0..1 (Top-Left origin)
    public var zoomScale: CGFloat
    public var isAutoGenerated: Bool

    public init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        focusPoint: CGPoint,
        zoomScale: CGFloat,
        isAutoGenerated: Bool = true
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.focusPoint = focusPoint
        self.zoomScale = zoomScale
        self.isAutoGenerated = isAutoGenerated
    }

    public var duration: TimeInterval {
        max(0.1, endTime - startTime)
    }
}

// MARK: - Instant Render State

public struct CameraRenderState: Equatable {
    public var zoom: CGFloat = 1.0
    /// Normalized (0..1, Top-Left origin) center of the zoomed viewport
    public var focusCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)

    public init(zoom: CGFloat = 1.0, focusCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.zoom = zoom
        self.focusCenter = focusCenter
    }
}

public struct ActiveClickRipple: Equatable {
    public var location: CGPoint // Normalized 0..1 (Top-Left origin)
    public var progress: CGFloat // 0.0 -> 1.0
    public var isRightClick: Bool

    public init(location: CGPoint, progress: CGFloat, isRightClick: Bool) {
        self.location = location
        self.progress = progress
        self.isRightClick = isRightClick
    }
}

public struct CursorRenderState: Equatable {
    public var location: CGPoint = CGPoint(x: 0.5, y: 0.5) // Normalized 0..1 (Top-Left origin)
    public var isPressed: Bool = false
    public var opacity: CGFloat = 1.0
    public var ripples: [ActiveClickRipple] = []

    public init(
        location: CGPoint = CGPoint(x: 0.5, y: 0.5),
        isPressed: Bool = false,
        opacity: CGFloat = 1.0,
        ripples: [ActiveClickRipple] = []
    ) {
        self.location = location
        self.isPressed = isPressed
        self.opacity = opacity
        self.ripples = ripples
    }
}
