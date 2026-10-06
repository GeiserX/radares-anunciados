// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-or-later
//
// RadaresCore: the parts of Radares Anunciados that need no phone, so `swift test` runs them on a Mac.
// Feed decoding, distances, the alert maths, phrasing, the event log and the health rules. Foundation only:
// no UIKit, no Core Location, no ActivityKit. The app target under App/ links this package.
import PackageDescription

let package = Package(
    name: "RadaresCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "RadaresCore", targets: ["RadaresCore"]),
    ],
    targets: [
        .target(
            name: "RadaresCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RadaresCoreTests",
            dependencies: ["RadaresCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
