// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadStatistics",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadStatistics", targets: ["MoonreadStatistics"])],
    dependencies: [
        .package(path: "../MoonreadCoreBindings"),
        .package(path: "../MoonreadData"),
        .package(path: "../MoonreadDesign")
    ],
    targets: [
        .target(name: "MoonreadStatistics", dependencies: [
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings"),
            .product(name: "MoonreadDataTypes", package: "MoonreadData"),
            .product(name: "MoonreadDesign", package: "MoonreadDesign")])
    ]
)
