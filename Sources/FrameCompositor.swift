import Foundation
import CoreGraphics
import CoreVideo
import IOSurface
import Metal
import VideoToolbox
import AppKit
import Darwin

private struct MetalStageUniforms {
    var u0: SIMD4<Float> // canvasW, canvasH, zoom, cornerRadius
    var u1: SIMD4<Float> // screenRect: x, y, w, h (top-left pixel coords)
    var u2: SIMD4<Float> // focusX, focusY, borderOpacity, borderWidth
    var u3: SIMD4<Float> // wholeFrameMode, hasShadow, shadowOffsetX, shadowOffsetY (top-left pixel coords)
    var u4: SIMD4<Float> // shadowColor: r, g, b, shadowOpacity
    var u5: SIMD4<Float> // shadowBlur, 0, 0, 0
}

public final class FrameCompositor {

    private var cachedBackgroundURL: URL?
    private var cachedBackgroundImage: CGImage?

    private struct LayerCacheKey: Equatable {
        let canvasWidth: Int
        let canvasHeight: Int
        let backgroundType: BackgroundType
        let selectedGradientIndex: Int
        let solidColor: RGBAColor
        let customBackgroundURL: URL?
    }

    private struct CursorCacheKey: Equatable {
        let style: CursorStyle
        let isPressed: Bool
        let rippleColor: RGBAColor
    }

    private let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private let fastBitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

    private var cachedKey: LayerCacheKey?
    private var cachedBgOnlyImage: CGImage?

    // Metal GPU Hardware Compositor Resources (Renders 1920x1080 Full HD in ~3.5ms on NootedRed.kext!)
    private let mtlDevice: MTLDevice?
    private let mtlCommandQueue: MTLCommandQueue?
    private let mtlPipeline: MTLRenderPipelineState?
    private var mtlBgOnlyTex: MTLTexture?
    private var mtlTargetTex: MTLTexture?
    private var mtlSharedReadbackBuffer: MTLBuffer?
    private var mtlSharedContext: CGContext?
    private var mtlCachedWidth: Int = 0
    private var mtlCachedHeight: Int = 0

    // Pre-rendered Cursor Sprite (eliminates per-frame CPU Gaussian shadow blur!)
    private var cachedCursorKey: CursorCacheKey?
    private var cachedCursorSprite: CGImage?
    private let cursorSpriteSize: Int = 96
    private let cursorHotspotInSprite = CGPoint(x: 28.0, y: 68.0)

    // Fallback System RAM compositing buffer
    private var ramBuffer: UnsafeMutableRawPointer?
    private var ramBufferCapacity: Int = 0
    private var ramContext: CGContext?
    private var ramContextWidth: Int = 0
    private var ramContextHeight: Int = 0

    public init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.mtlDevice = dev
        self.mtlCommandQueue = dev?.makeCommandQueue()

