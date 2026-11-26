// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadLibrary",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadLibrary", targets: ["MoonreadLibrary"])],
    dependencies: [
        .package(path: "../MoonreadCoreBindings"),
        .package(path: "../MoonreadData"),
        .package(path: "../MoonreadDesign"),
        .package(path: "../MoonreadStatistics")
    ],
    targets: [
        .target(name: "MoonreadLibrary", dependencies: [
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings"),
            .product(name: "MoonreadSearchText", package: "MoonreadData"),
            .product(name: "MoonreadData", package: "MoonreadData"),
            .product(name: "MoonreadDataTypes", package: "MoonreadData"),
            .product(name: "MoonreadDesign", package: "MoonreadDesign"),
            .product(name: "MoonreadStatistics", package: "MoonreadStatistics"),
            .product(name: "MoonreadStatisticsDates", package: "MoonreadStatistics")
        ], resources: [.process("Resources")])
    ]
)
