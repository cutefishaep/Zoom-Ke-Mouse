import SwiftUI
import AppKit
import QuartzCore
import IOSurface

public struct CompositorCanvasView: NSViewRepresentable {
    public let controller: StudioController

    public init(controller: StudioController) {
        self.controller = controller
    }

    public func makeNSView(context: Context) -> StudioRenderNSView {
        let view = StudioRenderNSView()
        controller.attachCanvasView(view)
        view.updateLayoutAndSettings(settings: controller.settings, force: true)
        return view
    }

    public func updateNSView(_ nsView: StudioRenderNSView, context: Context) {
        controller.attachCanvasView(nsView)
        nsView.updateLayoutAndSettings(settings: controller.settings, force: false)
    }
}

/// Hardware GPU CoreAnimation Compositor View (Optimized for NootedRed.kext / 30-bit Framebuffer with zero unnecessary offscreen passes!)
public final class StudioRenderNSView: NSView {

    // GPU Layer Hierarchy
    private let rootLayer = CALayer()
    private let stageLayer = CALayer()
    private let bgGradientLayer = CAGradientLayer()
    private let bgImageLayer = CALayer()

    private let frameAssemblyLayer = CALayer()
    // 4 Outer-Edge Shadow Strip Layers (Center interior is 100% empty so GPU never composites shadow in the middle!)
    private let shadowTopLayer = CALayer()
    private let shadowBottomLayer = CALayer()
    private let shadowLeftLayer = CALayer()
    private let shadowRightLayer = CALayer()
    private let screenClipLayer = CALayer()
    private let zoomContainerLayer = CALayer()
    private let screenSurfaceLayer = CALayer()

    // Top-level HD Vector Cursor & Click Ripple Overlay
    private let cursorOverlayLayer = CALayer()
    private let cursorContainerLayer = CALayer()
    private let cursorShapeLayer = CAShapeLayer()
    private let cursorDotLayer = CAShapeLayer()
    private var ripplePool: [CAShapeLayer] = []
    private let rippleBaseRadius: CGFloat = 48.0

    private struct EdgeShadowCacheKey: Equatable {
        let screenRect: CGRect
        let cornerRadius: Int
        let shadowEnabled: Bool
        let opacityQ: Int
        let blurQ: Int
        let offsetXQ: Int
        let offsetYQ: Int
        let color: RGBAColor
    }

