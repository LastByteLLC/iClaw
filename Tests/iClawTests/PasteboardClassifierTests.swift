import XCTest
@testable import iClawCore

final class PasteboardClassifierTests: XCTestCase {

    // MARK: - Code Detection

    func testLooksLikeCode_SwiftFunction() {
        let code = """
        func greet(name: String) {
            let message = "Hello, \\(name)"
            return message
        }
        """
        XCTAssertTrue(PasteboardClassifier.looksLikeCode(code))
    }

    func testLooksLikeCode_PythonImport() {
        let code = """
        import os
        import sys

        def main():
            pass
        """
        XCTAssertTrue(PasteboardClassifier.looksLikeCode(code))
    }

    func testLooksLikeCode_PlainText() {
        let text = "Hello, this is just a regular message with no code in it."
        XCTAssertFalse(PasteboardClassifier.looksLikeCode(text))
    }

    func testLooksLikeCode_SingleIndicator() {
        // One line with "import" isn't enough (need >= 2)
        let text = "import something\nThis is just text."
        // "import " appears once at line start — should not be classified as code
        // Actually "import " is one indicator line. Need 2.
        XCTAssertFalse(PasteboardClassifier.looksLikeCode(text))
    }

    func testLooksLikeCode_JavaScript() {
        let code = """
        const x = 10;
        const y = () => {
            return x + 1;
        };
        """
        XCTAssertTrue(PasteboardClassifier.looksLikeCode(code))
    }

    func testLooksLikeCode_EmptyString() {
        XCTAssertFalse(PasteboardClassifier.looksLikeCode(""))
    }

    // MARK: - Hash

    func testHashPrefix_Deterministic() {
        let data = Data("Hello, world!".utf8)
        let hash1 = PasteboardClassifier.hashPrefix(data)
        let hash2 = PasteboardClassifier.hashPrefix(data)
        XCTAssertEqual(hash1, hash2)
    }

    func testHashPrefix_DifferentData() {
        let data1 = Data("Hello".utf8)
        let data2 = Data("World".utf8)
        XCTAssertNotEqual(PasteboardClassifier.hashPrefix(data1), PasteboardClassifier.hashPrefix(data2))
    }

    func testHashPrefix_OnlyFirst4KB() {
        // Two data blocks identical in first 4KB should have the same hash
        let base = Data(repeating: 0xAA, count: 4096)
        let data1 = base + Data(repeating: 0x01, count: 100)
        let data2 = base + Data(repeating: 0x02, count: 200)
        XCTAssertEqual(PasteboardClassifier.hashPrefix(data1), PasteboardClassifier.hashPrefix(data2))
    }

    // MARK: - FileAttachment Paste Init

    func testFileAttachment_PastedData_CreatesFile() {
        let data = Data("test content".utf8)
        let attachment = FileAttachment(pastedData: data, category: .text, sequence: 1, ext: "txt")
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.fileName, "pasted-content-1.txt")
        XCTAssertEqual(attachment?.fileCategory, .text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment!.url.path))

        // Cleanup
        try? FileManager.default.removeItem(at: attachment!.url)
    }

    func testFileAttachment_PastedImage_CategoryPreserved() {
        let data = Data(repeating: 0xFF, count: 100) // dummy image data
        let attachment = FileAttachment(pastedData: data, category: .image, sequence: 2, ext: "png")
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.fileName, "pasted-content-2.png")
        XCTAssertEqual(attachment?.fileCategory, .image)

        // Cleanup
        try? FileManager.default.removeItem(at: attachment!.url)
    }

    func testFileAttachment_SequenceIncrement() {
        let data = Data("code".utf8)
        let a1 = FileAttachment(pastedData: data, category: .code, sequence: 5, ext: "txt")
        let a2 = FileAttachment(pastedData: data, category: .code, sequence: 6, ext: "txt")
        XCTAssertEqual(a1?.fileName, "pasted-content-5.txt")
        XCTAssertEqual(a2?.fileName, "pasted-content-6.txt")

        // Cleanup
        try? FileManager.default.removeItem(at: a1!.url)
        try? FileManager.default.removeItem(at: a2!.url)
    }
}
