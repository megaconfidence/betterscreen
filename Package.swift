// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "BetterScreen",
    platforms: [.macOS(.v15)],
    targets: [
        // C bridge for symbols that ship in the public SDK .tbd files but are
        // not declared by any public header:
        //   IOAVService*                          -> IOKit        (DDC/CI over I2C, Apple Silicon)
        //   CoreDisplay_DisplayCreateInfoDictionary -> CoreDisplay (IODisplayLocation, EDID metadata)
        //   CGSIsHDR{Supported,Enabled}            -> CoreGraphics (macOS 15 SDR-peak guard)
        //
        // Declaring these in C (rather than @_silgen_name) lets clang apply the
        // CoreFoundation Create Rule, so `IOAVServiceCreateWithService` imports
        // into Swift as `Unmanaged<IOAVService>` and ownership is explicit.
        .target(name: "CDisplayBridge"),

        .executableTarget(
            name: "BetterScreen",
            dependencies: ["CDisplayBridge"],
            swiftSettings: [
                // AVFoundation delegates + IOKit serial queues + timers do not
                // model cleanly under Swift 6 strict concurrency. Isolation is
                // enforced by explicit queue discipline instead; see AmbientLightSensor
                // and DDCTransport.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreDisplay"),
            ]
        ),
    ]
)
