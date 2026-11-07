//
//  MIMEType.swift
//
//  PocketHost
//

import Foundation

enum MIMEType {
    static func type(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        let fileExtension = (path as NSString).pathExtension.lowercased()

        if !fileExtension.isEmpty, let type = types[fileExtension] {
            return type
        }

        // Files that are text without carrying an extension.
        switch name {
        case "dockerfile", "containerfile", "makefile", "gemfile", "procfile",
             "rakefile", "vagrantfile", "gemfile.lock", "brewfile", "justfile":
            return "text/plain; charset=utf-8"
        default:
            break
        }

        return "application/octet-stream"
    }

    static func type(forExtension pathExtension: String) -> String {
        let key = pathExtension.lowercased()
        return types[key] ?? "application/octet-stream"
    }

    static func isTextual(_ contentType: String) -> Bool {
        contentType.hasPrefix("text/")
            || contentType.contains("json")
            || contentType.contains("javascript")
            || contentType.contains("xml")
            || contentType.contains("svg")
            || contentType.contains("graphql")
    }

    /// Pairs, put into a dictionary with `uniquingKeysWith`: a repeated key in a
    /// dictionary literal traps at runtime, and this table gets edited a lot.
    private static let table: [(String, String)] = [
        ("html", "text/html; charset=utf-8"),
        ("htm", "text/html; charset=utf-8"),
        ("xhtml", "application/xhtml+xml; charset=utf-8"),
        ("css", "text/css; charset=utf-8"),
        ("scss", "text/x-scss; charset=utf-8"),
        ("sass", "text/x-sass; charset=utf-8"),
        ("less", "text/x-less; charset=utf-8"),
        ("styl", "text/stylus; charset=utf-8"),
        ("js", "text/javascript; charset=utf-8"),
        ("mjs", "text/javascript; charset=utf-8"),
        ("cjs", "text/javascript; charset=utf-8"),
        ("json", "application/json; charset=utf-8"),
        ("jsonc", "application/json; charset=utf-8"),
        ("json5", "application/json; charset=utf-8"),
        ("jsonl", "application/x-ndjson; charset=utf-8"),
        ("ndjson", "application/x-ndjson; charset=utf-8"),
        ("geojson", "application/geo+json; charset=utf-8"),
        ("map", "application/json; charset=utf-8"),
        ("webmanifest", "application/manifest+json; charset=utf-8"),
        ("txt", "text/plain; charset=utf-8"),
        ("md", "text/markdown; charset=utf-8"),
        ("markdown", "text/markdown; charset=utf-8"),
        ("csv", "text/csv; charset=utf-8"),
        ("tsv", "text/tab-separated-values; charset=utf-8"),
        ("xml", "application/xml; charset=utf-8"),
        ("yml", "text/yaml; charset=utf-8"),
        ("yaml", "text/yaml; charset=utf-8"),
        ("toml", "text/plain; charset=utf-8"),
        ("ini", "text/plain; charset=utf-8"),
        ("conf", "text/plain; charset=utf-8"),
        ("properties", "text/plain; charset=utf-8"),
        ("env", "text/plain; charset=utf-8"),
        ("lock", "text/plain; charset=utf-8"),
        ("log", "text/plain; charset=utf-8"),
        ("srt", "text/plain; charset=utf-8"),
        ("vtt", "text/vtt; charset=utf-8"),
        ("svg", "image/svg+xml"),
        ("png", "image/png"),
        ("apng", "image/apng"),
        ("jpg", "image/jpeg"),
        ("jpeg", "image/jpeg"),
        ("gif", "image/gif"),
        ("webp", "image/webp"),
        ("avif", "image/avif"),
        ("heic", "image/heic"),
        ("heif", "image/heif"),
        ("bmp", "image/bmp"),
        ("tiff", "image/tiff"),
        ("ico", "image/x-icon"),
        ("pdf", "application/pdf"),
        ("mp4", "video/mp4"),
        ("m4v", "video/x-m4v"),
        ("mov", "video/quicktime"),
        ("webm", "video/webm"),
        ("mkv", "video/x-matroska"),
        ("avi", "video/x-msvideo"),
        ("3gp", "video/3gpp"),
        ("ogv", "video/ogg"),
        ("mp3", "audio/mpeg"),
        ("m4a", "audio/mp4"),
        ("aac", "audio/aac"),
        ("wav", "audio/wav"),
        ("ogg", "audio/ogg"),
        ("oga", "audio/ogg"),
        ("opus", "audio/ogg"),
        ("flac", "audio/flac"),
        ("wasm", "application/wasm"),
        ("woff", "font/woff"),
        ("woff2", "font/woff2"),
        ("ttf", "font/ttf"),
        ("otf", "font/otf"),
        ("eot", "application/vnd.ms-fontobject"),
        ("zip", "application/zip"),
        ("gz", "application/gzip"),
        ("tar", "application/x-tar"),
        ("glb", "model/gltf-binary"),
        ("gltf", "model/gltf+json"),
        ("obj", "model/obj"),
        ("hdr", "image/vnd.radiance"),
        ("ktx2", "image/ktx2"),
        ("exr", "image/x-exr"),
        ("bin", "application/octet-stream"),
        ("ics", "text/calendar; charset=utf-8"),
        ("vcf", "text/vcard; charset=utf-8"),
        ("sql", "application/sql"),
        ("sh", "text/x-sh; charset=utf-8"),
        ("py", "text/x-python; charset=utf-8"),
        ("swift", "text/plain; charset=utf-8"),
        ("ts", "text/plain; charset=utf-8"),
        ("jsx", "text/plain; charset=utf-8"),
        ("tsx", "text/plain; charset=utf-8"),
        ("php", "text/plain; charset=utf-8"),
        ("glsl", "text/plain; charset=utf-8"),
        ("frag", "text/plain; charset=utf-8"),
        ("vert", "text/plain; charset=utf-8"),
        ("wgsl", "text/plain; charset=utf-8"),
        ("hlsl", "text/plain; charset=utf-8"),
        ("metal", "text/plain; charset=utf-8"),
        ("dockerfile", "text/plain; charset=utf-8"),
        ("containerfile", "text/plain; charset=utf-8"),
        ("gitignore", "text/plain; charset=utf-8"),
        ("gitattributes", "text/plain; charset=utf-8"),
        ("dockerignore", "text/plain; charset=utf-8"),
        ("editorconfig", "text/plain; charset=utf-8"),
        ("rs", "text/plain; charset=utf-8"),
        ("go", "text/plain; charset=utf-8"),
        ("java", "text/plain; charset=utf-8"),
        ("kt", "text/plain; charset=utf-8"),
        ("kts", "text/plain; charset=utf-8"),
        ("c", "text/plain; charset=utf-8"),
        ("h", "text/plain; charset=utf-8"),
        ("hpp", "text/plain; charset=utf-8"),
        ("cpp", "text/plain; charset=utf-8"),
        ("cs", "text/plain; charset=utf-8"),
        ("rb", "text/plain; charset=utf-8"),
        ("lua", "text/plain; charset=utf-8"),
        ("vue", "text/plain; charset=utf-8"),
        ("svelte", "text/plain; charset=utf-8"),
        ("astro", "text/plain; charset=utf-8"),
        ("graphql", "application/graphql; charset=utf-8"),
        ("gql", "application/graphql; charset=utf-8"),
        ("proto", "text/plain; charset=utf-8"),
        ("tf", "text/plain; charset=utf-8"),
        ("tfvars", "text/plain; charset=utf-8")
    ]

    private static let types: [String: String] = Dictionary(table, uniquingKeysWith: { first, _ in first })
}
