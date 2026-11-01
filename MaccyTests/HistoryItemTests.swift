import AppKit
import Testing
import Defaults
@testable import Maccy

private final class BundleToken {}

private func textImage(_ text: String) -> NSImage {
  let string = NSAttributedString(string: text, attributes: [
    .font: NSFont.boldSystemFont(ofSize: 48),
    .foregroundColor: NSColor.black
  ])
  let size = NSSize(width: string.size().width + 40, height: string.size().height + 40)
  return NSImage(size: size, flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    string.draw(at: NSPoint(x: 20, y: 20))
    return true
  }
}

private let stringTitleCases: [(input: String, title: String)] = [
  ("foo", "foo"),
  ("   foo bar   ", "···foo bar···"),
  ("\nfoo\nbar\n", "⏎foo⏎bar⏎"),
  ("\tfoo\tbar\t", "⇥foo⇥bar⇥")
]

private let objectReplacementTitleCases: [(input: String, title: String)] = [
  ("\u{FFFC}foo\u{FFFC}bar\u{FFFC}", "foobar"),
  ("\u{FFFC}\u{FFFC}", "")
]

extension SharedStateTests {
  @MainActor
  struct HistoryItemTests {
    private let blobType = NSPasteboard.PasteboardType("org.p0deje.Maccy.tests.blob")

    @Test("Sorted pins place letters before symbols")
    func sortedPinsPlacesLettersBeforeSymbols() {
      #expect(
        HistoryItem.sortedPins(["/", "c", "[", "b", "-", "\\", "y"]) ==
        ["b", "c", "y", "-", "/", "[", "\\"]
      )
    }

