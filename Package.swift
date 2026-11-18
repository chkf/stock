// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StockResearch",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ResearchCore", targets: ["ResearchCore"]),
        .executable(name: "research-check", targets: ["ResearchCheck"])
    ],
    targets: [
        .target(name: "CArchive", linkerSettings: [
            .linkedFramework("Accelerate", .when(platforms: [.iOS, .macOS])),
            .linkedLibrary("lapack", .when(platforms: [.linux])),
            .linkedLibrary("blas", .when(platforms: [.linux])),
            .linkedLibrary("z"), .linkedLibrary("iconv", .when(platforms: [.iOS, .macOS])),
            .linkedLibrary("crypto", .when(platforms: [.linux]))
        ]),
        .target(name: "CWorkspaceJS", dependencies: ["CArchive"], cSettings: [
            .define("_GNU_SOURCE"), .define("CONFIG_VERSION", to: "\"2026-06-04\"")
        ]),
        .target(name: "ResearchCore", dependencies: ["CArchive","CWorkspaceJS"], resources: [.process("Resources"), .copy("WorkspaceSeed")]),
        .executableTarget(name: "ResearchCheck", dependencies: ["ResearchCore"]),
        .testTarget(name: "ResearchCoreTests", dependencies: ["ResearchCore"])
    ]
)
