import Testing
@testable import DiffCore

@Suite("UnifiedDiffParser")
struct UnifiedDiffParserTests {

    @Test("解析单文件修改 diff")
    func parseSimpleModification() throws {
        let text = """
        diff --git a/Sources/Counter.swift b/Sources/Counter.swift
        index 1111111..2222222 100644
        --- a/Sources/Counter.swift
        +++ b/Sources/Counter.swift
        @@ -1,3 +1,3 @@
         struct Counter {
        -    var value: Int
        +    private(set) var value: Int
         }
        """

        let document = try UnifiedDiffParser().parse(text)

        #expect(document.files.count == 1)
        let file = try #require(document.files.first)
        #expect(file.change == .modified)
        #expect(file.oldPath == "Sources/Counter.swift")
        #expect(file.newPath == "Sources/Counter.swift")
        #expect(file.hunks.count == 1)

        let hunk = try #require(file.hunks.first)
        #expect(hunk.oldStart == 1 && hunk.oldCount == 3)
        #expect(hunk.newStart == 1 && hunk.newCount == 3)
        #expect(hunk.lines.count == 4)

        #expect(hunk.lines[0].change == .context)
        #expect(hunk.lines[0].oldLineNumber == 1)
        #expect(hunk.lines[0].newLineNumber == 1)

        #expect(hunk.lines[1].change == .deletion)
        #expect(hunk.lines[1].oldLineNumber == 2)
        #expect(hunk.lines[1].newLineNumber == nil)
        #expect(hunk.lines[1].content == "    var value: Int")

        #expect(hunk.lines[2].change == .addition)
        #expect(hunk.lines[2].oldLineNumber == nil)
        #expect(hunk.lines[2].newLineNumber == 2)

        #expect(hunk.lines[3].change == .context)
        #expect(hunk.lines[3].oldLineNumber == 3)
        #expect(hunk.lines[3].newLineNumber == 3)

        #expect(file.additionCount == 1)
        #expect(file.deletionCount == 1)
    }

    @Test("解析多文件 diff 与新增/删除文件")
    func parseMultiFile() throws {
        let text = """
        diff --git a/New.swift b/New.swift
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/New.swift
        @@ -0,0 +1,2 @@
        +line one
        +line two
        diff --git a/Gone.swift b/Gone.swift
        deleted file mode 100644
        index 1111111..0000000
        --- a/Gone.swift
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -so long
        """

        let document = try UnifiedDiffParser().parse(text)

        #expect(document.files.count == 2)
        #expect(document.files[0].change == .added)
        #expect(document.files[0].oldPath == nil)
        #expect(document.files[0].newPath == "New.swift")
        #expect(document.files[0].additionCount == 2)

        #expect(document.files[1].change == .deleted)
        #expect(document.files[1].newPath == nil)
        #expect(document.files[1].oldPath == "Gone.swift")
        #expect(document.files[1].deletionCount == 1)

        #expect(document.totalAdditions == 2)
        #expect(document.totalDeletions == 1)
    }

    @Test("解析重命名")
    func parseRename() throws {
        let text = """
        diff --git a/Old.swift b/Renamed.swift
        similarity index 95%
        rename from Old.swift
        rename to Renamed.swift
        index 1111111..2222222 100644
        --- a/Old.swift
        +++ b/Renamed.swift
        @@ -1,2 +1,2 @@
         unchanged
        -old line
        +new line
        """

        let document = try UnifiedDiffParser().parse(text)
        let file = try #require(document.files.first)
        #expect(file.change == .renamed)
        #expect(file.oldPath == "Old.swift")
        #expect(file.newPath == "Renamed.swift")
        #expect(file.canonicalPath == "Renamed.swift")
    }

    @Test("解析二进制文件标记")
    func parseBinary() throws {
        let text = """
        diff --git a/logo.png b/logo.png
        index 1111111..2222222 100644
        Binary files a/logo.png and b/logo.png differ
        """

        let document = try UnifiedDiffParser().parse(text)
        let file = try #require(document.files.first)
        #expect(file.isBinary)
        #expect(file.hunks.isEmpty)
    }

