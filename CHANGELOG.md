# Changelog

## Unreleased

## 1.01

- Publish to a host that serves your own domain: Netlify and Cloudflare Pages
  take the hosted folder as a zip and, when a domain is entered, connect it to
  the new deployment. Both are free for static sites and keep the domain across
  redeploys.
- A domain check resolves the domain with the system resolver, follows its
  canonical name and asks it for a page, so the app can say whether the domain
  reaches the site yet; the DNS records to create at the registrar are listed
  with a copy button for each.
- Many more file types are served with their real content types and open in the
  editor: archives (`7z`, `rar`, `bz2`, `xz`, `zst`, `dmg`, `iso`, `jar`, `apk`),
  documents (`docx`, `xlsx`, `pptx`, `odt`, `epub`, `mobi`, `rtf`, `tex`),
  images (`jp2`, `jxl`, `psd`, `ai`, `svgz`, `dng`, camera raw), audio (`aiff`,
  `midi`, `mka`, `ape`, `wv`, `dsf`), video (`mpeg`, `vob`, `mxf`, `3g2`),
  3D (`fbx`, `dae`, `stl`, `ply`, `usdz`, `usd`), fonts, keys and certificates,
  scientific and data formats (`parquet`, `avro`, `sqlite`, `h5`, `nc`), and
  another two dozen programming languages and config formats.
- New files start from a fitting template for Markdown, SVG, YAML, Python, shell,
  SQL, XML, CSV, WebVTT, HLS playlists and more.
- The npm card can search the registry from the phone and add a package to
  `package.json`, installing it straight away.

## 0.9

- Node projects install their own dependencies on the phone. Tapping **Run** (or
  **Install dependencies**) reads `package.json`, resolves the graph — from
  `package-lock.json` v1, v2 or v3 when one is there, from the npm registry
  otherwise — downloads the tarballs over HTTPS, checks each one's
  `sha512`/`sha1` integrity, unpacks them into the npm layout with hoisting and
  nesting, links `node_modules/.bin`, and then starts the project. Downloads are
  kept in a content-addressed cache, and an unchanged `package.json` skips the
  install entirely.
- `preinstall`, `install`, `postinstall` and root `prepare` scripts run in
  process when the command is `node <file>` or `node -e`; anything that needs a
  shell, another program or a native addon is reported instead of silently
  skipped.
- Map a hosted project's `process.exit(code)` call to a graceful project-only stop,
  preserving PocketHost and its persistent Node.js engine.

## 0.8

- Restored the built-in site API routes: `/api/health`, `/api/proxy`,
  `/api/anilibria` and `/api/provider`, preserving their existing responses and
  cross-origin behavior.
- Added an embedded Node.js Mobile 18.20.4 runtime for running project entry files
  from the hosted folder. The iOS V8 build has JIT disabled and remains subject
  to iOS memory, background-execution and process-API restrictions.
- Every connection is served on its own queue, so a slow client or long response
  does not stall other requests.

## 0.7

- API surface: folders answer as JSON with `?format=json` or an
  `Accept: application/json` header, listing each entry's name, path, size and
  modified date. For API clients, not for browsers.
- Cross-origin requests work end to end: `OPTIONS` preflights are answered for
  every path with the methods and headers a client asks for, and every response
  — errors included — carries `Access-Control-Allow-Origin` plus an
  `Access-Control-Expose-Headers` list with `Content-Range`, `Accept-Ranges`,
  `ETag` and `Content-Length`, so a page can range request media and read the
  result.

- Streaming formats are served properly: HLS playlists and segments (`.m3u8`,
  `.ts`, `.m2ts`, `.mts`), DASH (`.mpd`, `.m4s`), fMP4 and fragmented audio,
  subtitle formats (`.vtt`, `.srt`, `.ass`, `.ssa`), and `.flv`, `.f4v`, `.wmv`,
  `.wma`, `.ac3`, `.eac3`, `.alac`, `.amr` all get their real content types.
