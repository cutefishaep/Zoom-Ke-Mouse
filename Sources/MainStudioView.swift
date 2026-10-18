import SwiftUI
import AppKit

public enum InspectorTab: String, CaseIterable, Identifiable {
    case zoom = "Auto Zoom"
    case background = "Background"
    case shadow = "Drop Shadow"
    case mouse = "Mouse & Klik"
    case audioOutput = "Audio & Output"

    public var id: String { rawValue }

    public func title(_ lang: AppLanguage) -> String {
        switch (self, lang) {
        case (.zoom, _): return "Auto Zoom"
        case (.background, _): return "Background"
        case (.shadow, _): return "Drop Shadow"
        case (.mouse, .id): return "Mouse & Klik"
        case (.mouse, .en): return "Mouse & Click"
        case (.audioOutput, _): return "Audio & Output"
        }
    }

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

    private var lang: AppLanguage {
        controller.settings.appLanguage
    }

    private func tr(_ idText: String, _ enText: String) -> String {
        lang == .en ? enText : idText
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
                        Text(tr("Izin Rekam belum aktif", "Screen Recording Permission Required"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                        Button(tr("Buka Izin", "Grant Access")) {
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
                // Button 1: Fullscreen / Windowed Mode (Menu Button)
                Menu {
                    Button(action: {
                        controller.selectCaptureTargetMode(.fullScreen)
                    }) {
                        let title = tr("Layar Penuh (Selayar)", "Full Screen")
                        if controller.captureTargetMode == .fullScreen {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }

                    Button(action: {
                        controller.selectCaptureTargetMode(.appWindow)
                    }) {
                        let title = tr("Jendela Aplikasi", "Application Window")
                        if controller.captureTargetMode == .appWindow {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
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

                        Toggle(tr("Sembunyikan App Ini", "Hide This App"), isOn: Binding(
                            get: { controller.excludeOwnAppWindow },
                            set: { val in
                                controller.excludeOwnAppWindow = val
                                controller.restartScreenCaptureStream()
                            }
                        ))
                    } else {
                        if controller.availableAppWindows.isEmpty {
                            Text(tr("Tidak ada jendela lain", "No other windows available"))
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

                    Button(tr("Muat Ulang Layar & Jendela", "Refresh Displays & Windows")) {
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
                .help(tr("Pilih mode rekam Fullscreen atau Windowed", "Choose Fullscreen or Windowed capture mode"))

                Spacer()

                // Button 2: Red Squircle Record Button
                Button(action: {
                    controller.toggleRecording()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: controller.mode == .recording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text(controller.mode == .recording ? "Stop" : tr("Rekam", "Record"))
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
                .help(controller.mode == .recording
                      ? tr("Hentikan perekaman dan simpan video (⌘R)", "Stop recording and save video (⌘R)")
                      : tr("Mulai merekam (⌘R)", "Start recording (⌘R)"))

                Spacer()

                // Button 3: Settings Pop-up Button
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
                .help(tr("Buka pengaturan Auto Zoom, Background, Shadow, Mouse, dan Audio", "Open Auto Zoom, Background, Shadow, Mouse, and Audio settings"))
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
            AboutStudioSheetView(
                isPresented: $showAboutSheet,
                lang: controller.settings.appLanguage
            )
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

    private var lang: AppLanguage {
        controller.settings.appLanguage
    }

    private func tr(_ idText: String, _ enText: String) -> String {
        lang == .en ? enText : idText
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Pop-up: Settings Icon + "Settings" Title + Language Switcher + Done
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.accentColor)
                    Text("Settings")
                        .font(.system(size: 13.5, weight: .bold))
                }

                Spacer()

                // Multi-Language Switcher (Indonesia / English)
                HStack(spacing: 2) {
                    ForEach(AppLanguage.allCases) { item in
                        let active = (controller.settings.appLanguage == item)
                        Button(action: {
                            controller.settings.appLanguage = item
                        }) {
                            Text(item.displayName)
                                .font(.system(size: 11, weight: active ? .bold : .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(active ? Color.accentColor.opacity(0.22) : Color.clear)
                                )
                                .foregroundColor(active ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                .help(tr("Ganti bahasa antarmuka (Indonesia / English)", "Switch interface language (Indonesian / English)"))

                Button(action: {
                    onOpenAbout()
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(tr("Tentang Aplikasi & Lisensi", "About Application & License"))

                Button(tr("Selesai", "Done")) {
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
                            Text(tab.title(lang))
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
            Text(tr("Pengaturan Real-Time Auto Zoom", "Real-Time Auto Zoom Settings"))
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(tr("Auto-Zoom Saat Klik Mouse", "Auto-Zoom on Mouse Click"), isOn: $controller.settings.autoZoomEnabled)
                        .font(.system(size: 12, weight: .semibold))

                    if !controller.settings.autoZoomEnabled {
                        Toggle(tr("Selalu Zoom (Ikuti Kursor)", "Always Zoom (Follow Cursor)"), isOn: $controller.settings.alwaysZoomWhenClickDisabled)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Mode Bingkai Zoom", "Zoom Frame Mode"))
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.zoomFrameMode) {
                            ForEach(ZoomFrameMode.allCases) { zMode in
                                Text(zMode.label(lang)).tag(zMode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Skala Zoom", "Zoom Scale"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.2fx", controller.settings.defaultZoomScale))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                        }
                        Slider(value: $controller.settings.defaultZoomScale, in: 1.2...4.0, step: 0.05)
                    }

                    if controller.settings.autoZoomEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tr("Durasi Tahan Zoom", "Zoom Hold Duration"))
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(String(format: "%.1fs", controller.settings.zoomHoldDuration))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                            Slider(value: $controller.settings.zoomHoldDuration, in: 0.5...5.0, step: 0.1)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Kecepatan Transisi", "Transition Speed"))
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

            GroupBox(label: Text(tr("Kamera", "Camera")).font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(tr("Ikuti Kursor Saat Zoom", "Follow Cursor While Zoomed"), isOn: $controller.settings.followMouseWhenZoomed)
                        .font(.system(size: 12, weight: .medium))

                    if controller.settings.followMouseWhenZoomed {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tr("Kelembutan Kamera", "Camera Smoothness"))
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
            Text(tr("Background & Kanvas", "Background & Canvas"))
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text(tr("Jenis Background", "Background Type"))
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
                                    Text(bgType.label(lang))
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
                            Text(tr("Menggunakan wallpaper aktif macOS Anda", "Using your active macOS desktop wallpaper"))
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(tr("Segarkan", "Refresh")) {
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
                            tr("Warna Solid", "Solid Color"),
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
                                Label(tr("Pilih Gambar...", "Choose Image..."), systemImage: "folder.badge.plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(6)
            }

            GroupBox(label: Text(tr("Ukuran & Bingkai", "Size & Frame")).font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Aspek Rasio", "Aspect Ratio"))
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
                            Text(tr("Sudut Melengkung", "Corner Radius"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.cornerRadius)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.cornerRadius, in: 0...44, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Garis Tepi", "Border Opacity"))
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
                    Toggle(tr("Aktifkan Shadow", "Enable Drop Shadow"), isOn: $controller.settings.shadowEnabled)
                        .font(.system(size: 12, weight: .semibold))

                    Divider()

                    HStack(spacing: 6) {
                        Button(tr("Lembut", "Soft")) {
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

                        Button(tr("Gelap", "Dark")) {
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
                            Text(tr("Kepekatan", "Opacity"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.shadowOpacity * 100))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.shadowOpacity, in: 0.0...1.0, step: 0.02)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Radius Blur", "Blur Radius"))
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
                        tr("Warna", "Shadow Color"),
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
            Text(tr("Kursor & Klik", "Cursor & Clicks"))
                .font(.system(size: 13, weight: .bold))

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(tr("Tampilkan Kursor", "Show Cursor"), isOn: $controller.settings.showCursor)
                        .font(.system(size: 12, weight: .semibold))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Bentuk Kursor", "Cursor Style"))
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.cursorStyle) {
                            ForEach(CursorStyle.allCases) { style in
                                Text(style.label(lang)).tag(style)
                            }
                        }
                        .labelsHidden()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Ukuran Kursor", "Cursor Size"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.2fx", controller.settings.cursorScale))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.cursorScale, in: 0.75...3.5, step: 0.05)
                    }

                    Divider()

                    Toggle(tr("Perhalus Gerakan", "Smooth Cursor Movement"), isOn: $controller.settings.smoothMouseMovement)
                        .font(.system(size: 12, weight: .medium))

                    if controller.settings.smoothMouseMovement {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tr("Kelembutan", "Smoothness"))
                                    .font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(String(format: "%.0f%%", (1.0 - controller.settings.mouseSmoothingFactor) * 100))
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            Slider(value: $controller.settings.mouseSmoothingFactor, in: 0.08...0.50, step: 0.02)
                        }
                    }

                    Toggle(tr("Perbesar Saat Zoom", "Scale Cursor With Zoom"), isOn: $controller.settings.scaleCursorWithZoom)
                        .font(.system(size: 11, weight: .medium))

                    Toggle(tr("Sembunyikan Saat Diam", "Hide Cursor When Idle"), isOn: $controller.settings.hideCursorWhenIdle)
                        .font(.system(size: 11, weight: .medium))
                }
                .padding(6)
            }

            GroupBox(label: Text(tr("Efek & Animasi Klik", "Click Effects & Animation")).font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(tr("Aktifkan Animasi Klik", "Enable Click Animation"), isOn: $controller.settings.clickRippleEnabled)
                        .font(.system(size: 12, weight: .semibold))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Gaya Animasi Klik", "Click Animation Style"))
                            .font(.system(size: 11, weight: .medium))
                        Picker("", selection: $controller.settings.clickAnimationStyle) {
                            ForEach(ClickAnimationStyle.allCases) { animStyle in
                                Text(animStyle.label(lang)).tag(animStyle)
                            }
                        }
                        .labelsHidden()
                    }
                    .disabled(!controller.settings.clickRippleEnabled)
                    .opacity(controller.settings.clickRippleEnabled ? 1.0 : 0.6)

                    Toggle(tr("Efek Tekan Kursor (Squish)", "Cursor Squish on Click"), isOn: $controller.settings.clickSquishEffect)
                        .font(.system(size: 11, weight: .medium))

                    ColorPicker(
                        tr("Warna Klik Kiri", "Left Click Color"),
                        selection: Binding(
                            get: { controller.settings.clickRippleColor.swiftUIColor },
                            set: { controller.settings.clickRippleColor = RGBAColor(nsColor: NSColor($0)) }
                        )
                    )
                    .font(.system(size: 11, weight: .medium))

                    ColorPicker(
                        tr("Warna Klik Kanan", "Right Click Color"),
                        selection: Binding(
                            get: { controller.settings.rightClickRippleColor.swiftUIColor },
                            set: { controller.settings.rightClickRippleColor = RGBAColor(nsColor: NSColor($0)) }
                        )
                    )
                    .font(.system(size: 11, weight: .medium))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Radius Maksimal", "Max Radius"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(controller.settings.clickRippleMaxRadius)) px")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.clickRippleMaxRadius, in: 20...90, step: 2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Durasi Animasi", "Animation Duration"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.2fs", controller.settings.clickRippleDuration))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.clickRippleDuration, in: 0.20...1.20, step: 0.05)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Ketebalan Garis Cincin", "Ring Stroke Thickness"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text(String(format: "%.1f px", controller.settings.clickRippleLineWidth))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.clickRippleLineWidth, in: 1.5...8.0, step: 0.5)
                    }
                    .disabled(controller.settings.clickAnimationStyle == .softGlow)
                    .opacity(controller.settings.clickAnimationStyle == .softGlow ? 0.6 : 1.0)
                }
                .padding(6)
            }
        }
    }

    // MARK: - 5. Audio & Output Inspector
    private var audioOutputInspectorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("Pengaturan Audio & Kualitas Output", "Audio & Output Quality Settings"))
                .font(.system(size: 13, weight: .bold))

            // GroupBox 1: System Audio
            GroupBox(label: Text(tr("Audio Sistem & Desktop", "System & Desktop Audio")).font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(tr("Rekam Audio Sistem", "Record System Audio"), isOn: $controller.settings.isSystemAudioEnabled)
                        .font(.system(size: 12, weight: .semibold))
                        .help(tr("Rekam suara output desktop dan aplikasi Mac Anda", "Record internal audio from your Mac desktop and apps"))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Volume Audio Sistem", "System Audio Volume"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(round(controller.settings.systemAudioVolume * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.systemAudioVolume, in: Float(0.0)...Float(2.0), step: Float(0.05))
                            .help(tr("Atur tingkat gain / volume rekaman audio sistem (0% - 200%)", "Adjust system audio recording gain (0% - 200%)"))
                    }
                    .disabled(!controller.settings.isSystemAudioEnabled)
                    .opacity(controller.settings.isSystemAudioEnabled ? 1.0 : 0.6)
                }
                .padding(6)
            }

            // GroupBox 2: Microphone
            GroupBox(label: Text(tr("Mikrofon & Input Suara", "Microphone & Voice Input")).font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(tr("Rekam Mikrofon", "Record Microphone"), isOn: $controller.settings.isMicAudioEnabled)
                        .font(.system(size: 12, weight: .semibold))
                        .help(tr("Rekam narasi suara dari mikrofon selama perekaman layar", "Record voice narration from your microphone"))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Perangkat Mikrofon", "Microphone Device"))
                            .font(.system(size: 11, weight: .medium))

                        let devices = AudioCaptureManager.shared.availableDevices()
                        let autoName = devices.first?.name ?? "Default Microphone"
                        Picker(tr("Perangkat Mikrofon", "Microphone Device"), selection: $controller.settings.micDeviceUID) {
                            Text(tr("Otomatis (\(autoName))", "Auto (\(autoName))")).tag(String?.none)
                            ForEach(devices) { dev in
                                Text(dev.name).tag(String?.some(dev.id))
                            }
                        }
                        .labelsHidden()
                        .help(tr("Pilih perangkat input mikrofon yang digunakan untuk merekam", "Select the microphone input device for recording"))
                    }
                    .disabled(!controller.settings.isMicAudioEnabled)
                    .opacity(controller.settings.isMicAudioEnabled ? 1.0 : 0.6)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tr("Volume / Gain Mikrofon", "Microphone Volume / Gain"))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Text("\(Int(round(controller.settings.micAudioVolume * 100)))%")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        Slider(value: $controller.settings.micAudioVolume, in: Float(0.0)...Float(3.0), step: Float(0.05))
                            .help(tr("Atur tingkat gain / volume input mikrofon (0% - 300%)", "Adjust microphone input gain (0% - 300%)"))
                    }
                    .disabled(!controller.settings.isMicAudioEnabled)
                    .opacity(controller.settings.isMicAudioEnabled ? 1.0 : 0.6)

