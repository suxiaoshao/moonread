// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadDesign",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadDesign", targets: ["MoonreadDesign"])],
    targets: [.target(name: "MoonreadDesign")]
)
