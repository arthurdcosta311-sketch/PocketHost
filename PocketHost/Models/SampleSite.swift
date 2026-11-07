//
//  SampleSite.swift
//  PocketHost
//
//  The pages that are dropped into the hosted folder on first launch. They
//  double as proof that the browser engine really runs WebGL, WebAssembly and
//  JIT-compiled JavaScript.
//

import Foundation

enum SampleSite {
    static let pages: [(path: String, content: String)] = [
        ("index.html", indexHTML),
        ("webgl/index.html", webGLHTML),
        ("lab/index.html", labHTML)
    ]

    // MARK: - Landing page

    static let indexHTML = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="theme-color" content="#060b13" />
    <title>PocketHost · hosted from this device</title>
    <style>
      :root {
        --bg: #060b13;
        --ink: #e8eef7;
        --muted: #8fa2b8;
        --line: rgba(255,255,255,0.08);
        --card: rgba(255,255,255,0.045);
        --accent: #2fd6e8;
        --amber: #f6b73c;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0;
        min-height: 100vh;
        background: var(--bg);
        background-image: radial-gradient(120% 70% at 50% -10%, rgba(47,214,232,0.16), rgba(6,11,19,0) 60%);
        color: var(--ink);
        font: 400 16px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
        -webkit-font-smoothing: antialiased;
        padding: max(32px, env(safe-area-inset-top)) 22px max(40px, env(safe-area-inset-bottom));
        display: flex;
        justify-content: center;
      }
      main { width: 100%; max-width: 620px; }
      .badge {
        display: inline-flex; align-items: center; gap: 8px;
        padding: 7px 13px; border-radius: 999px;
        border: 1px solid var(--line); background: var(--card);
        color: var(--muted); font-size: 12px; font-weight: 600;
        letter-spacing: 0.06em; text-transform: uppercase;
      }
      .dot {
        width: 7px; height: 7px; border-radius: 50%;
        background: var(--accent); box-shadow: 0 0 12px var(--accent);
      }
      h1 {
        font-size: clamp(38px, 11vw, 56px); letter-spacing: -0.03em;
        line-height: 1; margin: 22px 0 14px; font-weight: 750;
      }
      h1 span { color: var(--accent); }
      .lede { color: var(--muted); font-size: 17px; margin: 0 0 30px; max-width: 46ch; }
      .grid { display: grid; gap: 14px; grid-template-columns: 1fr; }
      @media (min-width: 560px) { .grid { grid-template-columns: 1fr 1fr; } }
      a.card {
        display: block; text-decoration: none; color: inherit;
        padding: 18px 18px 20px; border-radius: 20px;
        border: 1px solid var(--line); background: var(--card);
        transition: transform .25s ease, border-color .25s ease, background .25s ease;
      }
      a.card:hover, a.card:focus-visible {
        transform: translateY(-2px);
        border-color: rgba(47,214,232,0.45);
        background: rgba(47,214,232,0.07);
        outline: none;
      }
      .kicker {
        font-size: 11px; letter-spacing: 0.14em; text-transform: uppercase;
        color: var(--amber); font-weight: 700;
      }
      .card h2 { margin: 8px 0 6px; font-size: 19px; letter-spacing: -0.01em; }
      .card p { margin: 0; color: var(--muted); font-size: 14.5px; }
      .panel {
        margin-top: 30px; padding: 8px 18px; border-radius: 20px;
        border: 1px solid var(--line); background: rgba(0,0,0,0.25);
      }
      .row {
        display: flex; justify-content: space-between; gap: 12px;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 12.5px; padding: 11px 0;
        border-bottom: 1px dashed rgba(255,255,255,0.07);
      }
      .row:last-child { border-bottom: 0; }
      .row span:first-child { color: var(--muted); }
      .row span:last-child { text-align: right; word-break: break-all; }
      footer { margin-top: 34px; color: #6f829a; font-size: 12.5px; }
    </style>
    </head>
    <body>
    <main>
      <div class="badge"><span class="dot"></span> Served from this device</div>
      <h1>Pocket<span>Host</span></h1>
      <p class="lede">This page came off a web server running in your pocket. It is plain HTML, CSS and
      JavaScript, delivered over HTTP to every device on the same network.</p>

      <div class="grid">
        <a class="card" href="/webgl/">
          <div class="kicker">GPU</div>
          <h2>WebGL demo</h2>
          <p>A full-screen fragment shader driven by JavaScript, running at display refresh rate.</p>
        </a>
        <a class="card" href="/lab/">
          <div class="kicker">Runtime</div>
          <h2>Capability lab</h2>
          <p>WebAssembly, workers, BigInt and a JIT benchmark, all measured live in this browser.</p>
        </a>
      </div>

      <div class="panel">
        <div class="row"><span>origin</span><span id="origin">…</span></div>
        <div class="row"><span>client</span><span id="client">…</span></div>
        <div class="row"><span>renderer</span><span id="gpu">…</span></div>
        <div class="row"><span>server</span><span>PocketHost · HTTP/1.1</span></div>
      </div>

      <footer>Drop your own files into the Files tab of the app and they appear right here.</footer>
    </main>
    <script>
      document.getElementById('origin').textContent = location.origin;
      document.getElementById('client').textContent =
        navigator.language + " · " + Math.round(window.devicePixelRatio * 100) / 100 + "x";
      (function () {
        var target = document.getElementById('gpu');
        try {
          var canvas = document.createElement('canvas');
          var gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
          if (!gl) { target.textContent = 'WebGL unavailable'; return; }
          var info = gl.getExtension('WEBGL_debug_renderer_info');
          var isGL2 = typeof WebGL2RenderingContext !== 'undefined' && gl instanceof WebGL2RenderingContext;
          var name = info ? gl.getParameter(info.UNMASKED_RENDERER_WEBGL) : '';
          target.textContent = (isGL2 ? 'WebGL 2 · ' : 'WebGL 1 · ') + (name || 'GPU');
        } catch (error) {
          target.textContent = String(error);
        }
      })();
    </script>
    </body>
    </html>
    """#

    // MARK: - WebGL

    static let webGLHTML = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="theme-color" content="#04070d" />
    <title>WebGL · PocketHost</title>
    <style>
      html, body { margin: 0; height: 100%; overflow: hidden; background: #04070d; }
      canvas { display: block; width: 100%; height: 100%; }
      .hud {
        position: fixed; inset: 0;
        padding: max(16px, env(safe-area-inset-top)) 16px max(16px, env(safe-area-inset-bottom));
        display: flex; flex-direction: column; gap: 10px; align-items: flex-start;
        pointer-events: none;
        font: 500 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
        color: #dbe6f2;
      }
      .panel {
        pointer-events: auto; padding: 10px 13px; border-radius: 14px;
        background: rgba(4,7,13,0.62); border: 1px solid rgba(255,255,255,0.12);
        backdrop-filter: blur(14px); -webkit-backdrop-filter: blur(14px);
        white-space: pre-line;
      }
      .back {
        margin-top: auto; pointer-events: auto; color: #9fb3c8;
        text-decoration: none; border: 1px solid rgba(255,255,255,0.12);
        padding: 9px 13px; border-radius: 12px; background: rgba(4,7,13,0.6);
      }
      .back:active { background: rgba(255,255,255,0.12); }
    </style>
    </head>
    <body>
    <canvas id="canvas"></canvas>
    <div class="home" style="display:none"></div>
    <div class="hud">
      <div class="panel" id="stats">starting WebGL…</div>
      <a class="back" href="/">‹ PocketHost</a>
    </div>
    <script>
    (function () {
      var canvas = document.getElementById('canvas');
      var stats = document.getElementById('stats');

      var gl = canvas.getContext('webgl2', { antialias: true, alpha: false, powerPreference: 'high-performance' })
        || canvas.getContext('webgl', { antialias: true, alpha: false });

      if (!gl) {
        stats.textContent = 'WebGL is not available in this browser.';
        return;
      }

      var isGL2 = typeof WebGL2RenderingContext !== 'undefined' && gl instanceof WebGL2RenderingContext;

      var vertexSource = [
        'attribute vec2 aPos;',
        'varying vec2 vUv;',
        'void main() {',
        '  vUv = aPos * 0.5 + 0.5;',
        '  gl_Position = vec4(aPos, 0.0, 1.0);',
        '}'
      ].join('\n');

      var fragmentSource = [
        'precision highp float;',
        'varying vec2 vUv;',
        'uniform vec2 uResolution;',
        'uniform float uTime;',
        'void main() {',
        '  vec2 p = vUv * 2.0 - 1.0;',
        '  p.x *= uResolution.x / uResolution.y;',
        '  float t = uTime * 0.55;',
        '  vec2 q = p;',
        '  float glow = 0.0;',
        '  for (int i = 0; i < 5; i++) {',
        '    float fi = float(i);',
        '    q += vec2(sin(q.y * 1.4 + t + fi), cos(q.x * 1.2 - t * 0.85 + fi)) * 0.42;',
        '    glow += 0.055 / max(0.045, length(fract(q * 0.5) - 0.5));',
        '  }',
        '  glow = clamp(glow * 0.32, 0.0, 1.0);',
        '  vec3 deep = vec3(0.016, 0.035, 0.07);',
        '  vec3 cyan = vec3(0.16, 0.82, 0.92);',
        '  vec3 col = mix(deep, cyan, glow);',
        '  col += vec3(0.96, 0.68, 0.22) * pow(glow, 7.0);',
        '  float vignette = 1.0 - smoothstep(0.35, 1.4, length(p));',
        '  col *= 0.55 + 0.45 * vignette;',
        '  gl_FragColor = vec4(col, 1.0);',
        '}'
      ].join('\n');

      function compile(type, source) {
        var shader = gl.createShader(type);
        gl.shaderSource(shader, source);
        gl.compileShader(shader);
        if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
          throw new Error(gl.getShaderInfoLog(shader) || 'shader error');
        }
        return shader;
      }

      var program;
      try {
        program = gl.createProgram();
        gl.attachShader(program, compile(gl.VERTEX_SHADER, vertexSource));
        gl.attachShader(program, compile(gl.FRAGMENT_SHADER, fragmentSource));
        gl.linkProgram(program);
        if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
          throw new Error(gl.getProgramInfoLog(program) || 'link error');
        }
      } catch (error) {
        stats.textContent = 'Shader failed:\n' + (error && error.message ? error.message : error);
        return;
      }

      gl.useProgram(program);

      var buffer = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);

      var aPos = gl.getAttribLocation(program, 'aPos');
      gl.enableVertexAttribArray(aPos);
      gl.vertexAttribPointer(aPos, 2, gl.FLOAT, false, 0, 0);

      var uResolution = gl.getUniformLocation(program, 'uResolution');
      var uTime = gl.getUniformLocation(program, 'uTime');
      var dpr = Math.min(window.devicePixelRatio || 1, 2);

      function resize() {
        var width = Math.max(1, Math.floor(canvas.clientWidth * dpr));
        var height = Math.max(1, Math.floor(canvas.clientHeight * dpr));
        if (canvas.width !== width || canvas.height !== height) {
          canvas.width = width;
          canvas.height = height;
        }
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.uniform2f(uResolution, canvas.width, canvas.height);
      }

      window.addEventListener('resize', resize);
      resize();

      var gpuName = 'unknown GPU';
      var info = gl.getExtension('WEBGL_debug_renderer_info');
      if (info) {
        try { gpuName = gl.getParameter(info.UNMASKED_RENDERER_WEBGL); } catch (error) { }
      }
      var maxTexture = gl.getParameter(gl.MAX_TEXTURE_SIZE);

      var frames = 0;
      var last = performance.now();
      var started = performance.now();

      function render(now) {
        gl.uniform1f(uTime, (now - started) / 1000.0);
        resize();
        gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

        frames++;
        if (now - last > 500) {
          var fps = Math.round(frames * 1000 / (now - last));
          frames = 0;
          last = now;
          stats.textContent =
            (isGL2 ? 'WebGL 2.0' : 'WebGL 1.0') + '  ·  ' + fps + ' fps\n' +
            'GPU: ' + gpuName + '\n' +
            'canvas: ' + canvas.width + '×' + canvas.height + '  ·  max texture ' + maxTexture + 'px';
        }
        requestAnimationFrame(render);
      }

      requestAnimationFrame(render);
    })();
    </script>
    </body>
    </html>
    """#

    // MARK: - Capability lab

    static let labHTML = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <meta name="theme-color" content="#060b13" />
    <title>Capability lab · PocketHost</title>
    <style>
      :root {
        --bg: #060b13; --ink: #e8eef7; --muted: #8fa2b8;
        --line: rgba(255,255,255,0.08); --accent: #2fd6e8;
        --ok: #4ade80; --bad: #f87171; --wait: #f6b73c;
      }
      * { box-sizing: border-box; }
      body {
        margin: 0; min-height: 100vh; background: var(--bg); color: var(--ink);
        font: 400 16px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
        -webkit-font-smoothing: antialiased;
        padding: max(28px, env(safe-area-inset-top)) 20px max(36px, env(safe-area-inset-bottom));
      }
      main { max-width: 620px; margin: 0 auto; }
      .back { color: var(--muted); text-decoration: none; font-size: 13px; }
      .kicker {
        margin-top: 16px; font-size: 11px; letter-spacing: 0.14em;
        text-transform: uppercase; color: var(--accent); font-weight: 700;
      }
      h1 { font-size: 30px; letter-spacing: -0.03em; margin: 8px 0 8px; font-weight: 750; }
      .lede { color: var(--muted); font-size: 15px; margin: 0 0 24px; }
      .card {
        border: 1px solid var(--line); border-radius: 18px;
        background: rgba(255,255,255,0.03); overflow: hidden;
      }
      .check {
        display: flex; align-items: center; gap: 12px; padding: 12px 16px;
        border-bottom: 1px solid var(--line);
      }
      .check:last-child { border-bottom: 0; }
      .status {
        width: 8px; height: 8px; border-radius: 50%;
        background: var(--wait); flex: 0 0 auto;
      }
      .status.ok { background: var(--ok); box-shadow: 0 0 10px rgba(74,222,128,0.5); }
      .status.bad { background: var(--bad); }
      .name { flex: 1; font-size: 14.5px; }
      .value {
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        font-size: 11.5px; color: var(--muted);
        text-align: right; max-width: 46%; word-break: break-word;
      }
      .actions { display: flex; gap: 10px; margin-top: 18px; }
      button {
        font: inherit; font-size: 14px; color: var(--ink);
        background: rgba(255,255,255,0.06);
        border: 1px solid rgba(255,255,255,0.14);
        padding: 9px 16px; border-radius: 12px;
      }
      button:active { background: rgba(255,255,255,0.14); }
      .ua {
        margin-top: 22px; color: #6f829a; font-size: 11.5px;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        word-break: break-word;
      }
    </style>
    </head>
    <body>
    <main>
      <a class="back" href="/">‹ PocketHost</a>
      <div class="kicker">Runtime</div>
      <h1>Capability lab</h1>
      <p class="lede">Everything below is measured in this exact browser, seconds after the page arrived over
      the network. If the numbers are here, the engine is running at full speed.</p>

      <section class="card" id="checks"></section>

      <div class="actions">
        <button id="rerun">Run again</button>
      </div>

      <p class="ua" id="ua"></p>
    </main>
    <script>
    (function () {
      var list = document.getElementById('checks');

      var checks = [
        {
          name: 'JavaScript JIT throughput',
          run: function () {
            var n = 4000000, x = 0, i;
            var start = performance.now();
            for (i = 0; i < n; i++) { x = (x + Math.imul(i, 2654435761)) % 1000003; }
            var ms = performance.now() - start;
            if (x === -1) { return 'impossible'; }
            return (n / ms / 1000).toFixed(1) + ' M ops/s';
          }
        },
        {
          name: 'WebGL 2',
          run: function () {
            return document.createElement('canvas').getContext('webgl2') ? 'available' : 'missing';
          }
        },
        {
          name: 'WebGL 1',
          run: function () {
            var canvas = document.createElement('canvas');
            var gl = canvas.getContext('webgl2') || canvas.getContext('webgl');
            if (!gl) { return 'missing'; }
            var info = gl.getExtension('WEBGL_debug_renderer_info');
            return info ? String(gl.getParameter(info.UNMASKED_RENDERER_WEBGL)) : 'available';
          }
        },
        {
          name: 'WebAssembly',
          run: function () {
            if (typeof WebAssembly !== 'object') { return 'missing'; }
            var bytes = new Uint8Array([
              0,97,115,109,1,0,0,0,1,5,1,96,0,1,127,3,2,1,0,
              7,8,1,4,102,117,110,99,0,0,10,6,1,4,0,65,42,11
            ]);
            var instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
            var answer = instance.exports.func();
            return answer === 42 ? 'instantiated · 42' : 'unexpected ' + answer;
          }
        },
        {
          name: 'Web Worker',
          run: function () {
            return new Promise(function (resolve) {
              if (typeof Worker === 'undefined') { resolve('missing'); return; }
              var source = 'self.onmessage = function (event) { self.postMessage(event.data * 2); };';
              var url = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }));
              var worker = new Worker(url);
              var settled = false;
              worker.onmessage = function (event) {
                settled = true;
                worker.terminate();
                URL.revokeObjectURL(url);
                resolve('round trip · ' + event.data);
              };
              worker.onerror = function () {
                if (!settled) { settled = true; worker.terminate(); resolve('failed to start'); }
              };
              worker.postMessage(21);
              setTimeout(function () {
                if (!settled) { settled = true; worker.terminate(); resolve('timed out'); }
              }, 2000);
            });
          }
        },
        {
          name: 'OffscreenCanvas',
          run: function () {
            return typeof OffscreenCanvas === 'undefined' ? 'missing' : 'available';
          }
        },
        {
          name: 'BigInt',
          run: function () {
            if (typeof BigInt !== 'function') { return 'missing'; }
            return String(BigInt('9007199254740993') * BigInt(2));
          }
        },
        {
          name: 'Intl.NumberFormat',
          run: function () {
            return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'EUR' }).format(1234.5);
          }
        },
        {
          name: 'CSS backdrop-filter',
          run: function () {
            var supported = (typeof CSS !== 'undefined') &&
              (CSS.supports('backdrop-filter', 'blur(4px)') || CSS.supports('-webkit-backdrop-filter', 'blur(4px)'));
            return supported ? 'supported' : 'missing';
          }
        },
        {
          name: 'ES module scripts',
          run: function () {
            return (typeof HTMLScriptElement !== 'undefined' && typeof HTMLScriptElement.supports === 'function' &&
              HTMLScriptElement.supports('module')) ? 'supported' : 'unknown';
          }
        },
        {
          name: 'Web Crypto',
          run: function () {
            return (typeof crypto !== 'undefined' && crypto.subtle) ? 'available' : 'missing';
          }
        },
        {
          name: 'fetch to this server',
          run: function () {
            if (typeof fetch !== 'function') { return Promise.resolve('missing'); }
            return fetch(location.origin + '/?probe=' + Date.now(), { cache: 'no-store' })
              .then(function (response) { return 'HTTP ' + response.status; })
              .catch(function (error) { return 'failed: ' + error.message; });
          }
        },
        {
          name: 'Hardware',
          run: function () {
            var threads = navigator.hardwareConcurrency || '?';
            var memory = navigator.deviceMemory ? navigator.deviceMemory + ' GB' : 'unknown memory';
            return threads + ' threads · ' + memory;
          }
        },
        {
          name: 'Viewport',
          run: function () {
            return window.innerWidth + '×' + window.innerHeight + ' @' +
              (Math.round((window.devicePixelRatio || 1) * 100) / 100) + 'x';
          }
        }
      ];

      function isGood(value) {
        return !/^(missing|failed|timed out|unexpected|unknown)/i.test(value);
      }

      function makeRow(name) {
        var row = document.createElement('div');
        row.className = 'check';
        var status = document.createElement('span');
        status.className = 'status';
        var label = document.createElement('span');
        label.className = 'name';
        label.textContent = name;
        var value = document.createElement('span');
        value.className = 'value';
        value.textContent = '…';
        row.appendChild(status);
        row.appendChild(label);
        row.appendChild(value);
        list.appendChild(row);
        return { status: status, value: value };
      }

      function settle(row, text) {
        var text_ = String(text);
        row.value.textContent = text_;
        row.status.className = 'status ' + (isGood(text_) ? 'ok' : 'bad');
      }

      checks.forEach(function (check) {
        var row = makeRow(check.name);
        try {
          var result = check.run();
          if (result && typeof result.then === 'function') {
            result.then(function (value) { settle(row, value); })
              .catch(function (error) { settle(row, 'failed: ' + (error && error.message ? error.message : error)); });
          } else {
            settle(row, result);
          }
        } catch (error) {
          settle(row, 'failed: ' + (error && error.message ? error.message : error));
        }
      });

      document.getElementById('rerun').addEventListener('click', function () {
        location.reload();
      });

      document.getElementById('ua').textContent = navigator.userAgent;
    })();
    </script>
    </body>
    </html>
    """#
}
