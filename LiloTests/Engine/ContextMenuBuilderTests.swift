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
        builder.build(menu, linkURL: nil, extensionItems: [], searchEngineName: "DuckDuckGo")

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
        makeBuilder().build(menu, linkURL: nil, extensionItems: [])
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Back".localized))
        XCTAssertTrue(titles.contains("Forward".localized))
        XCTAssertTrue(titles.contains("Reload".localized))
        XCTAssertTrue(titles.contains("Picture in Picture".localized))
        XCTAssertFalse(titles.contains("Open Link in New Tab".localized))
    }

    /// WebKit proposes the extensions' items itself: the menu shows them once, as Lilo's copies.
    func testBuildShowsAnExtensionsItemsOnce() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = try makeTestExtensionRegistry(in: folder)
        defer { registry.teardown() }
        let extensionFolder = folder.appendingPathComponent("ext")
        try FileManager.default.createDirectory(at: extensionFolder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Menu", "version": "1.0", "permissions": ["contextMenus"],
            "background": ["service_worker": "background.js"]
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: extensionFolder.appendingPathComponent("manifest.json"))
        try "chrome.contextMenus.create({ id: 'item', title: 'Extension item', contexts: ['all'] });"
            .write(to: extensionFolder.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try await registry.load(from: extensionFolder)
        let id = try XCTUnwrap(registry.loadedExtensions.last?.id)
        let context = try XCTUnwrap(registry.context(for: id))
        _ = await registry.backgrounds.load(id)
        let adapter = TabExtensionAdapter(engineTab: WKWebViewTab(id: UUID(), webView: WKWebView()))
        let created = await pollUntil { !context.menuItems(for: adapter).isEmpty }
        XCTAssertTrue(created)

        let menu = NSMenu()
        context.menuItems(for: adapter).forEach(menu.addItem)
        let ours = context.menuItems(for: adapter)
        makeBuilder().build(menu, linkURL: nil, extensionItems: ours)

        let shown = menu.items.filter { $0.title == "Extension item" }
        XCTAssertEqual(shown.count, 1)
        XCTAssertIdentical(shown.first, ours.first)
    }

    func testBuildAddsLinkActionsWhenLinkPresent() {
        let menu = NSMenu()
        makeBuilder().build(menu, linkURL: URL(string: "https://example.com"), extensionItems: [])
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

        builder.build(menu, linkURL: nil, imageURL: imageURL, extensionItems: [])

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

        builder.build(menu, linkURL: linkURL, extensionItems: [])

        let item = menu.items.first { $0.title == "Download Linked File" }
        XCTAssertNotNil(item, "an https link with no matching native item should still get a working download item")
        item.map { _ = $0.target?.perform($0.action, with: $0) }
        XCTAssertEqual(downloaded, linkURL)
    }

    func testBuildOmitsDownloadItemForMailtoLink() {
        let builder = makeBuilder()
        let menu = NSMenu()

        builder.build(menu, linkURL: URL(string: "mailto:someone@example.com"), extensionItems: [])

        XCTAssertFalse(menu.items.contains { $0.title == "Download Linked File" },
                        "mailto: links aren't downloadable: WebKit itself shows no native item for them")
    }

    func testBuildOmitsDownloadItemForJavascriptLink() {
        let builder = makeBuilder()
        let menu = NSMenu()

        builder.build(menu, linkURL: URL(string: "javascript:void(0)"), extensionItems: [])

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

        builder.build(menu, linkURL: linkURL, imageURL: nil, extensionItems: [])

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

        builder.build(menu, linkURL: nil, imageURL: imageURL, extensionItems: [])

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
