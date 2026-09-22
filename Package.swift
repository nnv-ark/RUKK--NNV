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
        .package(path: "/Users/olafurhjordisarsonjonsson/Developer/projects/FELAG/FyrirtaekiKit"),
    ],
    targets: [
        // RUKKApp.swift carries the @main entry point used only by the Xcode app
        // target; excluding it here keeps the SwiftPM library linkable into tests.
        .target(name: "RUKK",
                dependencies: [.product(name: "FyrirtaekiKit", package: "FyrirtaekiKit")],
                exclude: ["RUKKApp.swift"]),
        // FyrirtaekiKit beint inn í prófin líka: FELAG-skráin sem fer á milli
        // tækja er skilgreind þar og prófin bera sniðið saman við hana.
        .testTarget(name: "RUKKTests",
                    dependencies: ["RUKK",
                                   .product(name: "FyrirtaekiKit", package: "FyrirtaekiKit")],
                    resources: [.copy("Fixtures")])
    ]
)
