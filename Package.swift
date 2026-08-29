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
//
// Two products, one dependency edge:
//   PJSIP (binary)  ←  SwiftPJSUA (pure engine)  ←  SwiftPJSUAKit (CallKit/PushKit/UI)  ←  app
//   • SwiftPJSUA    — pure pjsua1 engine. Imports only PJSIP + Foundation. NO CallKit,
//                     PushKit, AVAudioSession, UIKit or SwiftUI. Exposes call/account
//                     primitives + an explicit audio-device API the GUI layer drives.
//   • SwiftPJSUAKit — CallKit + PushKit + AVAudioSession orchestration that depends on
//                     the engine. This is where the OS owns the audio session and tells
//                     the engine when to attach/detach the sound device.
// The boundary is compiler-enforced: the engine cannot reach back into Kit. Promote
// SwiftPJSUAKit to its own repo only if its release cadence diverges from the engine's.
let package = Package(
    name: "swift-pjsua",
    // Custom actor executors (SE-0392) require the Swift 5.9 concurrency runtime,
    // which is not back-deployed below iOS 17. If you must support iOS 15–16, drop the
    // custom executor and use the dedicated-thread + `withCheckedThrowingContinuation`
    // fallback sketched in README.md. macOS is intentionally omitted: `swift-pjsip`
    // currently ships an iOS-only xcframework, so the package cannot link on macOS yet.
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SwiftPJSUA", targets: ["SwiftPJSUA"]),
        .library(name: "SwiftPJSUAKit", targets: ["SwiftPJSUAKit"]),
    ],
    dependencies: [
        // A version range, not a branch: swift-pjsip's product is a prebuilt xcframework,
        // so this dependency edge carries an ABI rather than source. `branch: "main"`
        // re-resolved that binary on every upstream commit — an ABI that could move under
        // us with no version to name it — and a `branch:` requirement also makes this
        // package unusable as a versioned dependency of anything else.
        //
        // The range is upToNextMinor rather than `from:` because swift-pjsip's own bump
        // rule (its docs/Versioning.md) makes the distinction load-bearing: a MINOR means
        // the binary changed — config_site.h, PJSIP commit, patch set, slices — while a
        // PATCH means only the packaging moved and the binary is untouched. So this accepts
        // exactly the releases that cannot change the ABI under us, and adopting a new
        // binary stays a deliberate one-line edit with a diff to review.
        //
        // Do not lower the floor. 0.2.0 was deleted — its module map dropped config_site.h's
        // overrides, so Swift compiled PJSUA_MAX_ACC 4 against a binary built with 8 (see
        // swift-pjsip ARCHITECTURE.md decision 4) — and 0.1.x is PJSIP 2.16, below the
        // upstream floor this engine relies on for the 439 / RFC 5626 handling.
        .package(url: "https://github.com/laconicman/swift-pjsip", "0.2.1" ..< "0.3.0")
    ],
    targets: [
        // The pure engine. Also doubles as the "support target" that carries the
        // framework link flags: a `.binaryTarget` cannot carry linkerSettings, so
        // swift-pjsip only documents the framework list. A *source* target can carry
        // them, and SwiftPM propagates a linked target's settings to whatever ultimately
        // links the product — so by depending on SwiftPJSUA, the consuming app picks
        // these up automatically. (Purely additive: the linker dedups duplicate
        // `-framework` flags and dead-strips PJSIP objects nothing references.)
        .target(
            name: "SwiftPJSUA",
            dependencies: [
                .product(name: "PJSIP", package: "swift-pjsip")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"), // libpjproject.a contains C++ (pjsua2) objects
            ]
        ),
        // CallKit / PushKit / AVAudioSession orchestration. Depends on the engine and
        // drives its audio-device API from `CXProviderDelegate` audio-session callbacks.
        .target(
            name: "SwiftPJSUAKit",
            dependencies: ["SwiftPJSUA"],
            linkerSettings: [
                .linkedFramework("CallKit"),
                .linkedFramework("PushKit"),
            ]
        ),
        .testTarget(
            name: "SwiftPJSUATests",
            // PJSIP is needed directly to feed C enum values (pjsip_inv_state,
            // pjsip_transport_type_e) into the engine's mapping under test.
            dependencies: [
                "SwiftPJSUA",
                .product(name: "PJSIP", package: "swift-pjsip"),
            ]
        ),
        .testTarget(
            name: "SwiftPJSUAKitTests",
            dependencies: ["SwiftPJSUAKit"]
        ),
    ]
)
