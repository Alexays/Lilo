import XCTest
import WebKit
@testable import Lilo

@MainActor
final class ContextMenuBuilderTests: XCTestCase {
    private func makeBuilder(onDownload: @escaping (URL) -> Void = { _ in }, onSearchWeb: @escaping () -> Void = {}) -> ContextMenuBuilder {
        ContextMenuBuilder(
            webView: WKWebView(frame: .zero),
            onOpenInNewTab: { _ in },
            onOpenInPrivateSpace: { _ in },
            onOpenInNewWindow: { _ in },
            onTogglePiP: {},
            onBookmark: {},
            onHideElement: {},
            onDownload: onDownload,
            onSearchWeb: onSearchWeb
        )
    }

    func testSearchWebItemSearchesWithLiloEngine() throws {
        var searched = false
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Search with Google", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")
        let builder = makeBuilder(onSearchWeb: { searched = true })
        builder.build(menu, linkURL: nil, searchEngineName: "DuckDuckGo")

        XCTAssertEqual(item.title, String(format: "Search with %@".localized, "DuckDuckGo"))
        let action = try XCTUnwrap(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(searched)
    }

    func testIsOpenInNewWindowItemMatchesWebKitIdentifierLoosely() {
        let match = NSMenuItem()
        match.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierOpenLinkInNewWindow")
        XCTAssertTrue(ContextMenuBuilder.isOpenInNewWindowItem(match))

        let other = NSMenuItem()
        other.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
        XCTAssertFalse(ContextMenuBuilder.isOpenInNewWindowItem(other))

        XCTAssertFalse(ContextMenuBuilder.isOpenInNewWindowItem(NSMenuItem()))
    }

    func testBuildAppendsNavigationAndPiPItems() {
        let menu = NSMenu()
        makeBuilder().build(menu, linkURL: nil)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Back".localized))
        XCTAssertTrue(titles.contains("Forward".localized))
        XCTAssertTrue(titles.contains("Reload".localized))
        XCTAssertTrue(titles.contains("Picture in Picture".localized))
        XCTAssertFalse(titles.contains("Open Link in New Tab".localized))
    }

    /// As Chrome, a link, media, selection or text field menu has no Back, Reload, page or PiP items.
    func testPageItemsStayOutOfLinkMediaSelectionAndFieldMenus() {
        let pageTitles = ["Back", "Forward", "Reload", "Bookmark This Page", "Picture in Picture"].map(\.localized)
        func titles(linkURL: URL? = nil, imageURL: URL? = nil, element: NSObject? = nil) -> Set<String> {
            let menu = NSMenu()
            makeBuilder().build(menu, linkURL: linkURL, imageURL: imageURL, element: element)
            return Set(menu.items.map(\.title)).intersection(pageTitles)
        }
        XCTAssertEqual(titles(), Set(pageTitles).subtracting(["Bookmark This Page".localized]), "a blank web view has no page URL")
        XCTAssertEqual(titles(linkURL: URL(string: "https://example.com/a")), [])
        XCTAssertEqual(titles(imageURL: URL(string: "https://example.com/a.mp4")), [])
        XCTAssertEqual(titles(element: FakeElementInfo(editable: true, selected: false)), [])
        XCTAssertEqual(titles(element: FakeElementInfo(editable: false, selected: true)), [])
        XCTAssertEqual(titles(element: FakeElementInfo(editable: false, selected: false)).count, 4)
    }

    func testBuildAddsLinkActionsWhenLinkPresent() {
        let menu = NSMenu()
        makeBuilder().build(menu, linkURL: URL(string: "https://example.com"))
        let linkItem = menu.items.first { $0.title == "Open Link in New Tab".localized }
        XCTAssertNotNil(linkItem)
        XCTAssertEqual(linkItem?.representedObject as? URL, URL(string: "https://example.com"))
        XCTAssertTrue(menu.items.contains { $0.title == "Open Link in New Private Space".localized })
        XCTAssertTrue(menu.items.contains { $0.title == "Open Link in New Window".localized })
    }

    func testBuildAddsWorkingDownloadImageItemWhenImagePresent() {
        var downloaded: URL?
        let builder = makeBuilder(onDownload: { downloaded = $0 })
        let menu = NSMenu()
        let imageURL = URL(string: "https://example.com/cat.png")!

        builder.build(menu, linkURL: nil, imageURL: imageURL)

        let item = menu.items.first { $0.title == "Download Image" }
        XCTAssertNotNil(item, "menu should offer a working Download Image item")
        XCTAssertEqual(item?.representedObject as? URL, imageURL)

        item.map { _ = $0.target?.perform($0.action, with: $0) }
        XCTAssertEqual(downloaded, imageURL, "triggering the item routes the image URL to onDownload")
    }

