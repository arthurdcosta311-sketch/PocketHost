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
- **A real browser engine**: WKWebView renders the hosted pages with
  JIT-compiled JavaScript, WebGL 2 on the GPU, WebAssembly, Web Workers and
  OffscreenCanvas.
- **Files tab**: browse the hosted folder, import files or whole folders from the
  Files app, create files and folders, and edit text-based files in place.
- **Shareable address**: the app shows the LAN URL and a QR code so another phone
  or a laptop can open the same site.
- **Bonjour**: advertises itself as an `_http._tcp` service on the network.
- **Never blocks the page**: if the chosen port is already taken the server walks
  up to the next free one, and the browser finishes a load on its own as soon as
  the listener is up instead of leaving a dead page behind.

## Where the files live

`Documents/www`, which is also visible in the Files app
(*On My iPhone › PocketHost › www*) because file sharing is enabled. Three sample
pages are seeded on first launch: a landing page, a WebGL shader demo, and a
capability lab that measures JIT throughput, WebAssembly, workers and viewport.

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

Answers that would need more than **512 MB** are detected from their length and
reported against the app's live footprint on the Server tab. The file is streamed
either way, which is what keeps the app inside its budget; blocking one is opt-in
in Settings, not the default.

The **on-device runner** exercises the site on the phone itself: every 15 seconds,
when no other machine has asked for anything recently, it GETs the entry page and
up to three same-origin links it finds there. Those runs are tagged, counted
separately and kept out of the shared request log, so the runtime stays warm
without a connected device driving it. It only ever issues GETs for documents and
assets — it never synthesises taps, keystrokes, controls or key maps, so anything
interactive still needs a real client.

## Limits worth knowing

- Background hosting needs the Location background mode and location permission.
  App Store review may ask about it, since it is a background-location use.
- If location permission is denied, the server still runs while the app is on
  screen, and iOS may pause it shortly after you switch away.
- The server is reachable on the local network only. Serving to the public
  internet would need a tunnel or port forwarding on a router, which an app
  cannot set up by itself.

## Layout

    PocketHost/
      Server/       HTTP parsing, responses, MIME types, folder listings, network info
      Models/       File store, hosting store, browser model, sample site
      Views/        Server, Files, editor, browser and settings screens
