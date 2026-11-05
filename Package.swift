// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ARMSim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ARMCore", targets: ["ARMCore"]),
        .executable(name: "armsim", targets: ["armsim"]),
        .executable(name: "ARMSimIDE", targets: ["ARMSimIDE"]),
    ],
    targets: [
        // Simulation engine: CPU core, memory bus, ELF loader / mini linker.
        // Hot interpreter loop: no dynamic exclusivity checks in release builds.
        .target(name: "ARMCore", swiftSettings: [
            .unsafeFlags(["-enforce-exclusivity=unchecked"], .when(configuration: .release)),
        ]),
        // Command line front end: load an ELF/.o/.bin and run it.
        .executableTarget(name: "armsim", dependencies: ["ARMCore"]),
        // µVision-like IDE (SwiftUI): project manager, editor, build, simulator debugger.
        .executableTarget(name: "ARMSimIDE", dependencies: ["ARMCore"]),
        // Self test runner (no XCTest needed): assembles/compiles snippets with
        // Apple clang, runs them in the simulator and checks the results.
        .executableTarget(name: "armsim-selftest", dependencies: ["ARMCore"]),
    ]
)
