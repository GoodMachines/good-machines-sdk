// swift-tools-version: 6.4
// The Swift SDK, installable by URL: add this repository as a package
// dependency at a version tag.
import PackageDescription

let root = "Sources"

let package = Package(
    name: "AgentKit",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "AgentChatUI", targets: ["AgentChatUI"]),
        .library(name: "AgentFoundationModels", targets: ["AgentFoundationModels"]),
    ],
    targets: [
        .target(name: "AgentKit", path: "\(root)/AgentKit"),
        .target(name: "AgentChatUI", dependencies: ["AgentKit"], path: "\(root)/AgentChatUI"),
        .target(name: "AgentFoundationModels", dependencies: ["AgentKit", "AgentChatUI"], path: "\(root)/AgentFoundationModels"),
    ]
)
