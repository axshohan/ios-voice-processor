// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "ios-voice-processor",
    platforms: [
        .iOS(.v11)  // Adjust the minimum iOS version if necessary
    ],
    products: [
        .library(
            name: "ios-voice-processor",
            targets: ["ios-voice-processor"]
        )
    ],
    targets: [
        .target(
            name: "ios-voice-processor",
            path: ".",
            exclude: ["example", "resources"],  // Exclude folders that are not part of the source code
            sources: ["VoiceProcessor.swift", "VoiceProcessorBuffer.swift", "VoiceProcessorErrors.swift"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
