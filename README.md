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
