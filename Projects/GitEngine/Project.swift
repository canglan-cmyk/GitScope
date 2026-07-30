import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.framework(
    name: "GitEngine",
    dependencies: [
        .project(target: "DiffCore", path: "../DiffCore"),
    ]
)
