// swift-tools-version: 6.0
import PackageDescription

// As plataformas abaixo documentam onde este pacote roda de verdade (o app iOS).
// Elas não impedem `swift build`/`swift test` no toolchain de Windows, que é
// justamente o ponto: EditorCore só depende de Foundation, então a lógica pura
// é desenvolvida e validada localmente, sem Mac e sem CI.
let package = Package(
    name: "EditorCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "EditorCore", targets: ["EditorCore"])
    ],
    targets: [
        .target(name: "EditorCore"),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
    ]
)
