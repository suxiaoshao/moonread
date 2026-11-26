// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadData",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MoonreadData", targets: ["MoonreadData"]),
        .library(name: "MoonreadDataTypes", targets: ["MoonreadDataTypes"])
    ],
    dependencies: [
        .package(path: "../MoonreadCoreBindings"),
        .package(path: "../MoonreadQueries"),
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.12.0")
    ],
    targets: [
        .target(name: "MoonreadData", dependencies: [
            "MoonreadDataTypes",
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings"),
            .product(name: "MoonreadQueries", package: "MoonreadQueries"),
            .product(name: "GRDB", package: "GRDB.swift")
        ]),
        .target(name: "MoonreadDataTypes", dependencies: [
            .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings")
        ])
    ]
)
