// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tidy2",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Tidy2", targets: ["Tidy2App"])
    ],
    targets: [
        .executableTarget(
            name: "Tidy2App",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
