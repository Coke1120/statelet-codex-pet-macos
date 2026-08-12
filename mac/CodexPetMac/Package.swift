// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Statelet",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "CodexPetCore", targets: ["CodexPetCore"]),
        .executable(name: "statelet", targets: ["Statelet"]),
        .executable(name: "codex-pet-core-self-test", targets: ["CodexPetCoreSelfTest"]),
    ],
    targets: [
        .target(
            name: "CodexPetCore",
            path: "Sources/CodexPetCore"
        ),
        .executableTarget(
            name: "Statelet",
            dependencies: ["CodexPetCore"],
            path: "Sources/CodexPetMac"
        ),
        .executableTarget(
            name: "CodexPetCoreSelfTest",
            dependencies: ["CodexPetCore"],
            path: "Sources/CodexPetCoreSelfTest"
        ),
        .testTarget(
            name: "CodexPetCoreTests",
            dependencies: ["CodexPetCore"],
            path: "Tests/CodexPetCoreTests"
        ),
        .testTarget(
            name: "StateletTests",
            dependencies: ["Statelet", "CodexPetCore"],
            path: "Tests/CodexPetMacTests"
        ),
    ]
)
