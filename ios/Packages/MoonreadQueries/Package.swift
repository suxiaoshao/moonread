// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoonreadQueries",
    platforms: [.iOS(.v18)],
    products: [
        .library(name: "MoonreadQueries", targets: ["MoonreadQueries"])
    ],
    dependencies: [
        .package(url: "https://github.com/apollographql/apollo-ios", exact: "2.5.0")
    ],
    targets: [
        .target(
            name: "MoonreadQueries",
            dependencies: [
                .product(name: "ApolloAPI", package: "apollo-ios")
            ]
        )
    ]
)
