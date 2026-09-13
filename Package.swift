// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RUKK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RUKK", targets: ["RUKK"])
    ],
    dependencies: [
        // Sameiginleg fyrirtækjaskrá FELAG (nafn, kennitala, VSK, banki, merki…).
        .package(path: "/Users/olafurhjordisarsonjonsson/Developer/FELAG/FyrirtaekiKit"),
    ],
    targets: [
        // RUKKApp.swift carries the @main entry point used only by the Xcode app
        // target; excluding it here keeps the SwiftPM library linkable into tests.
        .target(name: "RUKK",
                dependencies: [.product(name: "FyrirtaekiKit", package: "FyrirtaekiKit")],
                exclude: ["RUKKApp.swift"]),
        .testTarget(name: "RUKKTests", dependencies: ["RUKK"],
                    resources: [.copy("Fixtures")])
    ]
)
