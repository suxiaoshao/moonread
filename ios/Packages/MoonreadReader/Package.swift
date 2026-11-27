// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadReader",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MoonreadReader", targets: ["MoonreadReader"]),
        .library(name: "MoonreadInstalledFonts", targets: ["MoonreadInstalledFonts"])
    ],
    dependencies: [
        .package(path: "../MoonreadCoreBindings"),
        .package(path: "../MoonreadData"),
        .package(path: "../MoonreadDesign")
    ],
    targets: [
        .target(name: "MoonreadReader", dependencies: [
            "MoonreadInstalledFonts",
            .product(name: "MoonreadDataTypes", package: "MoonreadData"),
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings"),
            .product(name: "MoonreadData", package: "MoonreadData"),
            .product(name: "MoonreadDesign", package: "MoonreadDesign")
        ]),
        .target(name: "MoonreadInstalledFonts")
    ]
)
