// swift-tools-version: 5.9
import PackageDescription

// swift-pjsua
// ===========
// An idiomatic, Swift-only async wrapper over PJSIP's *C* high-level API (pjsua1),
// built on `swift-pjsip`'s `PJSIP` module. The defining design choice is that the
// engine is an `actor` whose work runs on a custom `SerialExecutor` backed by ONE
// dedicated, PJLIB-registered POSIX thread — so `await phone.makeCall(...)` runs the
// (blocking) C call on the correct thread, with no continuations and no C++ shim.
//
// Why pjsua1 (the C API) and not PJSUA2 (C++): PJSUA2 delivers events by you
// *subclassing* its C++ classes and overriding virtual methods, which Swift/C++
// interop cannot do directly (https://www.swift.org/documentation/cxx-interop/status/).
// So "Swift only" + PJSUA2 would still need a C++ shim. pjsua1's C function-pointer
// callbacks bridge to Swift cleanly, so it is the honest cornerstone for this goal.
let package = Package(
    name: "swift-pjsua",
    // Custom actor executors (SE-0392) require the Swift 5.9 concurrency runtime,
    // which is not back-deployed below iOS 17 / macOS 14. If you must support
    // iOS 15–16, drop the custom executor and use the dedicated-thread +
    // `withCheckedThrowingContinuation` fallback sketched in README.md.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SwiftPJSUA", targets: ["SwiftPJSUA"])
    ],
    dependencies: [
        .package(url: "https://github.com/laconicman/swift-pjsip", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "SwiftPJSUA",
            dependencies: [
                .product(name: "PJSIP", package: "swift-pjsip")
            ],
            // SwiftPJSUA doubles as the "support target". A `.binaryTarget` cannot carry
            // linkerSettings, so swift-pjsip documents the framework list for the app to
            // link by hand. A *source* target can carry them, and SwiftPM propagates a
            // linked target's settings to whatever ultimately links the product — so by
            // depending on SwiftPJSUA, the consuming app picks these up automatically.
            // (Purely additive: the linker dedups duplicate `-framework` flags and
            // dead-strips PJSIP objects nothing references.)
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedLibrary("c++") // libpjproject.a contains C++ (pjsua2) objects
            ]
        )
    ]
)
