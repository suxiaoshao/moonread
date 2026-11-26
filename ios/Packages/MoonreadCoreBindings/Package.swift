// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadCoreBindings",
    platforms: [.iOS(.v18)],
    products: [.library(name: "MoonreadCoreBindings", targets: ["MoonreadCoreBindings"])],
    targets: [
        .systemLibrary(name: "moonread_coreFFI"),
        .target(name: "MoonreadCoreBindings", dependencies: ["moonread_coreFFI"])
    ]
)