    @Test("Title for string", arguments: stringTitleCases)
    func titleForString(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    // U+FFFC arrives from rich text with inline attachments and hangs CoreText
    // on macOS 26. See https://github.com/p0deje/Maccy/issues/1520.
    @Test("Title without object replacement characters", arguments: objectReplacementTitleCases)
    func titleWithObjectReplacementCharacters(input: String, title: String) {
      #expect(historyItem(input).title == title)
    }

    @Test("Title for RTF")
    func titleWithRTF() {
      let rtf = NSAttributedString(string: "foo").rtf(
        from: NSRange(0...2),
        documentAttributes: [:]
      )
      #expect(historyItem(rtf, .rtf).title == "foo")
    }

    @Test("Title for HTML")
    func titleWithHTML() {
      let html = "<a href='#'>foo</a>".data(using: .utf8)
      #expect(historyItem(html, .html).title == "foo")
    }

    @Test("Image has an empty title")
    func image() throws {
      let image = try #require(NSImage(named: "NSBluetoothTemplate"))
      #expect(historyItem(image).title == "")
    }

    @Test("Image title becomes the recognized text")
    func imageTitleBecomesRecognizedText() async throws {
      let item = historyItem(textImage("Hello Maccy"))
      let deadline = ContinuousClock.now + .seconds(10)
      while item.title.isEmpty && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(item.title == "Hello Maccy")
    }

    @Test("Title for file", arguments: ["/tmp/foo.bar", "/tmp/产品培训/产品培训.txt"])
    func file(path: String) {
      let url = URL(fileURLWithPath: path)
      #expect(historyItem(url).title == "file://\(path)")
    }

    @Test("Text from Universal Clipboard")
    func textFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let textContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: url.lastPathComponent.data(using: .utf8)
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, textContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "foo.bar")
    }

    @Test("Image from Universal Clipboard")
    func imageFromUniversalClipboard() throws {
      let url = try #require(Bundle(for: BundleToken.self).url(forResource: "guy", withExtension: "jpeg"))
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      let image = try #require(item.image)
      let expected = try #require(NSImage(data: try Data(contentsOf: url)))
      #expect(image.tiffRepresentation == expected.tiffRepresentation)
    }

    @Test("File from Universal Clipboard")
    func fileFromUniversalClipboard() {
      let url = URL(fileURLWithPath: "/tmp/foo.bar")
      let fileURLContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.fileURL.rawValue,
        value: url.dataRepresentation
      )
      let universalClipboardContent = HistoryItemContent(
        type: NSPasteboard.PasteboardType.universalClipboard.rawValue,
        value: "".data(using: .utf8)
      )
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = [fileURLContent, universalClipboardContent]
      item.title = item.generateTitle()
      #expect(item.title == "file:///tmp/foo.bar")
    }

    @Test("Item without data has an empty title")
    func itemWithoutData() {
      #expect(historyItem(nil).title == "")
    }

    @Test("Superseding compares digests")
    func supersedingComparesDigests() {
      let existing = historyItem(Data("foo".utf8), blobType)
      // Matching digests are enough, so the stored value doesn't have to be loaded.
      existing.contents[0].value = Data("not loaded".utf8)

      #expect(existing.contents[0].digest == HistoryItemContent.digest(Data("foo".utf8)))
      #expect(existing.supersedes(historyItem(Data("foo".utf8), blobType)))
      #expect(!existing.supersedes(historyItem(Data("bar".utf8), blobType)))
    }

    @Test("Superseding contents without digest")
    func supersedingContentsWithoutDigest() {
      // Stored by an older version.
      let legacy = historyItem(Data("foo".utf8), blobType)
      legacy.contents[0].digest = nil

      #expect(legacy.supersedes(historyItem(Data("foo".utf8), blobType)))
      #expect(!legacy.supersedes(historyItem(Data("bar".utf8), blobType)))
      #expect(historyItem(Data("foo".utf8), blobType).supersedes(legacy))
      #expect(!historyItem(Data("bar".utf8), blobType).supersedes(legacy))
    }

    @Test("Setting value updates digest and byte count")
    func settingValueUpdatesDigestAndByteCount() {
      let content = historyItem(Data("foo".utf8), blobType).contents[0]
      #expect(content.byteCount == 3)

      content.setValue(Data("foobar".utf8))
      #expect(content.digest == HistoryItemContent.digest(Data("foobar".utf8)))
      #expect(content.byteCount == 6)

      content.setValue(nil)
      #expect(content.digest == nil)
      #expect(content.byteCount == nil)
    }

    @Test("Image byte count does not load image")
    func imageByteCountDoesNotLoadImage() {
      let item = historyItem(Data(count: 2048), .png)
      // The recorded size is used, so the stored value doesn't have to be loaded.
      item.contents[0].value = Data("not loaded".utf8)

      #expect(item.imageByteCount == 2048)
      #expect(historyItem("foo").imageByteCount == nil)
    }

    @Test("Superseding empty contents")
    func supersedingEmptyContents() {
      #expect(historyItem(nil, blobType).supersedes(historyItem(nil, blobType)))
      #expect(!historyItem(nil, blobType).supersedes(historyItem(Data("foo".utf8), blobType)))
      #expect(!historyItem(Data("foo".utf8), blobType).supersedes(historyItem(nil, blobType)))
    }

    @Test("Several items can have an empty pin")
    func severalItemsCanHaveEmptyPin() {
      let item1 = historyItem("foo")
      item1.pin = ""
      let item2 = historyItem("bar")
      item2.pin = ""
      #expect(throws: Never.self) {
        try Storage.shared.context.save()
      }
      #expect(item1.pin == "")
      #expect(item2.pin == "")
    }

    private func historyItem(_ value: String?) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value?.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ data: Data?, _ type: NSPasteboard.PasteboardType) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: type.rawValue,
          value: data
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: NSImage) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.tiff.rawValue,
          value: value.tiffRepresentation
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }

    private func historyItem(_ value: URL) -> HistoryItem {
      let contents = [
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.fileURL.rawValue,
          value: value.dataRepresentation
        ),
        HistoryItemContent(
          type: NSPasteboard.PasteboardType.string.rawValue,
          value: value.lastPathComponent.data(using: .utf8)
        )
      ]
      let item = HistoryItem()
      Storage.shared.context.insert(item)
      item.contents = contents
      item.title = item.generateTitle()

      return item
    }
  }
}
