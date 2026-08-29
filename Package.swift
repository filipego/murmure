// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MurmurYouTube",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6")
    ],
    targets: [
        .target(
            name: "MurmurUpdateCore",
            path: "Sources/MurmurUpdateCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MurmurPermissionCore",
            path: "Sources/MurmurPermissionCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MurmurAudioCore",
            path: "Sources/MurmurAudioCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The dictionary is its own target so it can be tested directly, and because its
        // behaviour is a cross-platform contract: the Windows app reimplements this logic in
        // C#, and both sides run the same vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "MurmurDictionary",
            path: "Sources/MurmurDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "MurmurYouTube",
            dependencies: [
                "MurmurDictionary",
                "MurmurUpdateCore",
                "MurmurPermissionCore",
                "MurmurAudioCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MurmurYouTube",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "MurmurUpdateHelper",
            dependencies: ["MurmurUpdateCore"],
            path: "Sources/MurmurUpdateHelper",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurUpdateCoreTests",
            dependencies: ["MurmurUpdateCore"],
            path: "Tests/MurmurUpdateCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurPermissionCoreTests",
            dependencies: ["MurmurPermissionCore"],
            path: "Tests/MurmurPermissionCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurAudioCoreTests",
            dependencies: ["MurmurAudioCore"],
            path: "Tests/MurmurAudioCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurDictionaryTests",
            dependencies: ["MurmurDictionary"],
            path: "Tests/MurmurDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MurmurYouTubeTests",
            dependencies: ["MurmurYouTube", "MurmurDictionary"],
            path: "Tests/MurmurYouTubeTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
