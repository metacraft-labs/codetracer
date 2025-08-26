// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "TreeSitterTracepoint",
    products: [
        .library(name: "TreeSitterTracepoint", targets: ["TreeSitterTracepoint"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.8.0"),
    ],
    targets: [
        .target(
            name: "TreeSitterTracepoint",
            dependencies: [],
            path: ".",
            sources: [
                "src/parser.c",
                // NOTE: if your language has an external scanner, add it here.
            ],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
        .testTarget(
            name: "TreeSitterTracepointTests",
            dependencies: [
                "SwiftTreeSitter",
                "TreeSitterTracepoint",
            ],
            path: "bindings/swift/TreeSitterTracepointTests"
        )
    ],
    cLanguageStandard: .c11
)
