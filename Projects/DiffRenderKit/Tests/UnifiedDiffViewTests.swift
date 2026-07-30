import AppKit
import Testing
import DiffCore
@testable import DiffRenderKit

@Suite("UnifiedDiffView", .serialized)
@MainActor
struct UnifiedDiffViewTests {

    private func makeSampleFileDiff() throws -> FileDiff {
        let text = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@
         context line
        -let value = 1
        +let value = 2
        """
        var file = try #require(try UnifiedDiffParser().parse(text).files.first)
        IntralineHighlighter.annotate(file: &file)
        return file
    }

    @Test("布局高度 = 行数 × 行高")
    func layoutHeightMatchesRowCount() throws {
        let view = UnifiedDiffView(frame: .zero)
        view.fileDiff = try makeSampleFileDiff()

        // 1 hunk header + 3 lines = 4 rows
        let height = view.layoutHeight(forWidth: 800)
        #expect(height == 4 * view.rowHeight)
        #expect(view.intrinsicContentSize.height == height)
    }

    @Test("空 diff 高度为 0")
    func emptyDiff() {
        let view = UnifiedDiffView(frame: .zero)
        #expect(view.layoutHeight(forWidth: 800) == 0)
    }

    @Test("离屏渲染不崩溃且产生非空位图")
    func offscreenRenderSmoke() throws {
        let view = UnifiedDiffView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        view.fileDiff = try makeSampleFileDiff()
        let height = view.layoutHeight(forWidth: 600)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: height)

        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
    }

    @Test("行高与字体度量一致")
    func rowHeightFollowsFontMetrics() {
        let view = UnifiedDiffView(frame: .zero)
        #expect(view.rowHeight > view.theme.fontSize)
        #expect(view.rowDescent > 0)
    }
}
