// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadDesign",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadDesign", targets: ["MoonreadDesign"])],
    dependencies: [.package(path: "../MoonreadCoreBindings")],
    targets: [.target(name: "MoonreadDesign", dependencies: [
        .product(name: "MoonreadCoreBindings", package: "MoonreadCoreBindings")
    ])]
)
