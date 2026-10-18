import SwiftUI
import AppKit

public enum InspectorTab: String, CaseIterable, Identifiable {
    case zoom = "Auto Zoom"
    case background = "Background"
    case shadow = "Drop Shadow"
    case mouse = "Mouse & Klik"
    case audioOutput = "Audio & Output"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .zoom: return "plus.magnifyingglass"
        case .background: return "photo.artframe"
        case .shadow: return "square.3.layers.3d.down.right"
        case .mouse: return "cursorarrow.click.2"
        case .audioOutput: return "speaker.wave.2.fill"
        }
    }
}

public struct MainStudioView: View {
    @ObservedObject var controller: StudioController
    @State private var selectedTab: InspectorTab = .zoom
    @State private var showSettingsSheet: Bool = false
    @State private var showAboutSheet: Bool = false

    public init(controller: StudioController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Live Preview Stage (Compact Square)
            ZStack(alignment: .topLeading) {
                CompositorCanvasView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !controller.hasScreenCapturePermission {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Izin Rekam belum aktif")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                        Button("Buka Izin") {
                            controller.openScreenRecordingSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.mini)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(8)
                    .padding(10)
                }

                // Recording Timer Badge Overlay
                if controller.mode == .recording {
                    VStack {
                        Spacer()
                        HStack {
                            RecordingTimerBadgeView(telemetry: controller.telemetry)
                            Spacer()
                        }
                        .padding(10)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.07, green: 0.08, blue: 0.10))

            Divider()

            // 2. Compact Bottom Bar (3 Main Controls)
            HStack(spacing: 12) {
                // Tombol 1: Fullscreen / Windowed Mode (Menu Button)
                Menu {
                    Button(action: {
                        controller.selectCaptureTargetMode(.fullScreen)
                    }) {
                        if controller.captureTargetMode == .fullScreen {
                            Label("Layar Penuh (Selayar)", systemImage: "checkmark")
                        } else {
                            Text("Layar Penuh (Selayar)")
                        }
                    }

                    Button(action: {
                        controller.selectCaptureTargetMode(.appWindow)
                    }) {
                        if controller.captureTargetMode == .appWindow {
                            Label("Jendela Aplikasi", systemImage: "checkmark")
                        } else {
                            Text("Jendela Aplikasi")
                        }
                    }

                    Divider()

                    if controller.captureTargetMode == .fullScreen {
                        ForEach(controller.availableDisplays) { disp in
                            Button(action: {
                                controller.selectDisplay(disp.id)
                            }) {
                                if controller.selectedDisplayID == disp.id {
                                    Label(disp.name, systemImage: "checkmark")
                                } else {
                                    Text(disp.name)
                                }
                            }
                        }

                        Divider()

                        Toggle("Sembunyikan App Ini", isOn: Binding(
                            get: { controller.excludeOwnAppWindow },
                            set: { val in
                                controller.excludeOwnAppWindow = val
                                controller.restartScreenCaptureStream()
                            }
                        ))
                    } else {
                        if controller.availableAppWindows.isEmpty {
                            Text("Tidak ada jendela lain")
                        } else {
                            ForEach(controller.availableAppWindows) { win in
                                Button(action: {
                                    controller.selectAppWindow(win.id)
                                }) {
                                    if controller.selectedWindowID == win.id {
                                        Label(win.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(win.displayName)
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    Button("Muat Ulang Layar & Jendela") {
                        controller.refreshDisplaysAndWindows()
                        controller.restartScreenCaptureStream()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: controller.captureTargetMode == .fullScreen ? "display" : "macwindow")
                            .font(.system(size: 13, weight: .semibold))
                        Text(controller.captureTargetMode == .fullScreen ? "Fullscreen" : "Windowed")
                            .font(.system(size: 11.5, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Pilih mode rekam Fullscreen atau Windowed")

                Spacer()

                // Tombol 2: Tombol Record Merah Bentuk Squircle
                Button(action: {
                    controller.toggleRecording()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: controller.mode == .recording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(controller.mode == .recording ? "Stop" : "Rekam")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(controller.mode == .recording ? Color.red : Color(red: 0.92, green: 0.22, blue: 0.24))
                            .shadow(color: Color.red.opacity(controller.mode == .recording ? 0.6 : 0.3), radius: 6, x: 0, y: 2)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command])
                .help(controller.mode == .recording ? "Hentikan perekaman dan simpan video (⌘R)" : "Mulai merekam (⌘R)")

                Spacer()

                // Tombol 3: Tombol Settings Pop-up
                Button(action: {
                    showSettingsSheet = true
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Settings")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08)))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .help("Buka pengaturan Auto Zoom, Background, Shadow, dan Mouse")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 420, minHeight: 300)
        .sheet(isPresented: $showSettingsSheet) {
            SettingsSheetModalView(
                controller: controller,
                selectedTab: $selectedTab,
                isPresented: $showSettingsSheet,
                onOpenAbout: {
                    showAboutSheet = true
                }
            )
        }
        .sheet(isPresented: $showAboutSheet) {
            AboutStudioSheetView(isPresented: $showAboutSheet)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenZoomKeMouseAbout"))) { _ in
            showAboutSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenZoomKeMouseSettings"))) { _ in
            showSettingsSheet = true
        }
    }




}

private struct SettingsSheetModalView: View {
    @ObservedObject var controller: StudioController
    @Binding var selectedTab: InspectorTab
    @Binding var isPresented: Bool
    var onOpenAbout: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header Pop-up with About Button on the Left
            HStack {
                Button(action: {
                    onOpenAbout()
                }) {
                    HStack(spacing: 7) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 15))
                            .foregroundColor(.accentColor)
                        Text("Zoom Ke Mouse")
                            .font(.system(size: 13, weight: .bold))
                        Text("v1.0.1")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Klik untuk melihat info Tentang Aplikasi & Lisensi")

                Spacer()

                Button("Selesai") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Clean Native Segmented / Tab Bar (Full Width & Even Precision)
            HStack(spacing: 4) {
                ForEach(InspectorTab.allCases) { tab in
                    let isSelected = (selectedTab == tab)
                    Button(action: {
                        selectedTab = tab
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: tab.iconName)
                                .font(.system(size: 11.5, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 11.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                        .foregroundColor(isSelected ? .accentColor : .primary.opacity(0.85))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))

            Divider()

            // Content Panel
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
                    case .audioOutput:
                        audioOutputInspectorSection
                    }
                }
                .padding(16)
            }
            .frame(height: 430)
        }
        .frame(width: 620)
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
                        Text("Mode Bingkai Zoom")
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

    // MARK: - 5. Audio & Output Inspector
    private var audioOutputInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pengaturan Audio & Kualitas Output")
                .font(.system(size: 13, weight: .bold))

            // GroupBox 1: Audio Sistem & Desktop
            GroupBox(label: Text("Audio Sistem & Desktop").font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Rekam Audio Sistem", isOn: $controller.settings.isSystemAudioEnabled)
                        .font(.system(size: 12, weight: .semibold))
                        .help("Rekam suara output desktop dan aplikasi Mac Anda")

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Volume Audio Sistem")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(round(controller.settings.systemAudioVolume * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.systemAudioVolume, in: Float(0.0)...Float(2.0), step: Float(0.05))
                            .help("Atur tingkat gain / volume rekaman audio sistem (0% - 200%)")
                    }
                    .disabled(!controller.settings.isSystemAudioEnabled)
                    .opacity(controller.settings.isSystemAudioEnabled ? 1.0 : 0.6)
                }
                .padding(6)
            }

            // GroupBox 2: Mikrofon & Input Suara
            GroupBox(label: Text("Mikrofon & Input Suara").font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Rekam Mikrofon", isOn: $controller.settings.isMicAudioEnabled)
                        .font(.system(size: 12, weight: .semibold))
                        .help("Rekam narasi suara dari mikrofon selama perekaman layar")

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Perangkat Mikrofon")
                            .font(.system(size: 11, weight: .medium))

                        let devices = AudioCaptureManager.shared.availableDevices()
                        Picker("Perangkat Mikrofon", selection: $controller.settings.micDeviceUID) {
                            if devices.isEmpty {
                                Text("Default Microphone").tag(String?.none)
                            } else {
                                Text("Default Microphone").tag(String?.none)
                                ForEach(devices) { dev in
                                    Text(dev.name).tag(String?.some(dev.id))
                                }
                            }
                        }
                        .labelsHidden()
                        .help("Pilih perangkat input mikrofon yang digunakan untuk merekam")
                    }
                    .disabled(!controller.settings.isMicAudioEnabled)
                    .opacity(controller.settings.isMicAudioEnabled ? 1.0 : 0.6)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Volume Mikrofon")
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(round(controller.settings.micAudioVolume * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.micAudioVolume, in: Float(0.0)...Float(2.0), step: Float(0.05))
                            .help("Atur tingkat gain / volume input mikrofon (0% - 200%)")
                    }
                    .disabled(!controller.settings.isMicAudioEnabled)
                    .opacity(controller.settings.isMicAudioEnabled ? 1.0 : 0.6)

                    if controller.settings.isMicAudioEnabled && !controller.hasMicrophonePermission {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11))
                            Text("Izin mikrofon belum aktif")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Buka Izin") {
                                controller.openMicrophoneSettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.mini)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(6)
            }

            // GroupBox 3: Format & Kualitas Video (Presets)
            GroupBox(label: Text("Format & Kualitas Video (Presets)").font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Target Resolusi")
                            .font(.system(size: 11, weight: .medium))
                        Picker("Target Resolusi", selection: $controller.settings.videoResolution) {
                            Text("Native (Layar Asli)").tag(VideoResolutionTarget.native)
                            Text("1080p (Full HD)").tag(VideoResolutionTarget.fhd1080p)
                        }
                        .labelsHidden()
                        .help("Pilih resolusi target video hasil rekaman")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frame Rate")
                            .font(.system(size: 11, weight: .medium))
                        Picker("Frame Rate", selection: $controller.settings.videoFrameRate) {
                            Text("60 FPS (Mulus)").tag(VideoFrameRateTarget.fps60)
                            Text("30 FPS").tag(VideoFrameRateTarget.fps30)
                        }
                        .labelsHidden()
                        .help("Pilih target frame rate video rekaman (60 FPS direkomendasikan)")
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Format & Codec")
                            .font(.system(size: 11, weight: .medium))
                        Picker("Format & Codec", selection: $controller.settings.videoCodec) {
                            Text("ProRes 422 (Default 60 FPS)").tag(VideoCodecPreset.proRes422)
                            Text(VideoCodecPreset.proRes422LT.rawValue).tag(VideoCodecPreset.proRes422LT)
                            Text(VideoCodecPreset.h264.rawValue).tag(VideoCodecPreset.h264)
                            Text(VideoCodecPreset.hevc.rawValue).tag(VideoCodecPreset.hevc)
                        }
                        .labelsHidden()
                        .help("Pilih format kontainer dan video codec. ProRes 422 direkomendasikan untuk stabilitas 60 FPS")
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
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.1"
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
                        Text("CC BY-SA 4.0")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }

                    Text("Hak Cipta © 2026 Wahyu Septiaji (@cutefishaep). Dilisensikan di bawah Creative Commons Attribution-ShareAlike 4.0 International.")
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