    @Test("处理文件末尾无换行标记")
    func parseNoNewlineMarker() throws {
        let text = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,1 +1,1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """

        let document = try UnifiedDiffParser().parse(text)
        let hunk = try #require(document.files.first?.hunks.first)
        #expect(hunk.lines[0].hasNoTrailingNewline)
        #expect(hunk.lines[1].hasNoTrailingNewline)
    }

    @Test("解析 hunk section heading")
    func parseSectionHeading() throws {
        let text = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -10,3 +10,3 @@ func doWork() {
         context
        -before
        +after
        """

        let document = try UnifiedDiffParser().parse(text)
        let hunk = try #require(document.files.first?.hunks.first)
        #expect(hunk.sectionHeading == "func doWork() {")
        #expect(hunk.headerText == "@@ -10,3 +10,3 @@ func doWork() {")
    }

    @Test("非法 hunk 头抛错")
    func malformedHunkHeaderThrows() {
        let text = """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ bogus @@
        """
        #expect(throws: UnifiedDiffParser.ParseError.self) {
            try UnifiedDiffParser().parse(text)
        }
    }

    @Test("空输入产出空文档")
    func emptyInput() throws {
        let document = try UnifiedDiffParser().parse("")
        #expect(document.files.isEmpty)
    }
}

@Suite("IntralineHighlighter")
struct IntralineHighlighterTests {

    @Test("前缀/后缀裁剪出中间变更区")
    func basicTrim() {
        let ranges = IntralineHighlighter.highlightRanges(
            deleted: "let x = oldValue()",
            added: "let x = newValue()"
        )
        // "let x = " 共 8 字符前缀, "Value()" 共 7 字符后缀
        #expect(ranges.deleted == 8..<11)  // "old"
        #expect(ranges.added == 8..<11)    // "new"
    }

    @Test("完全相同的行不产生高亮")
    func identicalLines() {
        let ranges = IntralineHighlighter.highlightRanges(
            deleted: "same",
            added: "same"
        )
        #expect(ranges.deleted == nil)
        #expect(ranges.added == nil)
    }

    @Test("多字节字符按字符边界裁剪")
    func multibyteBoundary() {
        let ranges = IntralineHighlighter.highlightRanges(
            deleted: "print(\"你好\")",
            added: "print(\"再见\")"
        )
        #expect(ranges.deleted == 7..<9)
        #expect(ranges.added == 7..<9)
    }

    @Test("等量增删配对高亮,不等量跳过")
    func hunkAnnotation() {
        var hunk = DiffHunk(
            oldStart: 1, oldCount: 3, newStart: 1, newCount: 3,
            lines: [
                DiffLine(change: .context, oldLineNumber: 1, newLineNumber: 1, content: "ctx"),
                DiffLine(change: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "let a = 1"),
                DiffLine(change: .addition, oldLineNumber: nil, newLineNumber: 2, content: "let a = 2"),
                DiffLine(change: .context, oldLineNumber: 3, newLineNumber: 3, content: "ctx"),
            ]
        )
        IntralineHighlighter.annotate(hunk: &hunk)
        #expect(hunk.lines[1].intralineHighlight == 8..<9)
        #expect(hunk.lines[2].intralineHighlight == 8..<9)

        var unbalanced = DiffHunk(
            oldStart: 1, oldCount: 2, newStart: 1, newCount: 1,
            lines: [
                DiffLine(change: .deletion, oldLineNumber: 1, newLineNumber: nil, content: "one"),
                DiffLine(change: .deletion, oldLineNumber: 2, newLineNumber: nil, content: "two"),
                DiffLine(change: .addition, oldLineNumber: nil, newLineNumber: 1, content: "merged"),
            ]
        )
        IntralineHighlighter.annotate(hunk: &unbalanced)
        #expect(unbalanced.lines.allSatisfy { $0.intralineHighlight == nil })
    }
}
