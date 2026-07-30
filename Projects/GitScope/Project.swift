import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
    name: "GitScope",
    packages: [
        .remote(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            requirement: .upToNextMajor(from: "1.2.0")
        ),
    ],
    settings: .settings(
        base: sharedSettings.merging([
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        ]) { _, new in new }
    ),
    targets: [
        .target(
            name: "GitScope",
            destinations: [.mac],
            product: .app,
            bundleId: baseBundleID,
            deploymentTargets: deploymentTarget,
            infoPlist: .extendingDefault(with: [
                "NSHumanReadableCopyright": "© 2026 canglan",
                "NSMainStoryboardFile": "",
                "NSPrincipalClass": "NSApplication",
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "DiffCore", path: "../DiffCore"),
                .project(target: "DiffRenderKit", path: "../DiffRenderKit"),
                .project(target: "GitEngine", path: "../GitEngine"),
                .package(product: "SwiftTerm"),
            ]
        ),
    ]
)
