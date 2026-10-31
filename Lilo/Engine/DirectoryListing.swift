import Foundation

/// The page a `file:` folder shows, as Chrome's "Index of": WebKit loads nothing for a folder.
enum DirectoryListing {
    /// The table rows of the folder's files, for the page's `tbody`. Nil when the folder cannot be read.
    static func rows(of url: URL) -> String? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return nil }

        let locale = Locale(identifier: Localization.locale)
        let sizeStyle = ByteCountFormatStyle(style: .file).locale(locale)
        let dateStyle = Date.FormatStyle(date: .numeric, time: .shortened).locale(locale)
        // A relative href would read a colon in a name as a scheme.
        var nameAllowed = CharacterSet.urlPathAllowed
        nameAllowed.remove(charactersIn: "/:")
        let rows = entries.map { entry in
            var values = try? entry.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true, let target = try? entry.resolvingSymlinksInPath().resourceValues(forKeys: Set(keys)) {
                values = target
            }
            return (name: entry.lastPathComponent, isDirectory: values?.isDirectory == true,
                    size: values?.fileSize ?? 0, modified: values?.contentModificationDate)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var body = ""
        for row in rows {
            let name = ViewSourceSchemeHandler.escape(row.name)
            let href = ViewSourceSchemeHandler.escape(row.name.addingPercentEncoding(withAllowedCharacters: nameAllowed) ?? "")
            body += """
                <tr data-dir="\(row.isDirectory ? 1 : 0)"><td data-value="\(name)"><a href="\(href)\(row.isDirectory ? "/" : "")">\
                <svg aria-hidden="true"><use href="#\(row.isDirectory ? "folder" : "file")"/></svg>\(name)</a></td>\
                <td data-value="\(row.isDirectory ? -1 : row.size)">\(row.isDirectory ? "" : Int64(row.size).formatted(sizeStyle))</td>\
                <td data-value="\(Int(row.modified?.timeIntervalSince1970 ?? 0))">\(row.modified?.formatted(dateStyle) ?? "")</td></tr>

                """
        }
        return body
    }

    /// The page of the folder at `url`, its table empty until `rows(of:)` fills it.
    static func page(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let title = ViewSourceSchemeHandler.escape(String(format: "Index of %@".localized, path.hasSuffix("/") ? path : path + "/"))
        let parent = path == "/" ? "" : "<p><a href=\"../\"><svg aria-hidden=\"true\"><use href=\"#up\"/></svg>\("Parent folder".localized)</a></p>"
        return """
            <!DOCTYPE html>
            <html lang="\(Localization.locale)"><head><meta charset="utf-8">
            <meta name="color-scheme" content="light dark">
            <meta name="viewport" content="width=device-width">
            <title>\(title)</title>
            <style>
            :root { --text: #1d1d1f; --secondary: #6e6e73; --link: #0066cc; --separator: #d2d2d7; --hover: #f5f5f7; background: #fff; }
            @media (prefers-color-scheme: dark) {
              :root { --text: #f5f5f7; --secondary: #a1a1a6; --link: #4da3ff; --separator: #424245; --hover: #2c2c2e; background: #1e1e1e; }
            }
            body { margin: 32px 40px; font: 13px -apple-system, system-ui, sans-serif; color: var(--text); }
            h1 { margin: 0 0 16px; font-size: 22px; font-weight: 600; overflow-wrap: anywhere; }
            a { color: var(--link); text-decoration: none; display: inline-flex; align-items: center; gap: 6px; }
            a:hover { text-decoration: underline; }
            svg { width: 16px; height: 16px; flex: none; fill: none; stroke: var(--secondary); stroke-width: 1.3; stroke-linejoin: round; }
            table { border-collapse: collapse; width: 100%; }
            th { text-align: start; border-bottom: 1px solid var(--separator); padding: 0; }
            th button { all: unset; display: block; padding: 6px 8px; color: var(--secondary); font-weight: 500; cursor: default; }
            th button:focus-visible { outline: 2px solid var(--link); outline-offset: -2px; border-radius: 4px; }
            th[aria-sort] button { color: var(--text); }
            th[aria-sort=ascending] button::after { content: " \\25B4"; }
            th[aria-sort=descending] button::after { content: " \\25BE"; }
            td { padding: 4px 8px; white-space: nowrap; color: var(--secondary); font-variant-numeric: tabular-nums; }
            td:first-child { white-space: normal; overflow-wrap: anywhere; width: 100%; }
            th:nth-child(2), td:nth-child(2) { text-align: end; }
            tr:hover td { background: var(--hover); }
            </style></head><body>
            <svg style="display: none"><symbol id="folder" viewBox="0 0 16 16"><path d="M1.5 3.5h4.5l1.5 1.5h7v8h-13z"/></symbol>\
            <symbol id="file" viewBox="0 0 16 16"><path d="M3.5 1.5h6l3 3v10h-9z M9.5 1.5v3h3"/></symbol>\
            <symbol id="up" viewBox="0 0 16 16"><path d="M8 13V3 M4 7l4-4 4 4"/></symbol></svg>
            <h1>\(title)</h1>
            \(parent)
            <table><thead><tr><th aria-sort="ascending"><button>\("Name".localized)</button></th>\
            <th><button>\("Size".localized)</button></th><th><button>\("Date Modified".localized)</button></th></tr></thead>
            <tbody></tbody></table>
            <script>
            const headers = document.querySelectorAll("th");
            const collator = new Intl.Collator(undefined, { numeric: true });
            headers.forEach((header, column) => header.firstChild.addEventListener("click", () => {
              const order = header.getAttribute("aria-sort") === "ascending" ? -1 : 1;
              headers.forEach((other) => other.removeAttribute("aria-sort"));
              header.setAttribute("aria-sort", order > 0 ? "ascending" : "descending");
              const value = (row) => row.cells[column].dataset.value;
              const compare = column ? (a, b) => value(a) - value(b) : (a, b) => collator.compare(value(a), value(b));
              const body = document.querySelector("tbody");
              body.append(...[...body.rows].sort((a, b) => b.dataset.dir - a.dataset.dir || order * compare(a, b)));
            }));
            </script>
            </body></html>
            """
    }
}
