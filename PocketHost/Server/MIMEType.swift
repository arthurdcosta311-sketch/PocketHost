//
//  MIMEType.swift
//  PocketHost
//
//  Content types for everything the server is likely to hand out.
//

import Foundation

enum MIMEType {
    static func type(forExtension pathExtension: String) -> String {
        types[pathExtension.lowercased()] ?? "application/octet-stream"
    }

    static func isTextual(_ contentType: String) -> Bool {
        contentType.hasPrefix("text/")
            || contentType.contains("json")
            || contentType.contains("javascript")
            || contentType.contains("xml")
            || contentType.contains("svg")
    }

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "xhtml": "application/xhtml+xml; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "cjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "md": "text/markdown; charset=utf-8",
        "markdown": "text/markdown; charset=utf-8",
        "csv": "text/csv; charset=utf-8",
        "tsv": "text/tab-separated-values; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "yml": "text/yaml; charset=utf-8",
        "yaml": "text/yaml; charset=utf-8",
        "toml": "text/plain; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "heic": "image/heic",
        "heif": "image/heif",
        "bmp": "image/bmp",
        "tiff": "image/tiff",
        "ico": "image/x-icon",
        "pdf": "application/pdf",
        "mp4": "video/mp4",
        "m4v": "video/x-m4v",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "ogv": "video/ogg",
        "mp3": "audio/mpeg",
        "m4a": "audio/mp4",
        "aac": "audio/aac",
        "wav": "audio/wav",
        "ogg": "audio/ogg",
        "oga": "audio/ogg",
        "flac": "audio/flac",
        "wasm": "application/wasm",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "eot": "application/vnd.ms-fontobject",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "glb": "model/gltf-binary",
        "gltf": "model/gltf+json",
        "obj": "model/obj",
        "hdr": "image/vnd.radiance",
        "ktx2": "image/ktx2",
        "exr": "image/x-exr",
        "bin": "application/octet-stream",
        "ics": "text/calendar; charset=utf-8",
        "vcf": "text/vcard; charset=utf-8",
        "sql": "application/sql",
        "sh": "text/x-sh; charset=utf-8",
        "py": "text/x-python; charset=utf-8",
        "swift": "text/plain; charset=utf-8",
        "ts": "text/plain; charset=utf-8",
        "jsx": "text/plain; charset=utf-8",
        "tsx": "text/plain; charset=utf-8",
        "php": "text/plain; charset=utf-8",
        "glsl": "text/plain; charset=utf-8",
        "frag": "text/plain; charset=utf-8",
        "vert": "text/plain; charset=utf-8"
    ]
}