    func testBuildAddsDownloadLinkedFileItemForHTTPSLinkWhenNoImage() {
        var downloaded: URL?
        let builder = makeBuilder(onDownload: { downloaded = $0 })
        let menu = NSMenu()
        let linkURL = URL(string: "https://example.com/file.zip")!

        builder.build(menu, linkURL: linkURL)

        let item = menu.items.first { $0.title == "Download Linked File" }
        XCTAssertNotNil(item, "an https link with no matching native item should still get a working download item")
        item.map { _ = $0.target?.perform($0.action, with: $0) }
        XCTAssertEqual(downloaded, linkURL)
    }

    func testBuildOmitsDownloadItemForMailtoLink() {
        let builder = makeBuilder()
        let menu = NSMenu()

        builder.build(menu, linkURL: URL(string: "mailto:someone@example.com"))

        XCTAssertFalse(menu.items.contains { $0.title == "Download Linked File" },
                        "mailto: links aren't downloadable: WebKit itself shows no native item for them")
    }

    func testBuildOmitsDownloadItemForJavascriptLink() {
        let builder = makeBuilder()
        let menu = NSMenu()

        builder.build(menu, linkURL: URL(string: "javascript:void(0)"))

        XCTAssertFalse(menu.items.contains { $0.title == "Download Linked File" })
    }

    func testImageItemDoesNotFallBackToLinkURLWhenImageURLIsNil() {
        var downloaded: URL?
        let builder = makeBuilder(onDownload: { downloaded = $0 })
        let menu = NSMenu()
        // Simulate WebKit's native "Download Image" item with no resolvable imageURL, but a linkURL
        // present (e.g. a linked, non-image element). It must NOT retarget onto the link's URL.
        let native = NSMenuItem(title: "Download Image", action: Selector(("webkitInternal:")), keyEquivalent: "")
        native.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImage")
        menu.addItem(native)
        let linkURL = URL(string: "https://example.com/page")!

        builder.build(menu, linkURL: linkURL, imageURL: nil)

        let downloadItems = menu.items.filter { ContextMenuBuilder.isDownloadImageItem($0) }
        XCTAssertEqual(downloadItems.count, 1, "native item is left in place, not duplicated")
        let item = downloadItems.first
        XCTAssertNotEqual(item?.representedObject as? URL, linkURL,
                           "must not retarget the image item onto the unrelated link URL")
        XCTAssertNil(item?.representedObject, "left dead: no represented URL at all")
        XCTAssertFalse(item?.target === builder, "left dead: not retargeted to the builder")
        XCTAssertNil(downloaded, "the dead native item performs no download")
    }

    func testBuildRetargetsNativeDownloadImageItemPreservingItsLocalizedTitle() {
        var downloaded: URL?
        let builder = makeBuilder(onDownload: { downloaded = $0 })
        let menu = NSMenu()
        // Simulate WebKit's non-functional native item, with an OS-localized title.
        let native = NSMenuItem(title: "Télécharger l’image", action: Selector(("webkitInternal:")), keyEquivalent: "")
        native.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierDownloadImage")
        menu.addItem(native)
        let imageURL = URL(string: "https://example.com/cat.png")!

        builder.build(menu, linkURL: nil, imageURL: imageURL)

        let downloadItems = menu.items.filter { ContextMenuBuilder.isDownloadImageItem($0) }
        XCTAssertEqual(downloadItems.count, 1, "native item retargeted in place, not duplicated")
        let item = downloadItems.first
        XCTAssertEqual(item?.title, "Télécharger l’image", "WebKit's localized title is preserved")
        XCTAssertTrue(item?.target === builder, "action is retargeted to the builder")
        XCTAssertEqual(item?.representedObject as? URL, imageURL)
        item.map { _ = $0.target?.perform($0.action, with: $0) }
        XCTAssertEqual(downloaded, imageURL)
    }
}

/// `_WKContextMenuElementInfo` and its `_WKHitTestResult`, as far as the builder reads them.
private final class FakeElementInfo: NSObject {
    private final class HitTestResult: NSObject {
        @objc let isContentEditable: Bool
        @objc let isSelected: Bool
        init(editable: Bool, selected: Bool) { isContentEditable = editable; isSelected = selected }
    }
    @objc let hitTestResult: NSObject
    init(editable: Bool, selected: Bool) { hitTestResult = HitTestResult(editable: editable, selected: selected) }
}
