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
            .linkedLibrary("z"), .linkedLibrary("iconv", .when(platforms: [.iOS, .macOS])),
            .linkedLibrary("crypto", .when(platforms: [.linux]))
        ]),
        .target(name: "ResearchCore", dependencies: ["CArchive"], resources: [.process("Resources")]),
        .executableTarget(name: "ResearchCheck", dependencies: ["ResearchCore"]),
        .testTarget(name: "ResearchCoreTests", dependencies: ["ResearchCore"])
    ]
)
