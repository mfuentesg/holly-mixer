// swift-tools-version: 5.9

// WARNING:
// This is a Swift Playgrounds app package. It is opened by Swift Playgrounds on iPad
// or by Xcode on a Mac; `AppleProductTypes` is not available to plain `swift build`.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Mixit",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "Mixit",
            targets: ["AppModule"],
            bundleIdentifier: "com.mfuentesg.mixit",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .mic),
            accentColor: .presetColor(.orange),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            capabilities: [
                .localNetwork(purposeString: "Mixit connects to your X AIR mixer on the local network.")
            ],
            appCategory: .music
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
