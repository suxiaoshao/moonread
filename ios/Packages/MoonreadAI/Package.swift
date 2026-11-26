// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadAI",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MoonreadAI", targets: ["MoonreadAI"])
    ],
    dependencies: [
        .package(path: "../MoonreadDesign"),
        .package(url: "https://github.com/suxiaoshao/swift-ai-sdk", revision: "91a91744dfb6067815b09b2abba83948dedf351d"),
        .package(url: "https://github.com/Lakr233/Litext", revision: "cabc9c669e04f9e84629c867554a1660cd69b5da"),
        .package(url: "https://github.com/Lakr233/MarkdownView", exact: "4.8.5")
    ],
    targets: [
        .target(
            name: "MoonreadAI",
            dependencies: [
                .product(name: "MoonreadDesign", package: "MoonreadDesign"),
                .product(name: "SwiftAISDK", package: "swift-ai-sdk"),
                .product(name: "AISDKProvider", package: "swift-ai-sdk"),
                .product(name: "AISDKProviderUtils", package: "swift-ai-sdk"),
                .product(name: "OpenAIProvider", package: "swift-ai-sdk"),
                .product(name: "OpenAICompatibleProvider", package: "swift-ai-sdk"),
                .product(name: "AnthropicProvider", package: "swift-ai-sdk"),
                .product(name: "GoogleProvider", package: "swift-ai-sdk"),
                .product(name: "Litext", package: "Litext"),
                .product(name: "MarkdownView", package: "MarkdownView"),
                .product(name: "MarkdownParser", package: "MarkdownView")
            ],
            resources: [.process("Resources")]
        )
    ]
)
