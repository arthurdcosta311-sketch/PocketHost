// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NodeMobileRuntime",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NodeMobile", targets: ["NodeMobile"])
    ],
    targets: [
        .binaryTarget(
            name: "NodeMobile",
            url: "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v18.20.4/nodejs-mobile-v18.20.4-ios.zip",
            checksum: "8c5ca3a0d1e38de7f182a5642593e82593b820efd375a14b3ecafc4bcfee620e"
        )
    ]
)