                    if controller.settings.isMicAudioEnabled && controller.hasMicrophonePermission {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "mic.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 10))
                                Text(tr("Level Suara Mikrofon", "Mic Input Level"))
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", min(100, controller.liveMicInputLevel * 100)))
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.primary.opacity(0.10))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(
                                            LinearGradient(
                                                colors: [.green, .yellow, .orange],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(2, geo.size.width * CGFloat(min(1.0, controller.liveMicInputLevel))))
                                        .animation(.linear(duration: 0.12), value: controller.liveMicInputLevel)
                                }
                            }
                            .frame(height: 6)
                        }
                    } else if controller.settings.isMicAudioEnabled && !controller.hasMicrophonePermission {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.system(size: 11))
                            Text(tr("Izin mikrofon belum aktif", "Microphone permission required"))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(tr("Buka Izin", "Grant Access")) {
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

            // GroupBox 3: Video Format & Quality
            GroupBox(label: Text(tr("Format & Kualitas Video (Presets)", "Video Format & Quality (Presets)")).font(.system(size: 11, weight: .bold))) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Target Resolusi", "Target Resolution"))
                            .font(.system(size: 11, weight: .medium))
                        Picker(tr("Target Resolusi", "Target Resolution"), selection: $controller.settings.videoResolution) {
                            ForEach(VideoResolutionTarget.allCases) { res in
                                Text(res.label(lang)).tag(res)
                            }
                        }
                        .labelsHidden()
                        .help(tr("Pilih resolusi target video hasil rekaman", "Select target resolution for recorded video"))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Frame Rate")
                            .font(.system(size: 11, weight: .medium))
                        Picker("Frame Rate", selection: $controller.settings.videoFrameRate) {
                            Text(tr("60 FPS (Mulus)", "60 FPS (Smooth)")).tag(VideoFrameRateTarget.fps60)
                            Text("30 FPS").tag(VideoFrameRateTarget.fps30)
                        }
                        .labelsHidden()
                        .help(tr("Pilih target frame rate video rekaman (60 FPS direkomendasikan)", "Select target recording frame rate (60 FPS recommended)"))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("Format & Codec", "Format & Codec"))
                            .font(.system(size: 11, weight: .medium))
                        Picker(tr("Format & Codec", "Format & Codec"), selection: $controller.settings.videoCodec) {
                            ForEach(VideoCodecPreset.allCases) { codec in
                                Text(codec.label(lang)).tag(codec)
                            }
                        }
                        .labelsHidden()
                        .help(tr("Pilih format kontainer dan video codec. ProRes 422 direkomendasikan untuk stabilitas 60 FPS", "Select container format and video codec. ProRes 422 is recommended for smooth 60 FPS"))
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
    var lang: AppLanguage = .id

    private func tr(_ idText: String, _ enText: String) -> String {
        lang == .en ? enText : idText
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.4"
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

                Text("\(tr("Versi", "Version")) \(appVersion) (\(bundleIdentifier))")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Text(tr(
                "Perekam layar macOS dengan auto-zoom mengikuti posisi dan klik kursor secara real-time.",
                "macOS screen recorder with real-time auto-zoom following cursor movement and clicks."
            ))
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(tr("Pembuat", "Author"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Wahyu Septiaji (@cutefishaep)")
                            .font(.system(size: 11.5, weight: .semibold))
                    }

                    Divider()

                    HStack {
                        Text(tr("Repositori", "Repository"))
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
                        Text(tr("Lisensi", "License"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("CC BY-SA 4.0")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }

                    Text(tr(
                        "Hak Cipta © 2026 Wahyu Septiaji (@cutefishaep). Dilisensikan di bawah Creative Commons Attribution-ShareAlike 4.0 International.",
                        "Copyright © 2026 Wahyu Septiaji (@cutefishaep). Licensed under Creative Commons Attribution-ShareAlike 4.0 International."
                    ))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button(tr("Tutup", "Close")) {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 400)
    }
}


