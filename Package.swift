// swift-tools-version: 6.3
import PackageDescription
import Foundation

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let zoomSDKPath = ProcessInfo.processInfo.environment["WHOOSH_ZOOM_SDK_PATH"]
    ?? packageDirectory.appendingPathComponent("Vendor/Zoom/zoom-sdk-macos-7.1.5.84750/ZoomSDK").path
let hasZoomSDK = FileManager.default.fileExists(atPath: zoomSDKPath + "/ZoomSDK.framework/Headers/ZoomSDK.h")
let meetingDependencies: [Target.Dependency] = hasZoomSDK ? ["WhooshCredentials", "WhooshZoomBridge"] : ["WhooshCredentials"]
let zoomTargets: [Target] = hasZoomSDK ? [
    .target(name: "WhooshZoomBridge", publicHeadersPath: "include",
        cSettings: [.unsafeFlags(["-fobjc-arc", "-F", zoomSDKPath])],
        linkerSettings: [.linkedFramework("ZoomSDK"), .linkedFramework("AppKit"),
            .unsafeFlags(["-F", zoomSDKPath,
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", zoomSDKPath])])
] : []

let package = Package(
    name: "Whoosh",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Whoosh", targets: ["Whoosh"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "WhooshCredentials"),
        .target(name: "WhooshCalendar", dependencies: ["WhooshCredentials"]),
        .target(name: "WhooshMeetings", dependencies: meetingDependencies),
        .target(name: "WhooshSystem"),
        .target(name: "WhooshUpdates", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .target(name: "WhooshAppUI", dependencies: ["WhooshCalendar", "WhooshMeetings", "WhooshSystem", "WhooshCredentials"]),
        .executableTarget(name: "Whoosh", dependencies: ["WhooshAppUI", "WhooshSystem", "WhooshUpdates"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "WhooshCredentialsTests", dependencies: ["WhooshCredentials"]),
        .testTarget(name: "WhooshCalendarTests", dependencies: ["WhooshCalendar"]),
        .testTarget(name: "WhooshMeetingsTests", dependencies: ["WhooshMeetings"]),
        .testTarget(name: "WhooshSystemTests", dependencies: ["WhooshSystem"]),
        .testTarget(name: "WhooshUpdatesTests", dependencies: ["WhooshUpdates"]),
        .testTarget(name: "WhooshAppUITests", dependencies: ["WhooshAppUI", "WhooshCalendar", "WhooshMeetings"])
    ] + zoomTargets
)
