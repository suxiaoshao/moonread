// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadLibrary",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadLibrary", targets: ["MoonreadLibrary"])],
    dependencies: [
        .package(path: "../MoonreadCoreBindings"),
        .package(path: "../MoonreadData"),
        .package(path: "../MoonreadDesign")
    ],
    targets: [
        .target(name: "MoonreadLibrary", dependencies: [
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings"),
            .product(name: "MoonreadData", package: "MoonreadData"),
            .product(name: "MoonreadDataTypes", package: "MoonreadData"),
            .product(name: "MoonreadDesign", package: "MoonreadDesign")
        ])
    ]
)