- Live streaming manifests (`.m3u8`, `.mpd`) are revalidated on every request so
  a player never reads a stale playlist, while their segments keep normal caching.
- Pages are scanned for `<source>`, `<audio>`, `<track>`, `<img>` and `<video
  poster>` references too, so the runtimes report lists what a player streams.
- Playlists are editable in the app like any other text file.

## 0.6

- Fixed a crash: the MIME table had `.flac` twice, and a repeated key in a
  dictionary literal traps at runtime — which the server hit as soon as it
  served the first file after launch. The table is built from pairs with
  duplicates ignored, and the same list now covers CSS, JSON, JavaScript,
  config and source files.
- Content type is worked out from the whole file name, so `Dockerfile` and
  `Makefile` are served as text instead of a download.
- New-file menu offers a page, a stylesheet, a script or a JSON file, each
  starting from a fitting template, and creating `Dockerfile` or `Makefile` no
  longer renames it to `.html`.
- Folders named `assets`, `css`, `js`, `json` and `fonts` get their own icons,
  and folder navigation works the same whatever they are called.

- More kinds of file work throughout: JSON, JavaScript, TypeScript, stylesheet
  flavours, config files and source files are editable and served with proper
  content types, and files with no extension — `Dockerfile`, `Makefile`,
  `Gemfile` — open in the editor instead of falling through.
- New files start from a fitting template (`{}` for JSON, a comment header for
  CSS and JS, the page template for HTML) rather than always being an HTML page.
- Assets preview with Quick Look: tapping an image, audio or video file, PDF,
  font or model shows it instead of pushing it to the browser.

- Importing a `.zip` unpacks it into a folder named after the archive, with
  stored and deflated entries read straight from the container, a wrapping folder
  stripped, and `.`, `..` and `__MACOSX` entries skipped. Titles change to match
  the files it wrote.

- Settings lists the account's existing GitHub Pages sites. View opens one in the
  browser; Edit downloads its files into the hosted folder so they can be changed
  here and published back to the same repository.

## 0.5

- Publish to the web: copies the hosted folder to GitHub and turns GitHub Pages
  on, either at the account's own `username.github.io` site (served at the root)
  or in a named repository. Each account makes its own token, which is kept in
  the phone's keychain.
- The published site now lands at the repository root, keeps its stylesheet and
  script links working under a project path, points an already-enabled Pages site
  at the branch that was just published, adds `.nojekyll`, and reports a failed
  build instead of showing an address that serves nothing.

## 0.4

- Extended dynamic range: the browser's layer is set up for EDR rendering, the
  opaque SDR background is gone, and served pages carry
  `dynamic-range-limit: no-limit` so HDR images and video are not tone-mapped to
  SDR first.
- Internet hosting: NAT-PMP and UPnP-IGD port mapping with a global IPv6
  fallback, renewed while the server runs and removed when it stops.
- Fullscreen browsing: the address bar, controls, tab bar and status bar hide,
  with a floating button to bring them back.
- Web Crypto: a hardened shim, a revalidating ETag so cached pages cannot hide
  it, GET/OPTIONS support on the endpoint, and a real digest check in the lab.
- No memory ceiling: every file is streamed in chunks, whatever its size.

## 0.3

- Page runtimes are preloaded on the connected device, not held on the phone.
  Pages revalidate with `ETag`; assets are kept by the client for a minute and
  then revalidated in the background.
- Over-size answers are streamed instead of refused.

## 0.2

- Background hosting that keeps the listener alive with low-power location
  updates and a renewed background-task lease.

## 0.1

- HTTP/1.1 server on Network.framework, serving `Documents/www` at `localhost`
  and over the local network.
- WKWebView browser with JIT JavaScript, WebGL 2, WebAssembly and workers.
- Files tab with import, create, rename, delete and an in-place text editor.
- Bonjour advertising, LAN address and QR sharing.