    // State
    public private(set) var currentSettings = StudioSettings()
    private var currentCamera = CameraRenderState()
    private var currentCursor = CursorRenderState()
    private var lastAppliedCamera = CameraRenderState(zoom: -1, focusCenter: .zero)
    private var lastAppliedCursor = CursorRenderState(location: CGPoint(x: -1, y: -1))
    private var sourcePixelSize = CGSize(width: 1920, height: 1080)
    private var screenRectInStage: CGRect = CGRect(x: 0, y: 0, width: 1280, height: 720)
    private var cachedBgURL: URL?
    private var lastShadowKey: EdgeShadowCacheKey?
    private var lastCursorStyle: CursorStyle?
    private var lastBoundsSize: CGSize = .zero

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupGPULayers()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupGPULayers()
    }

    private func setupGPULayers() {
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let retinaScale = min(2.0, NSScreen.main?.backingScaleFactor ?? 1.0)

        rootLayer.backgroundColor = CGColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
        rootLayer.isOpaque = true
        self.layer = rootLayer

        // Keep cornerRadius = 0 on stageLayer so WindowServer does a fast rectangular scissor clip instead of a 30-bit offscreen mask pass!
        stageLayer.masksToBounds = true
        stageLayer.cornerRadius = 0.0
        stageLayer.borderColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
        stageLayer.borderWidth = 1.0
        rootLayer.addSublayer(stageLayer)

        bgGradientLayer.startPoint = CGPoint(x: 0, y: 1)
        bgGradientLayer.endPoint = CGPoint(x: 1, y: 0)
        stageLayer.addSublayer(bgGradientLayer)

        bgImageLayer.contentsGravity = .resizeAspectFill
        bgImageLayer.masksToBounds = true
        bgImageLayer.isHidden = true
        stageLayer.addSublayer(bgImageLayer)

        frameAssemblyLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        stageLayer.addSublayer(frameAssemblyLayer)

        for sLayer in [shadowTopLayer, shadowBottomLayer, shadowLeftLayer, shadowRightLayer] {
            sLayer.contentsGravity = .resize
            sLayer.magnificationFilter = .linear
            sLayer.minificationFilter = .linear
            sLayer.isHidden = true
            frameAssemblyLayer.addSublayer(sLayer)
        }

        // Only enable masksToBounds on screenClipLayer when actively zooming in .insideFrame mode!
        screenClipLayer.masksToBounds = false
        frameAssemblyLayer.addSublayer(screenClipLayer)

        zoomContainerLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        screenClipLayer.addSublayer(zoomContainerLayer)

        // Leaf layer with .contents = ioSurface handles rounded corners directly in a single GPU shader pass!
        screenSurfaceLayer.contentsGravity = .resize
        screenSurfaceLayer.magnificationFilter = .linear
        screenSurfaceLayer.minificationFilter = .linear
        screenSurfaceLayer.masksToBounds = true
        screenSurfaceLayer.isOpaque = true
        zoomContainerLayer.addSublayer(screenSurfaceLayer)

        cursorOverlayLayer.masksToBounds = false
        rootLayer.addSublayer(cursorOverlayLayer)

        // Pre-build static circle path once so ripples scale purely on GPU without CPU path re-rasterization!
        let staticCircleRect = CGRect(
            x: -rippleBaseRadius,
            y: -rippleBaseRadius,
            width: rippleBaseRadius * 2.0,
            height: rippleBaseRadius * 2.0
        )
        let staticCirclePath = CGPath(ellipseIn: staticCircleRect, transform: nil)

        for _ in 0..<6 {
            let ripple = CAShapeLayer()
            ripple.contentsScale = retinaScale
            ripple.path = staticCirclePath
            ripple.isHidden = true
            cursorOverlayLayer.addSublayer(ripple)
            ripplePool.append(ripple)
        }

        cursorContainerLayer.contentsScale = retinaScale
        cursorShapeLayer.contentsScale = retinaScale
        cursorDotLayer.contentsScale = retinaScale
        cursorContainerLayer.addSublayer(cursorShapeLayer)
        cursorContainerLayer.addSublayer(cursorDotLayer)
        cursorOverlayLayer.addSublayer(cursorContainerLayer)

        rebuildCursorPath(style: .macOSPointer)
    }

    public override func layout() {
        super.layout()
        guard bounds.size != lastBoundsSize else { return }
        lastBoundsSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        recalculateStageGeometry()
        applyBackgroundAndShadowSettings()
        applyCameraAndCursorTransform(force: true)
        CATransaction.commit()
    }

    // MARK: - Zero-Copy GPU Frame Push

    public func pushGPUFrame(
        ioSurface: IOSurfaceRef?,
        fallbackCGImage: CGImage?,
        pixelSize: CGSize,
        camera: CameraRenderState,
        cursor: CursorRenderState,
        settings: StudioSettings
    ) {
        let sizeChanged = abs(pixelSize.width - sourcePixelSize.width) > 1 || abs(pixelSize.height - sourcePixelSize.height) > 1
        let settingsChanged = (settings != currentSettings)
        let surfaceChanged: Bool
        if let surface = ioSurface {
            surfaceChanged = (screenSurfaceLayer.contents as AnyObject? !== surface)
        } else if let cgImg = fallbackCGImage {
            surfaceChanged = (screenSurfaceLayer.contents as AnyObject? !== cgImg)
        } else {
            surfaceChanged = false
        }

        let cameraChanged = abs(camera.zoom - lastAppliedCamera.zoom) > 0.0005
            || abs(camera.focusCenter.x - lastAppliedCamera.focusCenter.x) > 0.0002
            || abs(camera.focusCenter.y - lastAppliedCamera.focusCenter.y) > 0.0002

        let cursorChanged = abs(cursor.location.x - lastAppliedCursor.location.x) > 0.0002
            || abs(cursor.location.y - lastAppliedCursor.location.y) > 0.0002
            || cursor.isPressed != lastAppliedCursor.isPressed
            || abs(cursor.opacity - lastAppliedCursor.opacity) > 0.01
            || cursor.ripples != lastAppliedCursor.ripples

        // Skip committing a CoreAnimation transaction if nothing changed on this tick!
        guard sizeChanged || settingsChanged || surfaceChanged || cameraChanged || cursorChanged else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if sizeChanged && pixelSize.width > 0 && pixelSize.height > 0 {
            sourcePixelSize = pixelSize
        }

        if settingsChanged || sizeChanged {
            currentSettings = settings
            recalculateStageGeometry()
            applyBackgroundAndShadowSettings()
        }

        if surfaceChanged {
            if let surface = ioSurface {
                screenSurfaceLayer.contents = surface
            } else if let cgImg = fallbackCGImage {
                screenSurfaceLayer.contents = cgImg
            }
        }

        currentCamera = camera
        currentCursor = cursor
        if cameraChanged || cursorChanged || settingsChanged || sizeChanged {
            applyCameraAndCursorTransform(force: settingsChanged || sizeChanged)
            lastAppliedCamera = camera
            lastAppliedCursor = cursor
        }

        CATransaction.commit()
    }

    public func updateLayoutAndSettings(settings: StudioSettings, force: Bool = false) {
        guard force || settings != currentSettings else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        currentSettings = settings
        recalculateStageGeometry()
        applyBackgroundAndShadowSettings()
        applyCameraAndCursorTransform(force: true)
        CATransaction.commit()
    }

    // MARK: - GPU Geometry & Transform Calculations

    private func recalculateStageGeometry() {
        guard bounds.width > 20 && bounds.height > 20 else { return }

        let targetAspectSize = currentSettings.aspectRatio.outputSize(
            forSource: sourcePixelSize,
            maxLongEdge: 1920
        )
        let outerInset = bounds.insetBy(dx: 12, dy: 12)
        let fittedStage = FrameCompositor.aspectFitRect(
            sourceSize: targetAspectSize,
            inside: outerInset.width > 40 && outerInset.height > 40 ? outerInset : bounds
        ).integral

        stageLayer.frame = fittedStage
        cursorOverlayLayer.frame = fittedStage

        let stageBounds = CGRect(origin: .zero, size: fittedStage.size)
        bgGradientLayer.frame = stageBounds
        bgImageLayer.frame = stageBounds

        frameAssemblyLayer.bounds = stageBounds
        frameAssemblyLayer.position = CGPoint(x: stageBounds.midX, y: stageBounds.midY)

        let resolutionScale = max(stageBounds.width, stageBounds.height) / 1920.0
        let scaledPadding = currentSettings.canvasPadding * resolutionScale
        let availableRect = stageBounds.insetBy(dx: scaledPadding, dy: scaledPadding)
        let sRect = FrameCompositor.aspectFitRect(
            sourceSize: sourcePixelSize,
            inside: availableRect.width > 20 && availableRect.height > 20 ? availableRect : stageBounds
        ).integral
        self.screenRectInStage = sRect

        let scaledRadius = min(
            currentSettings.cornerRadius * resolutionScale,
            min(sRect.width, sRect.height) * 0.25
        )
        let bWidth = currentSettings.insetBorderOpacity > 0.01 ? max(1.0, 1.5 * resolutionScale) : 0.0
        let bColor = CGColor(
            srgbRed: 1.0,
            green: 1.0,
            blue: 1.0,
            alpha: currentSettings.insetBorderOpacity
        )

        screenClipLayer.frame = sRect
        screenClipLayer.cornerRadius = scaledRadius
        screenClipLayer.borderWidth = bWidth
        screenClipLayer.borderColor = bColor

        let localScreenBounds = CGRect(origin: .zero, size: sRect.size)
        zoomContainerLayer.bounds = localScreenBounds
        zoomContainerLayer.position = CGPoint(x: sRect.width * 0.5, y: sRect.height * 0.5)
        screenSurfaceLayer.frame = localScreenBounds
        screenSurfaceLayer.cornerRadius = scaledRadius
    }

    private func applyBackgroundAndShadowSettings() {
        let stageBounds = stageLayer.bounds
        let resolutionScale = max(stageBounds.width, stageBounds.height) / 1920.0

        switch currentSettings.backgroundType {
        case .macWallpaper:
            if let cgImg = DesktopWallpaperHelper.currentMacWallpaperImage() {
                bgImageLayer.contents = cgImg
                bgImageLayer.isHidden = false
                bgGradientLayer.isHidden = true
            } else {
                bgImageLayer.isHidden = true
                bgGradientLayer.isHidden = false
            }

        case .gradient:
            bgImageLayer.isHidden = true
            bgGradientLayer.isHidden = false
            let presets = GradientPreset.allPresets
            let idx = max(0, min(presets.count - 1, currentSettings.selectedGradientIndex))
            let preset = presets[idx]
            bgGradientLayer.colors = preset.colors.map { $0.cgColor }
            bgGradientLayer.startPoint = CGPoint(x: preset.startPoint.x, y: 1.0 - preset.startPoint.y)
            bgGradientLayer.endPoint = CGPoint(x: preset.endPoint.x, y: 1.0 - preset.endPoint.y)

        case .solidColor:
            bgImageLayer.isHidden = true
            bgGradientLayer.isHidden = true
            stageLayer.backgroundColor = currentSettings.solidBackgroundColor.cgColor

        case .customImage:
            if let url = currentSettings.customBackgroundImageURL {
                if cachedBgURL != url {
                    cachedBgURL = url
                    if let nsImg = NSImage(contentsOf: url),
                       let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        bgImageLayer.contents = cgImg
                    }
                }
                bgImageLayer.isHidden = false
                bgGradientLayer.isHidden = true
            } else {
                bgImageLayer.isHidden = true
                bgGradientLayer.isHidden = false
            }
        }

        let scaledRadius = min(
            currentSettings.cornerRadius * resolutionScale,
            min(screenRectInStage.width, screenRectInStage.height) * 0.25
        )
        let shadowKey = EdgeShadowCacheKey(
            screenRect: screenRectInStage,
            cornerRadius: Int(round(scaledRadius * 2.0)),
            shadowEnabled: currentSettings.shadowEnabled,
            opacityQ: Int(round(currentSettings.shadowOpacity * 200.0)),
            blurQ: Int(round(currentSettings.shadowBlurRadius * 2.0)),
            offsetXQ: Int(round(currentSettings.shadowOffsetX * 2.0)),
            offsetYQ: Int(round(currentSettings.shadowOffsetY * 2.0)),
            color: currentSettings.shadowColor
        )

        if lastShadowKey != shadowKey {
            lastShadowKey = shadowKey
            if currentSettings.shadowEnabled && currentSettings.shadowOpacity > 0.005 {
                let shadowOffset = CGPoint(
                    x: currentSettings.shadowOffsetX * resolutionScale,
                    y: -currentSettings.shadowOffsetY * resolutionScale
                )
                let shadowBlur = max(1.0, currentSettings.shadowBlurRadius * resolutionScale)
                let strips = FrameCompositor.computeEdgeShadowStripRects(
                    screenRect: screenRectInStage,
                    cornerRadius: scaledRadius,
                    shadowOffset: shadowOffset,
                    shadowBlur: shadowBlur
                )
                let pairs: [(CALayer, CGRect)] = [
                    (shadowTopLayer, strips.top),
                    (shadowBottomLayer, strips.bottom),
                    (shadowLeftLayer, strips.left),
                    (shadowRightLayer, strips.right)
                ]
                for (sLayer, sRect) in pairs {
                    if let img = FrameCompositor.makeEdgeShadowStripImage(
                        stripRect: sRect,
                        screenRect: screenRectInStage,
                        cornerRadius: scaledRadius,
                        shadowOffset: shadowOffset,
                        shadowBlur: shadowBlur,
                        shadowColor: currentSettings.shadowColor,
                        shadowOpacity: currentSettings.shadowOpacity,
                        downsampleScale: 0.5
                    ) {
                        sLayer.frame = sRect
                        sLayer.contents = img
                        sLayer.isHidden = false
                    } else {
                        sLayer.isHidden = true
                    }
                }
            } else {
                for sLayer in [shadowTopLayer, shadowBottomLayer, shadowLeftLayer, shadowRightLayer] {
                    sLayer.isHidden = true
                }
            }
        }

        if lastCursorStyle != currentSettings.cursorStyle {
            lastCursorStyle = currentSettings.cursorStyle
            rebuildCursorPath(style: currentSettings.cursorStyle)
        }
    }

    private func applyCameraAndCursorTransform(force: Bool = false) {
        let W = screenRectInStage.width
        let H = screenRectInStage.height
        guard W > 10 && H > 10 else { return }

        let stageBounds = stageLayer.bounds
        let resolutionScale = max(stageBounds.width, stageBounds.height) / 1920.0

        let zoom = max(1.0, currentCamera.zoom)
        let focus = ZoomCameraEngine.clampViewportCenter(currentCamera.focusCenter, zoom: zoom)

        let dx = (0.5 - focus.x) * W
        let dy = (focus.y - 0.5) * H

        var transform = CATransform3DIdentity
        if zoom > 1.001 {
            transform = CATransform3DTranslate(transform, dx * zoom, dy * zoom, 0.0)
            transform = CATransform3DScale(transform, zoom, zoom, 1.0)
        }

        switch currentSettings.zoomFrameMode {
        case .wholeFrame:
            if screenClipLayer.masksToBounds {
                screenClipLayer.masksToBounds = false
            }
            frameAssemblyLayer.transform = transform
            zoomContainerLayer.transform = CATransform3DIdentity

        case .insideFrame:
            let needsClip = (zoom > 1.002)
            if screenClipLayer.masksToBounds != needsClip {
                screenClipLayer.masksToBounds = needsClip
            }
            frameAssemblyLayer.transform = CATransform3DIdentity
            zoomContainerLayer.transform = transform
        }

        // Update Vector Cursor Position & Scale OUTSIDE the frame
        if currentSettings.showCursor && currentCursor.opacity > 0.01 {
            cursorContainerLayer.isHidden = false
            cursorContainerLayer.opacity = Float(currentCursor.opacity)

            let cursorStageX = screenRectInStage.midX + (currentCursor.location.x - focus.x) * W * zoom
            let cursorStageY = screenRectInStage.midY + (focus.y - currentCursor.location.y) * H * zoom
            cursorContainerLayer.position = CGPoint(x: cursorStageX, y: cursorStageY)

            let zoomFactor: CGFloat = currentSettings.scaleCursorWithZoom ? pow(zoom, 0.35) : 1.0
            let squish: CGFloat = (currentSettings.clickSquishEffect && currentCursor.isPressed) ? 0.84 : 1.0
            let totalScale = currentSettings.cursorScale * resolutionScale * zoomFactor * squish
            cursorContainerLayer.transform = CATransform3DMakeScale(totalScale, totalScale, 1.0)

            if currentSettings.cursorStyle == .touchCircle {
                cursorDotLayer.fillColor = currentCursor.isPressed
                    ? currentSettings.clickRippleColor.cgColor
                    : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            }
        } else {
            cursorContainerLayer.isHidden = true
        }

        // Update Active Click Ripples using GPU scale transform (zero CGPath reallocation!)
        let activeRipples = currentSettings.clickRippleEnabled ? currentCursor.ripples : []
        let zoomComp: CGFloat = currentSettings.scaleCursorWithZoom ? pow(zoom, 0.35) : 1.0
        let maxR = currentSettings.clickRippleMaxRadius * resolutionScale * zoomComp

        for (idx, rippleLayer) in ripplePool.enumerated() {
            if idx < activeRipples.count {
                let r = activeRipples[idx]
                let clamped = max(0.0, min(1.0, r.progress))
                let easeOut = 1.0 - pow(1.0 - clamped, 3.0)
                let fadeAlpha = pow(1.0 - clamped, 1.65)
                let radius = max(4.0, maxR * (0.20 + 0.80 * easeOut))
                let scale = max(0.05, radius / rippleBaseRadius)
                let baseColor = r.isRightClick ? currentSettings.rightClickRippleColor : currentSettings.clickRippleColor

                let rx = screenRectInStage.midX + (r.location.x - focus.x) * W * zoom
                let ry = screenRectInStage.midY + (focus.y - r.location.y) * H * zoom

                rippleLayer.isHidden = false
                rippleLayer.position = CGPoint(x: rx, y: ry)
                rippleLayer.transform = CATransform3DMakeScale(scale, scale, 1.0)
                rippleLayer.fillColor = CGColor(
                    srgbRed: CGFloat(baseColor.r),
                    green: CGFloat(baseColor.g),
                    blue: CGFloat(baseColor.b),
                    alpha: CGFloat(baseColor.a) * fadeAlpha * 0.28
                )
                rippleLayer.strokeColor = CGColor(
                    srgbRed: CGFloat(baseColor.r),
                    green: CGFloat(baseColor.g),
                    blue: CGFloat(baseColor.b),
                    alpha: CGFloat(baseColor.a) * fadeAlpha * 0.92
                )
                rippleLayer.lineWidth = max(1.5, 3.0 * resolutionScale * zoomComp * (1.0 - 0.4 * clamped)) / scale
            } else if !rippleLayer.isHidden {
                rippleLayer.isHidden = true
            }
        }
    }

    private func rebuildCursorPath(style: CursorStyle) {
        switch style {
        case .macOSPointer:
            let arrowPath = CGMutablePath()
            arrowPath.move(to: CGPoint(x: 0.0, y: 0.0))
            arrowPath.addLine(to: CGPoint(x: 0.0, y: -24.0))
            arrowPath.addLine(to: CGPoint(x: 5.2, y: -18.8))
            arrowPath.addLine(to: CGPoint(x: 9.4, y: -27.2))
            arrowPath.addLine(to: CGPoint(x: 12.8, y: -25.5))
            arrowPath.addLine(to: CGPoint(x: 8.7, y: -17.0))
            arrowPath.addLine(to: CGPoint(x: 16.2, y: -17.0))
            arrowPath.closeSubpath()

            cursorShapeLayer.path = arrowPath
            cursorShapeLayer.shadowPath = nil
            cursorShapeLayer.fillColor = CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
            cursorShapeLayer.strokeColor = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            cursorShapeLayer.lineWidth = 2.0
            cursorShapeLayer.lineJoin = .round
            cursorShapeLayer.lineCap = .round
            cursorDotLayer.isHidden = true

        case .touchCircle:
            let radius: CGFloat = 12.0
            let circleRect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            let cPath = CGPath(ellipseIn: circleRect, transform: nil)
            cursorShapeLayer.path = cPath
            cursorShapeLayer.shadowPath = nil
            cursorShapeLayer.fillColor = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.28)
            cursorShapeLayer.strokeColor = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98)
            cursorShapeLayer.lineWidth = 2.4

            let dotR: CGFloat = 3.5
            cursorDotLayer.isHidden = false
            cursorDotLayer.path = CGPath(ellipseIn: CGRect(x: -dotR, y: -dotR, width: dotR * 2, height: dotR * 2), transform: nil)
            cursorDotLayer.fillColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

        case .crosshair:
            let path = CGMutablePath()
            let arm: CGFloat = 12.0
            path.move(to: CGPoint(x: -arm, y: 0))
            path.addLine(to: CGPoint(x: arm, y: 0))
            path.move(to: CGPoint(x: 0, y: -arm))
            path.addLine(to: CGPoint(x: 0, y: arm))
            let ringR: CGFloat = 6.5
            path.addEllipse(in: CGRect(x: -ringR, y: -ringR, width: ringR * 2, height: ringR * 2))

            cursorShapeLayer.path = path
            cursorShapeLayer.shadowPath = nil
            cursorShapeLayer.fillColor = nil
            cursorShapeLayer.strokeColor = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98)
            cursorShapeLayer.lineWidth = 2.2
            cursorDotLayer.isHidden = true
        }
    }
}
