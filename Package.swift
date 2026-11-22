// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DADFoundation",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DADFoundation", targets: ["DADFoundation"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", exact: "1.14.1"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", exact: "1.13.1"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", exact: "1.3.2"),
        .package(url: "https://github.com/apple/swift-http-types", exact: "1.8.0"),
    ],
    targets: [
        .target(name: "DADFoundation", dependencies: [
            .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
        ], resources: [.copy("links.json"), .copy("ui-catalog.json"), .copy("ui-binds.json")], plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]),
        .testTarget(name: "DADFoundationTests", dependencies: ["DADFoundation", .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")]),
    ]
)
