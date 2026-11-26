// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadData",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadDataTypes", targets: ["MoonreadDataTypes"])],
    dependencies: [.package(path: "../MoonreadCoreBindings")],
    targets: [
        .target(name: "MoonreadDataTypes", dependencies: [
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings")
        ])
    ]
)
