import SwiftUI
import AppKit

public enum InspectorTab: String, CaseIterable, Identifiable {
    case zoom = "Auto Zoom"
    case background = "Background"
    case shadow = "Drop Shadow"
    case mouse = "Mouse & Klik"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .zoom: return "plus.magnifyingglass"
        case .background: return "photo.artframe"
        case .shadow: return "square.3.layers.3d.down.right"
        case .mouse: return "cursorarrow.click.2"
        }
    }
}

public struct MainStudioView: View {
    @ObservedObject var controller: StudioController
    @State private var selectedTab: InspectorTab = .zoom
    @State private var showAboutSheet: Bool = false

    public init(controller: StudioController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Studio Header Bar
            topToolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // 2. Main Split Content: Left Live Canvas, Right Inspector Sidebar
            HStack(spacing: 0) {
                // Center Stage (Full Live Preview without Timeline Editor)
                VStack(spacing: 8) {
                    ZStack(alignment: .topLeading) {
                        CompositorCanvasView(controller: controller)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if !controller.hasScreenCapturePermission {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.yellow)

                                Text("Izin Rekam Layar belum aktif.")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)

                                Button("Buka Izin") {
                                    controller.openScreenRecordingSettings()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.orange)
                                .controlSize(.small)

                                Button("Muat Ulang") {
                                    controller.refreshDisplaysAndWindows()
                                    controller.restartScreenCaptureStream()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color.black.opacity(0.85))
                            .cornerRadius(8)
                            .padding(16)
                        }
                    }
                }
                .padding(12)
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10))

                Divider()

                // Right Inspector Sidebar
                VStack(spacing: 0) {
                    // Tab Picker with Full Hit-Box (.contentShape(Rectangle()))
                    HStack(spacing: 6) {
                        ForEach(InspectorTab.allCases) { tab in
                            let isSelected = (selectedTab == tab)
                            Button(action: {
                                selectedTab = tab
                            }) {
                                VStack(spacing: 5) {
                                    Image(systemName: tab.iconName)
                                        .font(.system(size: 14, weight: .semibold))
                                    Text(tab.rawValue)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.04))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
                                )
                                .foregroundColor(isSelected ? .accentColor : .primary.opacity(0.78))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            switch selectedTab {
                            case .zoom:
                                zoomInspectorSection
                            case .background:
                                backgroundInspectorSection
                            case .shadow:
                                shadowInspectorSection
                            case .mouse:
                                mouseInspectorSection
                            }
                        }
                        .padding(14)
                    }
                }
                .frame(width: 325)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 1020, minHeight: 620)
        .sheet(isPresented: $showAboutSheet) {
            AboutStudioSheetView(isPresented: $showAboutSheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenZoomKeMouseAbout"))) { _ in
            showAboutSheet = true
        }
    }

    // MARK: - Top Toolbar

    private var topToolbar: some View {
        HStack(spacing: 10) {
            // 1. Capture Mode: Layar Penuh vs Aplikasi
            Picker("", selection: Binding(
                get: { controller.captureTargetMode },
                set: { controller.selectCaptureTargetMode($0) }
            )) {
                ForEach(CaptureTargetMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            // 2. Display or App Window Selector
            if controller.captureTargetMode == .fullScreen {
                HStack(spacing: 4) {
                    Image(systemName: "display")
                        .foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { controller.selectedDisplayID },
                        set: { controller.selectDisplay($0) }
                    )) {
                        ForEach(controller.availableDisplays) { disp in
                            Text(disp.name).tag(disp.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 165)

                    Button(action: {
                        controller.refreshDisplaysAndWindows()
                        controller.restartScreenCaptureStream()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Muat ulang daftar layar")
                }

                Toggle("Sembunyikan App", isOn: Binding(
                    get: { controller.excludeOwnAppWindow },
                    set: { val in
                        controller.excludeOwnAppWindow = val
                        controller.restartScreenCaptureStream()
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .help("Sembunyikan jendela Zoom Ke Mouse saat rekam layar penuh")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "macwindow")
                        .foregroundColor(.accentColor)
                    Picker("", selection: Binding(
                        get: { controller.selectedWindowID },
                        set: { controller.selectAppWindow($0) }
                    )) {
                        if controller.availableAppWindows.isEmpty {
                            Text("Tidak ada jendela aplikasi").tag(CGWindowID(0))
                        } else {
                            ForEach(controller.availableAppWindows) { win in
                                Text(win.displayName).tag(win.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(width: 230)

                    Button(action: {
                        controller.refreshDisplaysAndWindows()
                        controller.restartScreenCaptureStream()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Muat ulang daftar aplikasi yang sedang buka")
                }
            }

            Divider()
                .frame(height: 24)

            // 3. Quick Switch: Zoom Bingkai vs Zoom Isi
            Picker("", selection: $controller.settings.zoomFrameMode) {
                ForEach(ZoomFrameMode.allCases) { zMode in
                    Text(zMode.rawValue).tag(zMode)
                }
            }
            .frame(width: 165)
            .help("Pilih apakah seluruh bingkai ikut nge-zoom atau zoom di dalam bingkai")

            Spacer()

            // Test Zoom Button
            Button(action: {
                controller.triggerDemoClick()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Tes Zoom")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.16))
                .cornerRadius(7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Uji coba efek zoom secara langsung")

            HStack(spacing: 8) {
                if controller.mode == .recording {
                    RecordingTimerBadgeView(telemetry: controller.telemetry)
                }

                // Direct Record / Stop & Save Immediately Button
                Button(action: {
                    controller.toggleRecording()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: controller.mode == .recording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(controller.mode == .recording ? "Stop & Simpan" : "Mulai Rekam")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(controller.mode == .recording ? Color.red : Color.red.opacity(0.88))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command])
                .help(controller.mode == .recording ? "Klik untuk berhenti dan langsung simpan video (⌘R)" : "Klik untuk mulai merekam secara real-time (⌘R)")
            }

            if controller.lastSavedVideoURL != nil {
                Button(action: {
                    controller.revealLastSavedVideo()
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Buka Folder")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Tampilkan file video terakhir di Finder")
            }

            // About App Button
            Button(action: {
                showAboutSheet = true
            }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(6)
                    .background(Color.secondary.opacity(0.16))
                    .cornerRadius(7)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Tentang Zoom Ke Mouse")
        }
    }

    // MARK: - 1. Auto Zoom Inspector

    private var zoomInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pengaturan Real-Time Auto Zoom")
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Auto-Zoom Saat Klik Mouse", isOn: $controller.settings.autoZoomEnabled)
                        .font(.system(size: 12, weight: .semibold))

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode Bingkai")
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.zoomFrameMode) {
                            ForEach(ZoomFrameMode.allCases) { zMode in
                                Text(zMode.rawValue).tag(zMode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Skala Zoom")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.2fx", controller.settings.defaultZoomScale))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }
                        Slider(value: $controller.settings.defaultZoomScale, in: 1.2...4.0, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Durasi Tahan Zoom")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1fs", controller.settings.zoomHoldDuration))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.zoomHoldDuration, in: 0.5...5.0, step: 0.1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kecepatan Transisi")
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.zoomSpeed) {
                            ForEach(ZoomSpeedPreset.allCases) { speed in
                                Text(speed.rawValue).tag(speed)
                            }
                        }
                        .labelsHidden()
                    }
                }
                .padding(6)
            }

            GroupBox(label: Text("Kamera").font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Ikuti Kursor Saat Zoom", isOn: $controller.settings.followMouseWhenZoomed)
                        .font(.system(size: 12, weight: .medium))

                    if controller.settings.followMouseWhenZoomed {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Kelembutan Kamera")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(String(format: "%.0f%%", controller.settings.panSmoothing * 100))
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            Slider(value: $controller.settings.panSmoothing, in: 0.05...0.50)
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - 2. Background & Canvas Inspector

    private var backgroundInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background & Kanvas")
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Jenis Background")
                        .font(.system(size: 11, weight: .medium))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(BackgroundType.allCases) { bgType in
                            let isSelected = (controller.settings.backgroundType == bgType)
                            Button(action: {
                                if bgType == .macWallpaper {
                                    DesktopWallpaperHelper.refreshCache()
                                }
                                controller.settings.backgroundType = bgType
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: iconForBackgroundType(bgType))
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(bgType.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                                )
                                .foregroundColor(isSelected ? .accentColor : .primary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if controller.settings.backgroundType == .macWallpaper {
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer")
                                .foregroundColor(.accentColor)
                            Text("Menggunakan wallpaper aktif macOS Anda")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Segarkan") {
                                DesktopWallpaperHelper.refreshCache()
                                controller.settings.backgroundType = .macWallpaper
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 4)
                    } else if controller.settings.backgroundType == .gradient {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(GradientPreset.allPresets) { preset in
                                let isSelected = controller.settings.selectedGradientIndex == preset.id
                                Button(action: {
                                    controller.settings.selectedGradientIndex = preset.id
                                }) {
                                    HStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(
                                                LinearGradient(
                                                    colors: preset.colors.map { $0.swiftUIColor },
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 22, height: 18)
                                        Text(preset.name)
                                            .font(.system(size: 10, weight: .medium))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.white.opacity(0.04))
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else if controller.settings.backgroundType == .solidColor {
                        ColorPicker(
                            "Warna Solid",
                            selection: Binding(
                                get: { controller.settings.solidBackgroundColor.swiftUIColor },
                                set: { controller.settings.solidBackgroundColor = RGBAColor(nsColor: NSColor($0)) }
                            )
                        )
                        .font(.system(size: 11, weight: .medium))
                    } else if controller.settings.backgroundType == .customImage {
                        VStack(alignment: .leading, spacing: 6) {
                            if let url = controller.settings.customBackgroundImageURL {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Button(action: {
                                controller.chooseCustomBackgroundImage()
                            }) {
                                Label("Pilih Gambar...", systemImage: "folder.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(6)
            }

            GroupBox(label: Text("Ukuran & Bingkai").font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Aspek Rasio")
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.aspectRatio) {
                            ForEach(CanvasAspectRatio.allCases) { ratio in
                                Text(ratio.rawValue).tag(ratio)
                            }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Padding")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.canvasPadding)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.canvasPadding, in: 0...180, step: 2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Sudut Melengkung")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.cornerRadius)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.cornerRadius, in: 0...44, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Garis Tepi")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.insetBorderOpacity * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.insetBorderOpacity, in: 0.0...0.85, step: 0.05)
                    }
                }
                .padding(6)
            }
        }
    }

    private func iconForBackgroundType(_ type: BackgroundType) -> String {
        switch type {
        case .macWallpaper: return "desktopcomputer"
        case .gradient: return "paintbrush.pointed.fill"
        case .solidColor: return "square.fill"
        case .customImage: return "photo.fill"
        }
    }

    // MARK: - 3. Drop Shadow Inspector

    private var shadowInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drop Shadow")
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Aktifkan Shadow", isOn: $controller.settings.shadowEnabled)
                        .font(.system(size: 12, weight: .semibold))

                    Divider()

                    HStack(spacing: 6) {
                        Button("Lembut") {
                            controller.settings.shadowEnabled = true
                            controller.settings.shadowOpacity = 0.35
                            controller.settings.shadowBlurRadius = 24
                            controller.settings.shadowOffsetY = 12
                            controller.settings.shadowColor = RGBAColor(r: 0, g: 0, b: 0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Studio") {
                            controller.settings.shadowEnabled = true
                            controller.settings.shadowOpacity = 0.60
                            controller.settings.shadowBlurRadius = 45
                            controller.settings.shadowOffsetY = 24
                            controller.settings.shadowColor = RGBAColor(r: 0, g: 0, b: 0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Gelap") {
                            controller.settings.shadowEnabled = true
                            controller.settings.shadowOpacity = 0.82
                            controller.settings.shadowBlurRadius = 72
                            controller.settings.shadowOffsetY = 38
                            controller.settings.shadowColor = RGBAColor(r: 0, g: 0, b: 0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Kepekatan")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.shadowOpacity * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.shadowOpacity, in: 0.0...1.0, step: 0.02)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Radius Blur")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.shadowBlurRadius)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.shadowBlurRadius, in: 0...110, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Offset Y")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.shadowOffsetY)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.shadowOffsetY, in: -20...70, step: 1)
                    }

                    ColorPicker(
                        "Warna",
                        selection: Binding(
                            get: { controller.settings.shadowColor.swiftUIColor },
                            set: { controller.settings.shadowColor = RGBAColor(nsColor: NSColor($0)) }
                        )
                    )
                    .font(.system(size: 11, weight: .medium))
                }
                .padding(6)
            }
        }
    }

    // MARK: - 4. Mouse & Click Inspector

    private var mouseInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Kursor & Klik")
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Tampilkan Kursor", isOn: $controller.settings.showCursor)
                        .font(.system(size: 12, weight: .semibold))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bentuk Kursor")
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.cursorStyle) {
                            ForEach(CursorStyle.allCases) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Ukuran Kursor")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.2fx", controller.settings.cursorScale))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.cursorScale, in: 0.75...3.5, step: 0.05)
                    }

                    Divider()

                    Toggle("Perhalus Gerakan", isOn: $controller.settings.smoothMouseMovement)
                        .font(.system(size: 12, weight: .medium))

                    if controller.settings.smoothMouseMovement {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Kelembutan")
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(String(format: "%.0f%%", (1.0 - controller.settings.mouseSmoothingFactor) * 100))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Slider(value: $controller.settings.mouseSmoothingFactor, in: 0.08...0.50, step: 0.02)
                        }
                    }

                    Toggle("Perbesar Saat Zoom", isOn: $controller.settings.scaleCursorWithZoom)
                        .font(.system(size: 11, weight: .medium))

                    Toggle("Sembunyikan Saat Diam", isOn: $controller.settings.hideCursorWhenIdle)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(6)
            }

            GroupBox(label: Text("Efek Klik").font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Gelombang Klik", isOn: $controller.settings.clickRippleEnabled)
                        .font(.system(size: 12, weight: .semibold))

                    Toggle("Efek Tekan Kursor", isOn: $controller.settings.clickSquishEffect)
                        .font(.system(size: 11, weight: .medium))

                    ColorPicker(
                        "Warna Klik Kiri",
                        selection: Binding(
                            get: { controller.settings.clickRippleColor.swiftUIColor },
                            set: { controller.settings.clickRippleColor = RGBAColor(nsColor: NSColor($0)) }
                        )
                    )
                    .font(.system(size: 11, weight: .medium))

                    ColorPicker(
                        "Warna Klik Kanan",
                        selection: Binding(
                            get: { controller.settings.rightClickRippleColor.swiftUIColor },
                            set: { controller.settings.rightClickRippleColor = RGBAColor(nsColor: NSColor($0)) }
                        )
                    )
                    .font(.system(size: 11, weight: .medium))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Radius")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.clickRippleMaxRadius)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.clickRippleMaxRadius, in: 20...90, step: 2)
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct RecordingTimerBadgeView: View {
    @ObservedObject var telemetry: TransportTelemetryModel

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text(String(format: "%.1fs", telemetry.recordingElapsed))
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(.red)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.red.opacity(0.14))
        .cornerRadius(6)
    }
}

private struct AboutStudioSheetView: View {
    @Binding var isPresented: Bool

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    private var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.cutefishaep.zoomkmouse"
    }

    var body: some View {
        VStack(spacing: 14) {
            if let iconImg = NSApp.applicationIconImage {
                Image(nsImage: iconImg)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
            }

            VStack(spacing: 4) {
                Text("Zoom Ke Mouse")
                    .font(.system(size: 18, weight: .bold))

                Text("Versi \(appVersion) (\(bundleIdentifier))")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text("Perekam layar macOS dengan auto-zoom mengikuti posisi dan klik kursor secara real-time.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Pembuat")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Wahyu Septiaji (@cutefishaep)")
                            .font(.system(size: 11.5, weight: .semibold))
                    }

                    Divider()

                    HStack {
                        Text("Repositori")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button(action: {
                            if let url = URL(string: "https://github.com/cutefishaep/Zoom-Ke-Mouse") {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            Text("github.com/cutefishaep/Zoom-Ke-Mouse")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()

                    HStack {
                        Text("Lisensi")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("CC BY-NC-SA 4.0")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }

                    Text("Hak Cipta © 2026 Wahyu Septiaji (@cutefishaep). Dilisensikan di bawah Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Tutup") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}
