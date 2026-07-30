import ProjectDescription

public let deploymentTarget: DeploymentTargets = .macOS("14.0")
public let baseBundleID = "im.canglan.gitscope"

public let sharedSettings: SettingsDictionary = [
    "SWIFT_VERSION": "6.0",
    "SWIFT_STRICT_CONCURRENCY": "complete",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
]

extension Project {
    /// Framework module + unit test bundle.
    public static func framework(
        name: String,
        dependencies: [TargetDependency] = [],
        testDependencies: [TargetDependency] = []
    ) -> Project {
        Project(
            name: name,
            settings: .settings(base: sharedSettings),
            targets: [
                .target(
                    name: name,
                    destinations: [.mac],
                    product: .framework,
                    bundleId: "\(baseBundleID).\(name.lowercased())",
                    deploymentTargets: deploymentTarget,
                    sources: ["Sources/**"],
                    dependencies: dependencies
                ),
                .target(
                    name: "\(name)Tests",
                    destinations: [.mac],
                    product: .unitTests,
                    bundleId: "\(baseBundleID).\(name.lowercased()).tests",
                    deploymentTargets: deploymentTarget,
                    sources: ["Tests/**"],
                    dependencies: [.target(name: name)] + testDependencies
                ),
            ]
        )
    }
}
