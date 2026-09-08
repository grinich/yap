// swift-tools-version: 6.3
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let zoomSDKPath = ProcessInfo.processInfo.environment["YAP_ZOOM_SDK_PATH"]
    ?? packageDirectory.appendingPathComponent("Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK").path
let hasZoomSDK = FileManager.default.fileExists(atPath: zoomSDKPath + "/ZoomSDK.framework/Headers/ZoomSDK.h")
let meetingDependencies: [Target.Dependency] = hasZoomSDK ? ["YapCredentials", "YapOAuth", "YapZoomBridge"] : ["YapCredentials", "YapOAuth"]
let zoomTargets: [Target] = hasZoomSDK ? [
    .target(name: "YapZoomBridge", publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc", "-F", zoomSDKPath])],
        linkerSettings: [.linkedFramework("ZoomSDK"), .linkedFramework("AppKit"),
            .unsafeFlags(["-F", zoomSDKPath,
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", zoomSDKPath])])
] : []

let package = Package(
    name: "Yap",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Yap", targets: ["Yap"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "YapCredentials"),
        .target(name: "YapOAuth"),
        .target(name: "YapCalendar", dependencies: ["YapCredentials", "YapOAuth"]),
        .target(name: "YapMeetings", dependencies: meetingDependencies),
        .target(name: "YapSystem"),
        .target(name: "YapUpdates", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "YapAppUI", dependencies: ["YapCalendar", "YapMeetings", "YapSystem", "YapCredentials"]),
        .executableTarget(name: "Yap", dependencies: ["YapAppUI", "YapSystem", "YapUpdates"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "YapOAuthTests", dependencies: ["YapOAuth"]),
        .testTarget(name: "YapCredentialsTests", dependencies: ["YapCredentials"]),
        .testTarget(name: "YapCalendarTests", dependencies: ["YapCalendar"]),
        .testTarget(name: "YapMeetingsTests", dependencies: ["YapMeetings"]),
        .testTarget(name: "YapSystemTests", dependencies: ["YapSystem"]),
        .testTarget(name: "YapUpdatesTests", dependencies: ["YapUpdates"]),
        .testTarget(name: "YapAppUITests", dependencies: ["YapAppUI", "YapCalendar", "YapMeetings"])
    ] + zoomTargets
)
