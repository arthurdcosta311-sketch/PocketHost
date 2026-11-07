# Changelog

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
