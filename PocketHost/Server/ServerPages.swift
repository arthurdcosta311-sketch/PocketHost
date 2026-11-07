//
//  ServerPages.swift
//  PocketHost
//
//  The HTML the server generates itself: folder listings and error pages.
//

import Foundation

enum ServerPages {
    struct ListingEntry {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
    }

    // MARK: - Listing

    static func listingHTML(path: String, entries: [ListingEntry]) -> String {
        let rows = entries.map { entry -> String in
            let href = encode(entry.name) + (entry.isDirectory ? "/" : "")
            let icon = entry.isDirectory ? "▸" : "·"
            let meta = entry.isDirectory ? "folder" : sizeText(entry.size)
            return """
            <li><a href="\(href)"><span class="icon">\(icon)</span><span class="name">\(escape(entry.name))\(entry.isDirectory ? "/" : "")</span><span class="meta">\(meta)</span></a></li>
            """
        }

        let parentRow = path == "/" ? "" : """
        <li><a href="../"><span class="icon">↑</span><span class="name">Parent folder</span><span class="meta"></span></a></li>
        """

        let count = entries.count
        let subtitle = count == 1 ? "1 entry" : "\(count) entries"

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <meta name="theme-color" content="#060b13" />
        <title>Index of \(escape(path))</title>
        <style>
          :root {
            --bg: #060b13;
            --ink: #e8eef7;
            --muted: #8fa2b8;
            --line: rgba(255,255,255,0.08);
            --accent: #2fd6e8;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            min-height: 100vh;
            background: var(--bg);
            color: var(--ink);
            font: 400 16px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            -webkit-font-smoothing: antialiased;
            padding: max(28px, env(safe-area-inset-top)) 20px max(36px, env(safe-area-inset-bottom));
          }
          main { max-width: 640px; margin: 0 auto; }
          .kicker { font-size: 11px; letter-spacing: .14em; text-transform: uppercase; color: var(--accent); font-weight: 700; }
          h1 { font-size: 26px; letter-spacing: -0.02em; margin: 8px 0 4px; font-weight: 700; }
          h1 code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 20px; color: var(--ink); }
          .lede { margin: 0 0 22px; color: var(--muted); font-size: 14px; }
          ul { list-style: none; margin: 0; padding: 0; border: 1px solid var(--line); border-radius: 18px; overflow: hidden; background: rgba(255,255,255,0.03); }
          li + li { border-top: 1px solid var(--line); }
          a { display: flex; align-items: center; gap: 12px; padding: 13px 16px; color: inherit; text-decoration: none; }
          a:active { background: rgba(255,255,255,0.06); }
          .icon { width: 14px; color: var(--accent); font-family: ui-monospace, Menlo, monospace; }
          .name { flex: 1; font-size: 15px; word-break: break-word; }
          .meta { color: var(--muted); font-size: 12px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; white-space: nowrap; }
          footer { margin-top: 22px; color: #6f829a; font-size: 12px; }
        </style>
        </head>
        <body>
        <main>
          <div class="kicker">PocketHost</div>
          <h1>Index of <code>\(escape(path))</code></h1>
          <p class="lede">\(subtitle) · served from this device</p>
          <ul>
            \(parentRow)
            \(rows.joined(separator: "\n    "))
          </ul>
          <footer>Served by PocketHost over HTTP/1.1</footer>
        </main>
        </body>
        </html>
        """
    }

    // MARK: - Error page

    static func messageHTML(statusCode: Int, title: String, detail: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
        <title>\(statusCode) · \(escape(title))</title>
        <style>
          :root { --bg: #060b13; --ink: #e8eef7; --muted: #8fa2b8; --accent: #f6b73c; }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; background: var(--bg); color: var(--ink);
            font: 400 16px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
            display: flex; align-items: center; justify-content: center;
            padding: max(28px, env(safe-area-inset-top)) 22px max(28px, env(safe-area-inset-bottom));
          }
          main { max-width: 480px; }
          .code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; letter-spacing: .12em; color: var(--accent); font-weight: 700; }
          h1 { font-size: 30px; letter-spacing: -0.02em; margin: 10px 0 10px; font-weight: 700; }
          p { color: var(--muted); margin: 0 0 20px; font-size: 15px; }
          a { display: inline-block; padding: 10px 16px; border-radius: 12px; border: 1px solid rgba(255,255,255,0.14); color: var(--ink); text-decoration: none; font-size: 14px; }
          a:active { background: rgba(255,255,255,0.08); }
          footer { margin-top: 26px; color: #6f829a; font-size: 12px; }
        </style>
        </head>
        <body>
        <main>
          <div class="code">HTTP \(statusCode)</div>
          <h1>\(escape(title))</h1>
          <p>\(escape(detail))</p>
          <a href="/">Back to the site root</a>
          <footer>Served by PocketHost</footer>
        </main>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    static func encode(_ component: String) -> String {
        WebPath.encode(component)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
