import ProjectDescription
import ProjectDescriptionHelpers

let project = Project.framework(
    name: "DiffRenderKit",
    dependencies: [
        .project(target: "DiffCore", path: "../DiffCore"),
    ]
)
