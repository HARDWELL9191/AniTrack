// swift-tools-version: 6.3

import PackageDescription

// MPVUI 0.8.0 (LePips/MPVUI, commit 0cb499c, MIT), unchanged Swift sources, with the native
// library replaced by JellyReco's build: the same MPVUI 0.8.0 recipe built from source on
// GitHub Actions plus JellyReco's mpv patches (libmpv/patches/mpv on the libmpv-build branch,
// workflow "libmpv build"). Android and test targets are left out.
//
// To move to a new library build: put its release's zip URL and sha256 below.
let package = Package(
    name: "MPVUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
    ],
    products: [
        .library(name: "MPVCore", targets: ["MPVCore"]),
        .library(name: "MPVUI", targets: ["MPVUI"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CMPV",
            dependencies: ["Libmpv-GPL"],
            path: "Sources/CMPV",
            publicHeadersPath: "include"
        ),
        .target(name: "MPVCore", dependencies: ["CMPV"], path: "Sources/MPVCore"),
        .target(
            name: "MPVUI",
            dependencies: [
                "Libmpv-GPL",
                "MPVCore",
                .target(name: "_MPVUIPictureInPicture", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources",
            exclude: ["MPVCore", "CMPV", "Player/PictureInPicture/_MPVUIPictureInPicture"],
            sources: ["Engine", "Models", "Player", "Views", "MPVCoreExports.swift"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("OpenGL", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .visionOS])),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "_MPVUIPictureInPicture",
            path: "Sources/Player/PictureInPicture/_MPVUIPictureInPicture",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("AppKit", .when(platforms: [.macOS]))]
        ),
        // LIBMPV_BINARY_BEGIN (the CI checks this pair against the release)
        .binaryTarget(
            name: "Libmpv-GPL",
            url: "https://github.com/HARDWELL9191/AniTrack/releases/download/libmpv-jr-6/Libmpv.xcframework.zip",
            checksum: "de5fca736bad59a6e7d4a0cc1d27879d05811b555796b7548af30cfa082612d2"
        ),
        // LIBMPV_BINARY_END
    ],
    swiftLanguageModes: [.v6]
)