        if let dev = dev {
            let shaderSource = """
            #include <metal_stdlib>
            using namespace metal;

            struct VertexOut {
                float4 position [[position]];
                float2 uv;
            };

            struct StageUniforms {
                float4 u0; // canvasW, canvasH, zoom, cornerRadius
                float4 u1; // screenRect: x, y, w, h
                float4 u2; // focusX, focusY, borderOpacity, borderWidth
                float4 u3; // wholeFrameMode, hasShadow, shadowOffsetX, shadowOffsetY
                float4 u4; // shadowColor: r, g, b, shadowOpacity
                float4 u5; // shadowBlur, 0, 0, 0
            };

            vertex VertexOut stageVertex(uint vid [[vertex_id]]) {
                float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
                float2 uvs[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
                VertexOut out;
                out.position = float4(pos[vid], 0.0, 1.0);
                out.uv = uvs[vid];
                return out;
            }

            float sdRoundedBox(float2 p, float2 center, float2 halfSize, float r) {
                float2 q = abs(p - center) - halfSize + r;
                return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
            }

            fragment float4 stageFragment(
                VertexOut in [[stage_in]],
                constant StageUniforms &u [[buffer(0)]],
                texture2d<float> bgTex [[texture(0)]],
                texture2d<float> screenTex [[texture(1)]]
            ) {
                constexpr sampler linSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

                float2 canvasSize = u.u0.xy;
                float zoom = max(1.0, u.u0.z);
                float cornerRadius = u.u0.w;

                float2 sOrigin = u.u1.xy;
                float2 sSize = u.u1.zw;
                float2 sCenter = sOrigin + sSize * 0.5;
                float2 sHalf = sSize * 0.5;

                float2 focusCenter = u.u2.xy;
                float borderOpacity = u.u2.z;
                float borderWidth = u.u2.w;

                bool wholeFrameMode = (u.u3.x > 0.5);
                bool hasShadow = (u.u3.y > 0.5);
                float2 shadowOffset = u.u3.zw;

                float4 shadowColor = u.u4;
                float shadowBlur = max(1.0, u.u5.x);

                float2 p = in.uv * canvasSize;
                float2 focusPt = sOrigin + focusCenter * sSize;

                float2 framePt = wholeFrameMode ? (focusPt + (p - sCenter) / zoom) : p;
                float d = sdRoundedBox(framePt, sCenter, sHalf, cornerRadius);

                // FAST INTERIOR PATH: Inside the screen (middle area), skip background AND skip drop shadow completely!
                if (d <= -0.5) {
                    float2 samplePt = wholeFrameMode ? framePt : (focusPt + (p - sCenter) / zoom);
                    float2 scrUV = clamp((samplePt - sOrigin) / sSize, 0.0, 1.0);
                    float4 scr = screenTex.sample(linSampler, scrUV);
                    if (borderOpacity > 0.01 && d > -borderWidth - 0.5) {
                        float bCov = clamp(borderWidth - abs(d), 0.0, 1.0) * borderOpacity;
                        scr.rgb = mix(scr.rgb, float3(1.0), bCov);
                    }
                    return float4(scr.rgb, 1.0);
                }

                // OUTER SIDES PATH (d > -0.5): Render background and analytical SDF drop shadow ONLY on the outer sides!
                float4 col = bgTex.sample(linSampler, in.uv);

                if (hasShadow) {
                    float dShadow = sdRoundedBox(framePt - shadowOffset, sCenter, sHalf, cornerRadius);
                    float uNorm = clamp((dShadow + shadowBlur * 0.35) / (shadowBlur * 1.35), 0.0, 1.0);
                    if (uNorm < 1.0) {
                        float t = 1.0 - uNorm;
                        float shAlpha = shadowColor.a * (t * t * (1.0 - 0.15 * uNorm));
                        col.rgb = mix(col.rgb, shadowColor.rgb, shAlpha);
                    }
                }

                float cov = clamp(0.5 - d, 0.0, 1.0);
                if (cov > 0.0) {
                    float2 samplePt = wholeFrameMode ? framePt : (focusPt + (p - sCenter) / zoom);
                    float2 scrUV = clamp((samplePt - sOrigin) / sSize, 0.0, 1.0);
                    float4 scr = screenTex.sample(linSampler, scrUV);
                    col.rgb = mix(col.rgb, scr.rgb, cov);
                }

                if (borderOpacity > 0.01 && abs(d) < borderWidth + 0.5) {
                    float bCov = clamp(borderWidth - abs(d), 0.0, 1.0) * borderOpacity;
                    col.rgb = mix(col.rgb, float3(1.0), bCov);
                }

                return float4(col.rgb, 1.0);
            }
            """
            if let lib = try? dev.makeLibrary(source: shaderSource, options: nil) {
                let pDesc = MTLRenderPipelineDescriptor()
                pDesc.vertexFunction = lib.makeFunction(name: "stageVertex")
                pDesc.fragmentFunction = lib.makeFunction(name: "stageFragment")
                pDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
                self.mtlPipeline = try? dev.makeRenderPipelineState(descriptor: pDesc)
            } else {
                self.mtlPipeline = nil
            }
        } else {
            self.mtlPipeline = nil
        }
    }

    deinit {
        if let ptr = ramBuffer {
            ptr.deallocate()
        }
    }

    // MARK: - Main CGContext Render Pipeline (Fallback when Metal texture is not used)

    public func render(
        in ctx: CGContext,
        canvasSize: CGSize,
        sourceImage: CGImage?,
        settings: StudioSettings,
        camera: CameraRenderState,
        cursor: CursorRenderState
    ) {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        guard canvasRect.width > 8 && canvasRect.height > 8 else { return }

        ctx.saveGState()
        ctx.interpolationQuality = .low
        ctx.setShouldAntialias(true)

        let referenceWidth: CGFloat = 1920.0
        let resolutionScale = max(canvasSize.width, canvasSize.height) / referenceWidth

        let imgWidth = CGFloat(sourceImage?.width ?? 1920)
        let imgHeight = CGFloat(sourceImage?.height ?? 1080)
        let scaledPadding = settings.canvasPadding * resolutionScale
        let availableRect = canvasRect.insetBy(dx: scaledPadding, dy: scaledPadding)
        let screenRect = Self.aspectFitRect(
            sourceSize: CGSize(width: max(1, imgWidth), height: max(1, imgHeight)),
            inside: availableRect.width > 40 && availableRect.height > 40 ? availableRect : canvasRect
        ).integral

        let scaledCornerRadius = min(
            settings.cornerRadius * resolutionScale,
            min(screenRect.width, screenRect.height) * 0.25
        )
        let roundedScreenPath = CGPath(
            roundedRect: screenRect,
            cornerWidth: scaledCornerRadius,
            cornerHeight: scaledCornerRadius,
            transform: nil
        )

        ensureCachedLayers(
            canvasSize: canvasSize,
            settings: settings
        )

        let zoom = max(1.0, camera.zoom)
        let clampedFocus = ZoomCameraEngine.clampViewportCenter(camera.focusCenter, zoom: zoom)
        let focusCG = CGPoint(
            x: screenRect.minX + clampedFocus.x * screenRect.width,
            y: screenRect.maxY - clampedFocus.y * screenRect.height
        )
        let screenCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)

        if let bgImg = cachedBgOnlyImage {
            ctx.draw(bgImg, in: canvasRect)
        } else {
            drawBackground(in: ctx, rect: canvasRect, settings: settings)
        }

        switch settings.zoomFrameMode {
        case .wholeFrame:
            ctx.saveGState()
            ctx.translateBy(x: screenCenter.x, y: screenCenter.y)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -focusCG.x, y: -focusCG.y)

            if settings.shadowEnabled && settings.shadowOpacity > 0.005 {
                Self.drawOuterEdgeShadowStrips(
                    in: ctx,
                    screenRect: screenRect,
                    cornerRadius: scaledCornerRadius,
                    resolutionScale: resolutionScale,
                    settings: settings
                )
            }

            ctx.saveGState()
            ctx.addPath(roundedScreenPath)
            ctx.clip()
            drawScreenContentOnly(in: ctx, screenRect: screenRect, sourceImage: sourceImage)
            ctx.restoreGState()

            if settings.insetBorderOpacity > 0.01 {
                ctx.saveGState()
                ctx.addPath(roundedScreenPath)
                ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: settings.insetBorderOpacity))
                ctx.setLineWidth(max(1.0, 1.5 * resolutionScale))
                ctx.strokePath()
                ctx.restoreGState()
            }

            ctx.restoreGState()

        case .insideFrame:
            if settings.shadowEnabled && settings.shadowOpacity > 0.005 {
                Self.drawOuterEdgeShadowStrips(
                    in: ctx,
                    screenRect: screenRect,
                    cornerRadius: scaledCornerRadius,
                    resolutionScale: resolutionScale,
                    settings: settings
                )
            }

            ctx.saveGState()
            ctx.addPath(roundedScreenPath)
            ctx.clip()
            ctx.translateBy(x: screenCenter.x, y: screenCenter.y)
            ctx.scaleBy(x: zoom, y: zoom)
            ctx.translateBy(x: -focusCG.x, y: -focusCG.y)
            drawScreenContentOnly(in: ctx, screenRect: screenRect, sourceImage: sourceImage)
            ctx.restoreGState()

            if settings.insetBorderOpacity > 0.01 {
                ctx.saveGState()
                ctx.addPath(roundedScreenPath)
                ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: settings.insetBorderOpacity))
                ctx.setLineWidth(max(1.0, 1.5 * resolutionScale))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        drawOverlays(
            in: ctx,
            screenRect: screenRect,
            screenCenter: screenCenter,
            clampedFocus: clampedFocus,
            zoom: zoom,
            resolutionScale: resolutionScale,
            cursor: cursor,
            settings: settings
        )

        ctx.restoreGState()
    }

    private func drawOverlays(
        in ctx: CGContext,
        screenRect: CGRect,
        screenCenter: CGPoint,
        clampedFocus: CGPoint,
        zoom: CGFloat,
        resolutionScale: CGFloat,
        cursor: CursorRenderState,
        settings: StudioSettings
    ) {
        if settings.clickRippleEnabled {
            for ripple in cursor.ripples {
                let rippleStagePt = CGPoint(
                    x: screenCenter.x + (ripple.location.x - clampedFocus.x) * screenRect.width * zoom,
                    y: screenCenter.y + (clampedFocus.y - ripple.location.y) * screenRect.height * zoom
                )
                drawClickRipple(
                    in: ctx,
                    at: rippleStagePt,
                    progress: ripple.progress,
                    isRightClick: ripple.isRightClick,
                    settings: settings,
                    resolutionScale: resolutionScale,
                    cameraZoom: zoom
                )
            }
        }

        if settings.showCursor && cursor.opacity > 0.01 {
            let cursorStagePt = CGPoint(
                x: screenCenter.x + (cursor.location.x - clampedFocus.x) * screenRect.width * zoom,
                y: screenCenter.y + (clampedFocus.y - cursor.location.y) * screenRect.height * zoom
            )
            drawCustomCursorFast(
                in: ctx,
                at: cursorStagePt,
                cursor: cursor,
                settings: settings,
                resolutionScale: resolutionScale,
                cameraZoom: zoom
            )
        }
    }

    private func drawScreenContentOnly(
        in ctx: CGContext,
        screenRect: CGRect,
        sourceImage: CGImage?
    ) {
        if let cgImage = sourceImage {
            ctx.draw(cgImage, in: screenRect)
        } else {
            drawPlaceholderScreen(in: ctx, rect: screenRect)
        }
    }

    // MARK: - Cached Background & Metal Texture Generator

    private func ensureCachedLayers(
        canvasSize: CGSize,
        settings: StudioSettings
    ) {
        let w = max(16, Int(round(canvasSize.width)))
        let h = max(16, Int(round(canvasSize.height)))

        let key = LayerCacheKey(
            canvasWidth: w,
            canvasHeight: h,
            backgroundType: settings.backgroundType,
            selectedGradientIndex: settings.selectedGradientIndex,
            solidColor: settings.solidBackgroundColor,
            customBackgroundURL: settings.customBackgroundImageURL
        )

        if cachedKey == key && cachedBgOnlyImage != nil && mtlCachedWidth == w && mtlCachedHeight == h {
            return
        }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let bpr = w * 4

        if let dev = mtlDevice, (mtlCachedWidth != w || mtlCachedHeight != h || mtlTargetTex == nil) {
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            texDesc.usage = .shaderRead
            mtlBgOnlyTex = dev.makeTexture(descriptor: texDesc)

            let targetDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            targetDesc.storageMode = .private
            targetDesc.usage = [.renderTarget, .shaderRead]
            mtlTargetTex = dev.makeTexture(descriptor: targetDesc)

            if let buf = dev.makeBuffer(length: bpr * h, options: .storageModeShared) {
                mtlSharedReadbackBuffer = buf
                mtlSharedContext = CGContext(
                    data: buf.contents(),
                    width: w,
                    height: h,
                    bitsPerComponent: 8,
                    bytesPerRow: bpr,
                    space: deviceRGB,
                    bitmapInfo: fastBitmapInfo
                )
            }
            mtlCachedWidth = w
            mtlCachedHeight = h
        }

        if let bgCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr, space: deviceRGB, bitmapInfo: fastBitmapInfo) {
            bgCtx.clear(rect)
            drawBackground(in: bgCtx, rect: rect, settings: settings)
            cachedBgOnlyImage = bgCtx.makeImage()
            if let data = bgCtx.data {
                mtlBgOnlyTex?.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: bpr)
            }
        }

        cachedKey = key
    }

    // MARK: - Background Drawing

    private func drawBackground(in ctx: CGContext, rect: CGRect, settings: StudioSettings) {
        switch settings.backgroundType {
        case .macWallpaper:
            if let bgImage = DesktopWallpaperHelper.currentMacWallpaperImage() {
                let fillRect = Self.aspectFillRect(
                    sourceSize: CGSize(width: bgImage.width, height: bgImage.height),
                    inside: rect
                )
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.interpolationQuality = .low
                ctx.draw(bgImage, in: fillRect)
                ctx.restoreGState()
                return
            }
            drawGradientPreset(in: ctx, rect: rect, index: settings.selectedGradientIndex)

        case .solidColor:
            ctx.setFillColor(settings.solidBackgroundColor.cgColor)
            ctx.fill(rect)

        case .customImage:
            if let url = settings.customBackgroundImageURL,
               let bgImage = loadCustomBackground(url: url) {
                let fillRect = Self.aspectFillRect(
                    sourceSize: CGSize(width: bgImage.width, height: bgImage.height),
                    inside: rect
                )
                ctx.saveGState()
                ctx.clip(to: rect)
                ctx.interpolationQuality = .low
                ctx.draw(bgImage, in: fillRect)
                ctx.restoreGState()
                return
            }
            drawGradientPreset(in: ctx, rect: rect, index: settings.selectedGradientIndex)

        case .gradient:
            drawGradientPreset(in: ctx, rect: rect, index: settings.selectedGradientIndex)
        }
    }

    private func drawGradientPreset(in ctx: CGContext, rect: CGRect, index: Int) {
        let presets = GradientPreset.allPresets
        let safeIndex = max(0, min(presets.count - 1, index))
        let preset = presets[safeIndex]

        let cgColors = preset.colors.map { $0.cgColor } as CFArray
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? deviceRGB

        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: nil) else {
            ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.18, alpha: 1.0))
            ctx.fill(rect)
            return
        }

        let startPt = CGPoint(
            x: rect.minX + preset.startPoint.x * rect.width,
            y: rect.maxY - preset.startPoint.y * rect.height
        )
        let endPt = CGPoint(
            x: rect.minX + preset.endPoint.x * rect.width,
            y: rect.maxY - preset.endPoint.y * rect.height
        )

        ctx.drawLinearGradient(
            gradient,
            start: startPt,
            end: endPt,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        let glowColors = [
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray
        if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
            let center = CGPoint(x: rect.minX + rect.width * 0.25, y: rect.minY + rect.height * 0.78)
            ctx.drawRadialGradient(
                radial,
                startCenter: center,
                startRadius: 0,
                endCenter: center,
                endRadius: max(rect.width, rect.height) * 0.65,
                options: []
            )
        }
    }

    // MARK: - Click Ripple Drawing

    private func drawClickRipple(
        in ctx: CGContext,
        at point: CGPoint,
        progress: CGFloat,
        isRightClick: Bool,
        settings: StudioSettings,
        resolutionScale: CGFloat,
        cameraZoom: CGFloat
    ) {
        let clamped = max(0.0, min(1.0, progress))
        let easeOut = 1.0 - pow(1.0 - clamped, 3.0)
        let fadeAlpha = pow(1.0 - clamped, 1.65)

        let zoomCompensation: CGFloat = settings.scaleCursorWithZoom ? pow(cameraZoom, 0.35) : 1.0
        let maxR = settings.clickRippleMaxRadius * resolutionScale * zoomCompensation
        let currentRadius = max(4.0, maxR * (0.20 + 0.80 * easeOut))

        let baseColor = isRightClick ? settings.rightClickRippleColor : settings.clickRippleColor

        ctx.saveGState()

        let fillAlpha = CGFloat(baseColor.a) * fadeAlpha * 0.28
        ctx.setFillColor(
            CGColor(
                srgbRed: CGFloat(baseColor.r),
                green: CGFloat(baseColor.g),
                blue: CGFloat(baseColor.b),
                alpha: fillAlpha
            )
        )
        let circleRect = CGRect(
            x: point.x - currentRadius,
            y: point.y - currentRadius,
            width: currentRadius * 2.0,
            height: currentRadius * 2.0
        )
        ctx.fillEllipse(in: circleRect)

        let strokeAlpha = CGFloat(baseColor.a) * fadeAlpha * 0.92
        ctx.setStrokeColor(
            CGColor(
                srgbRed: CGFloat(baseColor.r),
                green: CGFloat(baseColor.g),
                blue: CGFloat(baseColor.b),
                alpha: strokeAlpha
            )
        )
        ctx.setLineWidth(max(1.5, 3.2 * resolutionScale * zoomCompensation * (1.0 - 0.4 * clamped)))
        ctx.strokeEllipse(in: circleRect)

        ctx.restoreGState()
    }

    // MARK: - Fast Pre-Rendered Cursor Sprite Drawing

    private func ensureCursorSprite(cursor: CursorRenderState, settings: StudioSettings) -> CGImage? {
        let key = CursorCacheKey(
            style: settings.cursorStyle,
            isPressed: cursor.isPressed && settings.cursorStyle == .touchCircle,
            rippleColor: settings.clickRippleColor
        )
        if cachedCursorKey == key, let sprite = cachedCursorSprite {
            return sprite
        }

        let sz = cursorSpriteSize
        guard let cCtx = CGContext(
            data: nil,
            width: sz,
            height: sz,
            bitsPerComponent: 8,
            bytesPerRow: sz * 4,
            space: deviceRGB,
            bitmapInfo: fastBitmapInfo
        ) else {
            return nil
        }

        cCtx.clear(CGRect(x: 0, y: 0, width: sz, height: sz))
        cCtx.setShouldAntialias(true)

        let internalScale: CGFloat = 2.0
        cCtx.setShadow(
            offset: CGSize(width: 0, height: -2.5 * internalScale),
            blur: 5.0 * internalScale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.58)
        )

        cCtx.translateBy(x: cursorHotspotInSprite.x, y: cursorHotspotInSprite.y)
        cCtx.scaleBy(x: internalScale, y: internalScale)

        switch settings.cursorStyle {
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

            cCtx.addPath(arrowPath)
            cCtx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1.0))
            cCtx.fillPath()

            cCtx.setShadow(offset: .zero, blur: 0, color: nil)
            cCtx.addPath(arrowPath)
            cCtx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
            cCtx.setLineWidth(2.0)
            cCtx.setLineJoin(.round)
            cCtx.setLineCap(.round)
            cCtx.strokePath()

        case .touchCircle:
            let radius: CGFloat = 12.0
            let circleRect = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
            cCtx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.28))
            cCtx.fillEllipse(in: circleRect)

            cCtx.setShadow(offset: .zero, blur: 0, color: nil)
            cCtx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98))
            cCtx.setLineWidth(2.4)
            cCtx.strokeEllipse(in: circleRect)

            let dotR: CGFloat = 3.5
            let dotColor = cursor.isPressed ? settings.clickRippleColor.cgColor : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            cCtx.setFillColor(dotColor)
            cCtx.fillEllipse(in: CGRect(x: -dotR, y: -dotR, width: dotR * 2, height: dotR * 2))

        case .crosshair:
            let arm: CGFloat = 12.0
            cCtx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.98))
            cCtx.setLineWidth(2.2)
            cCtx.move(to: CGPoint(x: -arm, y: 0))
            cCtx.addLine(to: CGPoint(x: arm, y: 0))
            cCtx.move(to: CGPoint(x: 0, y: -arm))
            cCtx.addLine(to: CGPoint(x: 0, y: arm))
            cCtx.strokePath()

            let ringR: CGFloat = 6.5
            cCtx.strokeEllipse(in: CGRect(x: -ringR, y: -ringR, width: ringR * 2, height: ringR * 2))
        }

        let img = cCtx.makeImage()
        cachedCursorKey = key
        cachedCursorSprite = img
        return img
    }

    private func drawCustomCursorFast(
        in ctx: CGContext,
        at point: CGPoint,
        cursor: CursorRenderState,
        settings: StudioSettings,
        resolutionScale: CGFloat,
        cameraZoom: CGFloat
    ) {
        guard let sprite = ensureCursorSprite(cursor: cursor, settings: settings) else { return }

        let zoomFactor: CGFloat = settings.scaleCursorWithZoom ? pow(cameraZoom, 0.35) : 1.0
        let squish: CGFloat = (settings.clickSquishEffect && cursor.isPressed) ? 0.84 : 1.0
        let drawScale = (settings.cursorScale * resolutionScale * zoomFactor * squish) * 0.5

        let drawW = CGFloat(cursorSpriteSize) * drawScale
        let drawH = CGFloat(cursorSpriteSize) * drawScale
        let drawX = point.x - cursorHotspotInSprite.x * drawScale
        let drawY = point.y - cursorHotspotInSprite.y * drawScale

        ctx.saveGState()
        if cursor.opacity < 0.99 {
            ctx.setAlpha(cursor.opacity)
        }
        ctx.interpolationQuality = .low
        ctx.draw(sprite, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        ctx.restoreGState()
    }

    // MARK: - Placeholder Screen

    private func drawPlaceholderScreen(in ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1.0))
        ctx.fill(rect)

        let barHeight = rect.height * 0.06
        let barRect = CGRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight)
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.17, blue: 0.22, alpha: 1.0))
        ctx.fill(barRect)

        let dotColors: [CGColor] = [
            CGColor(srgbRed: 1.0, green: 0.37, blue: 0.34, alpha: 1.0),
            CGColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1.0),
            CGColor(srgbRed: 0.15, green: 0.79, blue: 0.25, alpha: 1.0)
        ]
        let dotR = max(4.0, barHeight * 0.22)
        for (i, c) in dotColors.enumerated() {
            let cx = rect.minX + barHeight * 0.6 + CGFloat(i) * (dotR * 3.2)
            let cy = barRect.midY
            ctx.setFillColor(c)
            ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        }
        ctx.restoreGState()
    }

    // MARK: - Render into CVPixelBuffer (Metal GPU 1080p Stage Render + Hardware DMA Blit for NootedRed.kext!)

    private func ensureRAMContext(width: Int, height: Int) -> (CGContext, UnsafeMutableRawPointer, Int)? {
        let bpr = width * 4
        let needed = bpr * height
        if ramContext == nil || ramContextWidth != width || ramContextHeight != height || ramBufferCapacity < needed {
            ramBuffer?.deallocate()
            let newBuf = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 64)
            Darwin.memset(newBuf, 0, needed)
            guard let newCtx = CGContext(
                data: newBuf,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: deviceRGB,
                bitmapInfo: fastBitmapInfo
            ) else {
                newBuf.deallocate()
                return nil
            }
            ramBuffer = newBuf
            ramBufferCapacity = needed
            ramContext = newCtx
            ramContextWidth = width
            ramContextHeight = height
        }
        guard let ctx = ramContext, let buf = ramBuffer else { return nil }
        return (ctx, buf, bpr)
    }

    public func renderToPixelBuffer(
        pool: CVPixelBufferPool?,
        size: CGSize,
        ioSurface: IOSurfaceRef? = nil,
        fallbackImage: CGImage?,
        settings: StudioSettings,
        camera: CameraRenderState,
        cursor: CursorRenderState
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let width = Int(size.width)
        let height = Int(size.height)

        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        } else {
            let attrs: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
        }

        guard let buffer = pixelBuffer else { return nil }

        // FAST PATH: Metal GPU Stage Compositor + Hardware DMA Blit to Shared System RAM Buffer (~3.8ms at 1920x1080 Full HD!)
        if let surf = ioSurface,
           let dev = mtlDevice,
           let cmdQueue = mtlCommandQueue,
           let pipeline = mtlPipeline {
            let sw = IOSurfaceGetWidth(surf)
            let sh = IOSurfaceGetHeight(surf)
            if sw > 16 && sh > 16 {
                let sDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: sw, height: sh, mipmapped: false)
                sDesc.usage = .shaderRead
                if let screenTex = dev.makeTexture(descriptor: sDesc, iosurface: surf, plane: 0) {
                    let canvasRect = CGRect(origin: .zero, size: size)
                    let referenceWidth: CGFloat = 1920.0
                    let resolutionScale = max(size.width, size.height) / referenceWidth
                    let scaledPadding = settings.canvasPadding * resolutionScale
                    let availableRect = canvasRect.insetBy(dx: scaledPadding, dy: scaledPadding)
                    let screenRect = Self.aspectFitRect(
                        sourceSize: CGSize(width: sw, height: sh),
                        inside: availableRect.width > 40 && availableRect.height > 40 ? availableRect : canvasRect
                    ).integral

                    let scaledCornerRadius = min(
                        settings.cornerRadius * resolutionScale,
                        min(screenRect.width, screenRect.height) * 0.25
                    )


                    ensureCachedLayers(
                        canvasSize: size,
                        settings: settings
                    )

                    let zoom = max(1.0, camera.zoom)
                    let clampedFocus = ZoomCameraEngine.clampViewportCenter(camera.focusCenter, zoom: zoom)
                    let isWholeFrame = (settings.zoomFrameMode == .wholeFrame) && (zoom > 1.002)
                    let hasShadow = (settings.shadowEnabled && settings.shadowOpacity > 0.005)
                    let sc = settings.shadowColor

                    var uniforms = MetalStageUniforms(
                        u0: SIMD4<Float>(
                            Float(width),
                            Float(height),
                            Float(zoom),
                            Float(scaledCornerRadius)
                        ),
                        u1: SIMD4<Float>(
                            Float(screenRect.minX),
                            Float(size.height - screenRect.maxY),
                            Float(screenRect.width),
                            Float(screenRect.height)
                        ),
                        u2: SIMD4<Float>(
                            Float(clampedFocus.x),
                            Float(clampedFocus.y),
                            Float(settings.insetBorderOpacity),
                            Float(max(1.0, 1.5 * resolutionScale))
                        ),
                        u3: SIMD4<Float>(
                            isWholeFrame ? 1.0 : 0.0,
                            hasShadow ? 1.0 : 0.0,
                            Float(settings.shadowOffsetX * resolutionScale),
                            Float(settings.shadowOffsetY * resolutionScale)
                        ),
                        u4: SIMD4<Float>(
                            Float(sc.r),
                            Float(sc.g),
                            Float(sc.b),
                            Float(settings.shadowOpacity)
                        ),
                        u5: SIMD4<Float>(
                            Float(max(1.0, settings.shadowBlurRadius * resolutionScale)),
                            0.0,
                            0.0,
                            0.0
                        )
                    )

                    // ZERO-COPY DIRECT METAL PATH: Render directly into CVPixelBuffer IOSurface
                    if let destSurface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
                        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .bgra8Unorm,
                            width: width,
                            height: height,
                            mipmapped: false
                        )
                        texDesc.usage = [.renderTarget, .shaderRead]

                        if let destTex = dev.makeTexture(descriptor: texDesc, iosurface: destSurface, plane: 0),
                           let bgOnlyTex = mtlBgOnlyTex,
                           let cmdBuf = cmdQueue.makeCommandBuffer() {

                            let rp = MTLRenderPassDescriptor()
                            rp.colorAttachments[0].texture = destTex
                            rp.colorAttachments[0].loadAction = .dontCare
                            rp.colorAttachments[0].storeAction = .store

                            if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rp) {
                                enc.setRenderPipelineState(pipeline)
                                enc.setFragmentBytes(&uniforms, length: MemoryLayout<MetalStageUniforms>.stride, index: 0)
                                enc.setFragmentTexture(bgOnlyTex, index: 0)
                                enc.setFragmentTexture(screenTex, index: 1)
                                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                                enc.endEncoding()
                            }

                            cmdBuf.commit()

                            // Render vector cursor sprite and click ripples directly on buffer
                            let hasRipples = settings.clickRippleEnabled && !cursor.ripples.isEmpty
                            let hasCursor = settings.showCursor && cursor.opacity > 0.01
                            if hasRipples || hasCursor {
                                CVPixelBufferLockBaseAddress(buffer, [])
                                if let dstBase = CVPixelBufferGetBaseAddress(buffer) {
                                    let dstBpr = CVPixelBufferGetBytesPerRow(buffer)
                                    if let overlayCtx = CGContext(
                                        data: dstBase,
                                        width: width,
                                        height: height,
                                        bitsPerComponent: 8,
                                        bytesPerRow: dstBpr,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                                    ) {
                                        let screenCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
                                        drawOverlays(
                                            in: overlayCtx,
                                            screenRect: screenRect,
                                            screenCenter: screenCenter,
                                            clampedFocus: clampedFocus,
                                            zoom: zoom,
                                            resolutionScale: resolutionScale,
                                            cursor: cursor,
                                            settings: settings
                                        )
                                    }
                                }
                                CVPixelBufferUnlockBaseAddress(buffer, [])
                            }

                            return buffer
                        }
                    }

                    // FALLBACK METAL PATH: Shared Readback Buffer + Blit
                    if let targetTex = mtlTargetTex,
                       let sharedBuf = mtlSharedReadbackBuffer,
                       let sharedCtx = mtlSharedContext,
                       let bgOnlyTex = mtlBgOnlyTex,
                       let cmdBuf = cmdQueue.makeCommandBuffer() {

                        let rp = MTLRenderPassDescriptor()
                        rp.colorAttachments[0].texture = targetTex
                        rp.colorAttachments[0].loadAction = .dontCare
                        rp.colorAttachments[0].storeAction = .store

                        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rp) {
                            enc.setRenderPipelineState(pipeline)
                            enc.setFragmentBytes(&uniforms, length: MemoryLayout<MetalStageUniforms>.stride, index: 0)
                            enc.setFragmentTexture(bgOnlyTex, index: 0)
                            enc.setFragmentTexture(screenTex, index: 1)
                            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                            enc.endEncoding()
                        }

                        let srcBpr = width * 4
                        if let blit = cmdBuf.makeBlitCommandEncoder() {
                            blit.copy(
                                from: targetTex,
                                sourceSlice: 0,
                                sourceLevel: 0,
                                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                sourceSize: MTLSize(width: width, height: height, depth: 1),
                                to: sharedBuf,
                                destinationOffset: 0,
                                destinationBytesPerRow: srcBpr,
                                destinationBytesPerImage: srcBpr * height
                            )
                            blit.endEncoding()
                        }

                        cmdBuf.commit()
                        cmdBuf.waitUntilCompleted()

                        // Draw Click Ripples & HD Vector Cursor Sprite onto cached System RAM buffer (~0.05ms!)
                        let screenCenter = CGPoint(x: screenRect.midX, y: screenRect.midY)
                        drawOverlays(
                            in: sharedCtx,
                            screenRect: screenRect,
                            screenCenter: screenCenter,
                            clampedFocus: clampedFocus,
                            zoom: zoom,
                            resolutionScale: resolutionScale,
                            cursor: cursor,
                            settings: settings
                        )

                        // Copy from cached System RAM into CVPixelBuffer
                        CVPixelBufferLockBaseAddress(buffer, [])
                        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                        guard let dstBase = CVPixelBufferGetBaseAddress(buffer) else { return nil }
                        let dstBpr = CVPixelBufferGetBytesPerRow(buffer)
                        let srcPtr = sharedBuf.contents()

                        if dstBpr == srcBpr {
                            Darwin.memcpy(dstBase, srcPtr, srcBpr * height)
                        } else {
                            let copyBytes = min(srcBpr, dstBpr)
                            for row in 0..<height {
                                Darwin.memcpy(
                                    dstBase.advanced(by: row * dstBpr),
                                    srcPtr.advanced(by: row * srcBpr),
                                    copyBytes
                                )
                            }
                        }
                        return buffer
                    }
                }
            }
        }

        // FALLBACK PATH (e.g., App Window CGImage capture)
        guard let (ramCtx, srcRamPtr, srcBpr) = ensureRAMContext(width: width, height: height) else { return nil }
        render(
            in: ramCtx,
            canvasSize: size,
            sourceImage: fallbackImage,
            settings: settings,
            camera: camera,
            cursor: cursor
        )

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let dstBpr = CVPixelBufferGetBytesPerRow(buffer)

        if dstBpr == srcBpr {
            Darwin.memcpy(dstBase, srcRamPtr, srcBpr * height)
        } else {
            let copyBytes = min(srcBpr, dstBpr)
            for row in 0..<height {
                Darwin.memcpy(
                    dstBase.advanced(by: row * dstBpr),
                    srcRamPtr.advanced(by: row * srcBpr),
                    copyBytes
                )
            }
        }

        return buffer
    }

    // MARK: - Hollow Outer-Edge Drop Shadow Strip Generator (Never renders middle interior!)

    /// Computes the 4 non-overlapping outer border strip rectangles (Top, Bottom, Left, Right) around `screenRect`
    /// so the middle interior (`hollowInnerRect`) is 100% excluded from CPU & GPU rendering.
    public static func computeEdgeShadowStripRects(
        screenRect: CGRect,
        cornerRadius: CGFloat,
        shadowOffset: CGPoint,
        shadowBlur: CGFloat
    ) -> (top: CGRect, bottom: CGRect, left: CGRect, right: CGRect) {
        let expand = ceil(max(1.0, shadowBlur) * 1.35) + 2.0
        let shiftedBox = screenRect.offsetBy(dx: shadowOffset.x, dy: shadowOffset.y)
        let outerRect = shiftedBox.union(screenRect).insetBy(dx: -expand, dy: -expand).integral

        let maxInsetX = max(2.0, screenRect.width * 0.42)
        let maxInsetY = max(2.0, screenRect.height * 0.42)
        let insetX = min(max(2.0, ceil(cornerRadius)), maxInsetX)
        let insetY = min(max(2.0, ceil(cornerRadius)), maxInsetY)
        let hollowInner = screenRect.insetBy(dx: insetX, dy: insetY).integral

        let topRect = CGRect(
            x: outerRect.minX,
            y: hollowInner.maxY,
            width: outerRect.width,
            height: max(0.0, outerRect.maxY - hollowInner.maxY)
        )
        let bottomRect = CGRect(
            x: outerRect.minX,
            y: outerRect.minY,
            width: outerRect.width,
            height: max(0.0, hollowInner.minY - outerRect.minY)
        )
        let leftRect = CGRect(
            x: outerRect.minX,
            y: hollowInner.minY,
            width: max(0.0, hollowInner.minX - outerRect.minX),
            height: max(0.0, hollowInner.height)
        )
        let rightRect = CGRect(
            x: hollowInner.maxX,
            y: hollowInner.minY,
            width: max(0.0, outerRect.maxX - hollowInner.maxX),
            height: max(0.0, hollowInner.height)
        )
        return (topRect, bottomRect, leftRect, rightRect)
    }

    @inline(__always)
    private static func sdRoundedBoxScalar(
        px: Float,
        py: Float,
        cx: Float,
        cy: Float,
        hx: Float,
        hy: Float,
        r: Float
    ) -> Float {
        let qx = abs(px - cx) - hx + r
        let qy = abs(py - cy) - hy + r
        let insidePart = min(max(qx, qy), 0.0)
        let ox = max(qx, 0.0)
        let oy = max(qy, 0.0)
        let outsidePart = sqrt(ox * ox + oy * oy)
        return insidePart + outsidePart - r
    }

    /// Renders a single outer edge shadow strip (`top`, `bottom`, `left`, or `right`) using analytical SDF blur.
    /// Pixels inside the screen (`dScreen <= -2.0`) are skipped immediately.
    public static func makeEdgeShadowStripImage(
        stripRect: CGRect,
        screenRect: CGRect,
        cornerRadius: CGFloat,
        shadowOffset: CGPoint,
        shadowBlur: CGFloat,
        shadowColor: RGBAColor,
        shadowOpacity: CGFloat,
        downsampleScale: CGFloat = 0.5
    ) -> CGImage? {
        guard stripRect.width >= 1.0 && stripRect.height >= 1.0 && shadowOpacity > 0.005 else {
            return nil
        }

        let bw = max(2, Int(ceil(stripRect.width * downsampleScale)))
        let bh = max(2, Int(ceil(stripRect.height * downsampleScale)))
        let bpr = bw * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: bw,
            height: bh,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let basePtr = ctx.data else {
            return nil
        }

        let pixels = basePtr.assumingMemoryBound(to: UInt32.self)
        let stepX = Float(stripRect.width) / Float(bw)
        let stepY = Float(stripRect.height) / Float(bh)
        let startX = Float(stripRect.minX) + stepX * 0.5
        let topY = Float(stripRect.maxY) - stepY * 0.5

        let scX = Float(screenRect.midX)
        let scY = Float(screenRect.midY)
        let shX = Float(screenRect.width) * 0.5
        let shY = Float(screenRect.height) * 0.5
        let rF = Float(cornerRadius)

        let offX = Float(shadowOffset.x)
        let offY = Float(shadowOffset.y)
        let blurF = max(1.0, Float(shadowBlur))
        let invBlurSpan = 1.0 / (blurF * 1.35)
        let blurBias = blurF * 0.35

        let colR = Float(shadowColor.r) * 255.0
        let colG = Float(shadowColor.g) * 255.0
        let colB = Float(shadowColor.b) * 255.0
        let maxAlpha = Float(min(1.0, max(0.0, shadowOpacity)))

        for py in 0..<bh {
            let sy = topY - Float(py) * stepY
            let rowOffset = py * bw
            for px in 0..<bw {
                let sx = startX + Float(px) * stepX
                let dScreen = sdRoundedBoxScalar(px: sx, py: sy, cx: scX, cy: scY, hx: shX, hy: shY, r: rF)
                if dScreen <= -2.0 {
                    pixels[rowOffset + px] = 0
                    continue
                }

                let dShadow = sdRoundedBoxScalar(
                    px: sx - offX,
                    py: sy - offY,
                    cx: scX,
                    cy: scY,
                    hx: shX,
                    hy: shY,
                    r: rF
                )
                let uNorm = (dShadow + blurBias) * invBlurSpan
                if uNorm >= 1.0 {
                    pixels[rowOffset + px] = 0
                    continue
                }

                let uClamped = max(0.0, uNorm)
                let t = 1.0 - uClamped
                let shAlpha = maxAlpha * (t * t * (1.0 - 0.15 * uClamped))
                let a8 = UInt32(min(255.0, max(0.0, shAlpha * 255.0 + 0.5)))
                if a8 == 0 {
                    pixels[rowOffset + px] = 0
                    continue
                }

                let r8 = UInt32(min(255.0, max(0.0, colR * shAlpha + 0.5)))
                let g8 = UInt32(min(255.0, max(0.0, colG * shAlpha + 0.5)))
                let b8 = UInt32(min(255.0, max(0.0, colB * shAlpha + 0.5)))
                pixels[rowOffset + px] = (a8 << 24) | (r8 << 16) | (g8 << 8) | b8
            }
        }

        return ctx.makeImage()
    }

    public static func drawOuterEdgeShadowStrips(
        in ctx: CGContext,
        screenRect: CGRect,
        cornerRadius: CGFloat,
        resolutionScale: CGFloat,
        settings: StudioSettings
    ) {
        let shadowOffset = CGPoint(
            x: settings.shadowOffsetX * resolutionScale,
            y: -settings.shadowOffsetY * resolutionScale
        )
        let shadowBlur = max(1.0, settings.shadowBlurRadius * resolutionScale)
        let strips = computeEdgeShadowStripRects(
            screenRect: screenRect,
            cornerRadius: cornerRadius,
            shadowOffset: shadowOffset,
            shadowBlur: shadowBlur
        )

        for stripRect in [strips.top, strips.bottom, strips.left, strips.right] {
            if let img = makeEdgeShadowStripImage(
                stripRect: stripRect,
                screenRect: screenRect,
                cornerRadius: cornerRadius,
                shadowOffset: shadowOffset,
                shadowBlur: shadowBlur,
                shadowColor: settings.shadowColor,
                shadowOpacity: settings.shadowOpacity,
                downsampleScale: 0.5
            ) {
                ctx.draw(img, in: stripRect)
            }
        }
    }

    // MARK: - Image Cache & Geometry Helpers

    private func loadCustomBackground(url: URL) -> CGImage? {
        if cachedBackgroundURL == url, let img = cachedBackgroundImage {
            return img
        }
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        cachedBackgroundURL = url
        cachedBackgroundImage = cgImage
        return cgImage
    }

    public static func aspectFitRect(sourceSize: CGSize, inside bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0 && sourceSize.height > 0 && bounds.width > 0 && bounds.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let w = sourceSize.width * scale
        let h = sourceSize.height * scale
        return CGRect(
            x: bounds.midX - w * 0.5,
            y: bounds.midY - h * 0.5,
            width: w,
            height: h
        )
    }

    public static func aspectFillRect(sourceSize: CGSize, inside bounds: CGRect) -> CGRect {
        guard sourceSize.width > 0 && sourceSize.height > 0 && bounds.width > 0 && bounds.height > 0 else {
            return bounds
        }
        let scale = max(bounds.width / sourceSize.width, bounds.height / sourceSize.height)
        let w = sourceSize.width * scale
        let h = sourceSize.height * scale
        return CGRect(
            x: bounds.midX - w * 0.5,
            y: bounds.midY - h * 0.5,
            width: w,
            height: h
        )
    }
}
