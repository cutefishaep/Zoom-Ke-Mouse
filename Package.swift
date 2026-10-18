// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "ZoomKeMouse",
    products: [
        .executable(name: "ZoomKeMouse", targets: ["ZoomKeMouse"])
    ],
    targets: [
        .executableTarget(
            name: "ZoomKeMouse",
            path: "Sources",
            swiftSettings: [
                .unsafeFlags(["-target", "x86_64-apple-macosx13.0"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Metal"),
                .linkedFramework("IOSurface"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        )
    ]
)
