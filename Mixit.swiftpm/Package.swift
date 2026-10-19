// swift-tools-version: 5.9

// WARNING:
// This is a Swift Playgrounds app package. It is opened by Swift Playgrounds on iPad
// or by Xcode on a Mac; `AppleProductTypes` is not available to plain `swift build`.

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Mixit",
    defaultLocalization: "en",
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
            appIcon: .asset("AppIcon"),
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
                .localNetwork(purposeString: "Mixit connects to your X AIR mixer on the local network."),
                .camera(purposeString: "Mixit scans the pairing code shown on the sound desk's iPad.")
            ],
            appCategory: .music
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            resources: [.process("es.lproj")]
        )
    ]
)
