import ProjectDescription
import ProjectDescriptionHelpers

let appVersion = "0.3.0"

let project = Project(
    name: "GitScope",
    packages: [
        .remote(
            url: "https://github.com/sparkle-project/Sparkle",
            requirement: .upToNextMajor(from: "2.6.0")
        ),
    ],
    settings: .settings(
        base: sharedSettings.merging([
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "MARKETING_VERSION": SettingValue(stringLiteral: appVersion),
            "CURRENT_PROJECT_VERSION": SettingValue(stringLiteral: appVersion),
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
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                // Sparkle auto-update configuration.
                "SUFeedURL": "https://canglan-cmyk.github.io/GitScope/appcast.xml",
                "SUPublicEDKey": "j5c4mqs6kNRfM1XmjWFAyFGj0DNfR6ax181ZV0dRumA=",
                "SUEnableAutomaticChecks": true,
            ]),
            sources: ["Sources/**"],
            resources: ["Resources/**"],
            dependencies: [
                .project(target: "DiffCore", path: "../DiffCore"),
                .project(target: "DiffRenderKit", path: "../DiffRenderKit"),
                .project(target: "GitEngine", path: "../GitEngine"),
                .package(product: "Sparkle"),
            ]
        ),
    ]
)
