import AppKit
import CoreImage.CIFilterBuiltins

// `@preconcurrency`: NSSharingServicePickerDelegate isn't @MainActor-annotated in the SDK, but
// AppKit only calls it on the main thread, so the MainActor-isolated implementation is safe.
extension MainWindowController: @preconcurrency NSSharingServicePickerDelegate {

    /// The active tab's URL if it is a shareable web page (http/https), else nil.
    /// Internal pages (`about:`), `file:`, `data:`, and custom schemes are excluded:
    /// Share works on web pages only.
    func shareableURL() -> URL? {
        guard let url = tabManager.visibleActiveTab?.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Presents the system share sheet for the current page, anchored to the
    /// window. No-ops on non-shareable pages (the menu item is also greyed out).
    @objc func shareCurrentPage(_ sender: Any?) {
        guard let url = shareableURL(),
              let view = window?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.delegate = self
        activeSharePicker = picker
        // A 1pt anchor at the top-center of the content view; the popover drops down from there.
        let anchor = NSRect(x: view.bounds.midX, y: view.bounds.maxY - 1, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        // Attach the page title as the subject (e.g. the Mail subject line).
        service?.subject = tabManager.activeTab?.title ?? ""
        activeSharePicker = nil
    }
}

// MARK: - QR code

extension MainWindowController {
    /// A QR code of the page's address, crisp at `side` points: the way to hand a page to a phone that
    /// Handoff and AirDrop do not reach.
    static func qrCode(for url: URL, side: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let code = filter.outputImage else { return nil }
        let scale = (side * 2 / code.extent.width).rounded(.down)
        let scaled = code.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(representation)
        image.accessibilityDescription = String(format: "QR code for %@".localized, url.host() ?? url.absoluteString)
        return image
    }

    @objc func showQRCode(_ sender: Any?) {
        guard let url = shareableURL(), let window, let image = Self.qrCode(for: url, side: 220) else { return }
        let alert = NSAlert()
        alert.messageText = "Scan to Open This Page".localized
        alert.informativeText = url.host() ?? url.absoluteString
        let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 220, height: 220))
        imageView.image = image
        alert.accessoryView = imageView
        alert.addButton(withTitle: "Done".localized)
        alert.addButton(withTitle: "Copy Image".localized)
        alert.addButton(withTitle: "Save...".localized)
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertSecondButtonReturn:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            case .alertThirdButtonReturn:
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "\(url.host() ?? "page") QR.png"
                panel.beginSheetModal(for: window) { result in
                    guard result == .OK, let destination = panel.url,
                          let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                    else { return }
                    do { try png.write(to: destination) } catch { NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil) }
                }
            default:
                break
            }
        }
    }
}
