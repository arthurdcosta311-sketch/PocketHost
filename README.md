# PocketHost

[![Build & Release](https://github.com/arthurdcosta311-sketch/PocketHost/actions/workflows/build.yml/badge.svg)](https://github.com/arthurdcosta311-sketch/PocketHost/actions/workflows/build.yml)

A web server in your pocket. PocketHost serves a folder of files over HTTP from
the iPhone itself, at `localhost` for the device and over Wi-Fi for everything
else on the network — and it ships with a full browser to look at the result.

## What it does

- **HTTP/1.1 server** built on Network.framework, bound to every interface.
  `GET` and `HEAD`, `index.html` resolution, folder listings, `301` redirects for
  folders without a trailing slash, `206` byte-range responses so video and audio
  seek properly, and a 40-entry live request log.
- **Any file type**: HTML, CSS, JavaScript, modules, JSON, WebAssembly, images,
  fonts, SVG, video, audio, PDF and more, with a MIME table in `MIMEType.swift`.
  Source, config and container files count too — `.json`, `.js`, `.ts`, `.css`,
  `.yml`, `.toml`, `.rs`, `.go`, `.tf`, `Dockerfile` and the rest are served with
  sensible types and open in the editor even when they carry no extension.
  Folders are just folders, whatever they are called (`assets`, `css`, `js`,
  `json` are all fine), and the new-file menu makes a page, stylesheet, script or
  JSON file from a fitting template.
- **Streaming sources**: HLS playlists and segments (`.m3u8`, `.ts`, `.m2ts`),
  DASH (`.mpd`, `.m4s`), fMP4, fragmented audio, subtitles, `.flv`, `.wmv`,
  `.wma` and the rest are served with their real content types, so a player
  recognises them. Byte ranges let it seek, and streaming manifests are always
  revalidated instead of cached for a minute. Pages that stream are scanned for
  `<source>`, `<track>`, `<img>` and poster URLs as well as scripts and styles.
- **API-friendly**: a folder answers as JSON when the request asks for it —
  `?format=json` or `Accept: application/json` — with each entry's name, path,
  size and modified date. Cross-origin preflights (`OPTIONS`) are answered for
  every path, and `Content-Range`, `Accept-Ranges`, `ETag` and `Content-Length`
  are exposed to cross-origin scripts, so a player or an API client can range
  request any file and read what came back.
- **Built-in site APIs**: `/api/health` reports server capabilities;
  `/api/proxy` fetches public HTTP(S) streams with range and referer passthrough,
  HLS playlist rewriting and SRT-to-WebVTT conversion; `/api/anilibria` resolves
  episodes to HLS. `/api/provider` remains an explicit `503` until a compatible
  provider resolver is available.
- **Embedded Node.js**: run a Node project from the hosted `www` folder on the
  iPhone. PocketHost provides Node.js Mobile 18.20.4; its iOS V8 build has JIT
  disabled, and iOS still controls memory, background execution and process APIs.
- **A real browser engine**: WKWebView renders the hosted pages with
  JIT-compiled JavaScript, WebGL 2 on the GPU, WebAssembly, Web Workers and
  OffscreenCanvas. Its layer is set up for extended dynamic range, and served
  pages are told `dynamic-range-limit: no-limit`, so high dynamic range images and
  video are not tone-mapped down to SDR before they reach the screen.
- **Full-screen pages**: one tap hides the browser's own controls, the tab bar and
  the status bar, so a game or a video fills the screen; a small floating button
  brings the chrome back.
- **Files tab**: browse the hosted folder, import files or whole folders from the
  Files app, create files and folders, and edit text-based files in place. A
  `.zip` dropped in is unpacked into a folder named after it, so a site can be
  imported in one go. Assets — images, audio, video, PDFs, fonts, models — open
  in a Quick Look preview instead of the editor.
- **Shareable address**: the app shows the LAN URL and a QR code so another phone
  or a laptop can open the same site.
- **Reachable from anywhere**: asks the router for a TCP port mapping (NAT-PMP,
  then UPnP IGD) and falls back to the device's own global IPv6 address, then
  shows the internet-facing URL with a QR code. The mapping is renewed while the
  server runs and removed when it stops.
- **Published copy**: when no router will open a port, one button copies the
  hosted folder to GitHub and turns GitHub Pages on, so the site gets a permanent
  `https` address that works from anywhere without any network setup. Choose the
  account's own `username.github.io` site, which serves at the root of the
  address, or a named repository. `WebPublisher` does it over the GitHub REST API.
- **Your sites, listed**: Settings reads every repository of the account that has
  GitHub Pages on. View opens one in the browser; Edit downloads its files into
  the hosted folder so you can change them here and publish them back.
- **Each account makes its own token**: the token is created on GitHub with the
  repo scope and kept in this phone's keychain, so nothing is shared between
  people using the app.
- **Bonjour**: advertises itself as an `_http._tcp` service on the network.
- **Web Crypto everywhere**: plain HTTP is not a secure context, so a shim gives
  every page a working `crypto.subtle` backed by the phone's own CryptoKit.
- **Never blocks the page**: if the chosen port is already taken the server walks
  up to the next free one, and the browser finishes a load on its own as soon as
  the listener is up instead of leaving a dead page behind.

## Where the files live

`Documents/www`, which is also visible in the Files app
(*On My iPhone › PocketHost › www*) because file sharing is enabled. Three sample
pages are seeded on first launch: a landing page, a WebGL shader demo, and a
capability lab that measures JIT throughput, WebAssembly, workers and viewport.

## Node.js projects

Add a `server.js` file to `Documents/www` (or enter another relative script path
in the Node.js card on the Server tab), then tap **Run**. PocketHost starts the
script inside its embedded Node.js runtime and sets `process.env.PORT` to an
available port; use that value in your server's `listen` call. A `package.json`
main entry is also accepted. Include any required `node_modules` in the project
folder; PocketHost does not run `npm install` on the phone.

The runtime is Node.js Mobile 18.20.4 and is a single embedded engine per app
process. Its iOS V8 build starts with JIT disabled; `child_process` process
spawning and `process.exit()` are not supported, and iOS can pause background work
or terminate the app under resource pressure. Stopping a project asks its servers
and timers to close, but does not stop the embedded engine itself.

## Background hosting

iOS suspends a backgrounded app within seconds, which would drop every request.
PocketHost stays out of that suspended state with **low-power background location
updates** (the coarsest accuracy, 500 m movement filter, "While Using" permission)
plus a rolling background-task lease that is renewed every time a request is
served. No location is ever stored, used for anything, or sent anywhere — it
exists only to keep the listener alive.

Hosting therefore keeps answering with the screen off, until you tap **Stop
server** or iOS ends the app. The whole thing is switchable in Settings →
Background, along with whether the screen itself stays awake while hosting.

## Releases

Every push builds an unsigned IPA on GitHub Actions and refreshes a rolling
**latest** release. Numbered releases are cut by pushing a `v*` tag or by
including a `[release vX.Y.Z]` marker in a commit message on `main`.

## Where the runtimes live

Nothing a page needs is kept on the phone. When a document is served,
`RuntimeScanner` works out what it pulls in — classic scripts, ES modules and
the modules they import, stylesheets and the fonts and images those reference,
`.wasm` binaries and worker scripts — and `CacheHints` adds a
`<link rel="preload">` (or `modulepreload`) for each one to the page's `<head>`.
The **connected device** downloads those files straight away, in parallel with
the page, and keeps them in its own HTTP cache.

The serving policy follows the same rule. Pages go out with
`Cache-Control: no-cache` plus `ETag` and `Last-Modified`, so an edit shows up
on the next load (as a `304 Not Modified` when nothing changed). Every other
file goes out with `public, max-age=60, stale-while-revalidate=86400`: the
client stores it, reuses it without asking for a minute, and after that shows its
own copy instantly while it revalidates in the background. The Server tab shows
how much the connected devices have kept. Turning **Cache files on connected
devices** off in Settings sends `no-store` for everything instead.

Files are streamed in chunks, so a multi-gigabyte one costs no more memory than a
small one: PocketHost puts **no ceiling** on what it serves, and nothing is
refused for its size. The Server tab reports the app's own memory footprint as a
readout.

Each connection gets its own queue, so a slow client or a long response does not
hold up other clients.

## Web Crypto

Browsers only expose `crypto.subtle` in a secure context, and PocketHost serves
plain HTTP over the network, so pages used to find it missing. Every HTML page is
now sent with a small shim script first (`/.pockethost/webcrypto.js`). Where the
browser already has real Web Crypto the script returns immediately; where it does
not, it fills in `crypto.subtle` and `crypto.randomUUID` and forwards each call to
`/.pockethost/crypto`, which does the work on the phone with CryptoKit: digests
(SHA-1, SHA-256, SHA-384, SHA-512), HMAC sign and verify, AES-GCM encrypt and
decrypt, and PBKDF2 and HKDF derivation. Key bytes only travel to this phone's own
server, and the results come back as the same `ArrayBuffer`s the real API returns.
A call goes out as a `POST`; if something between the page and the server blocks
one, the same request is retried as a `GET` with the payload in the query.

The capability lab in the seeded site runs a real SHA-256 through it and compares
the digest of the empty string with its known value, so a break in the chain shows
up as a failing row instead of silence.

The **on-device runner** exercises the site on the phone itself: every 15 seconds,
when no other machine has asked for anything recently, it GETs the entry page and
up to three same-origin links it finds there. Those runs are tagged, counted
separately and kept out of the shared request log, so the runtime stays warm
without a connected device driving it. It only ever issues GETs for documents and
assets — it never synthesises taps, keystrokes, controls or key maps, so anything
interactive still needs a real client.

## Limits worth knowing

- If location permission is denied, the server still runs while the app is on
  screen, and iOS may pause it shortly after you switch away.
- The address that reaches the internet comes from the router. It needs a router
  that speaks NAT-PMP or UPnP, or a device with a globally routable IPv6 address.
  A provider that puts the router behind its own NAT cannot be opened from inside,
  and PocketHost says so on the Server tab instead of pretending.
- **Publish to the web** is the way round that: it publishes a static copy to
  GitHub Pages, so it needs a GitHub token with the repo scope, only static files
  travel, and a published site is a snapshot until you publish again.

## Layout

    PocketHost/
      Server/       HTTP parsing, responses, MIME types, folder listings, network info
      Models/       File store, hosting store, browser model, sample site
      Views/        Server, Files, editor, browser and settings screens
