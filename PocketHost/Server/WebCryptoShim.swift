//
//  WebCryptoShim.swift
//  PocketHost
//
//  A browser only exposes `crypto.subtle` in a secure context, which plain HTTP
//  over the network is not. Every page PocketHost serves therefore gets this
//  small script first: where the real Web Crypto is missing it fills in
//  `crypto.subtle` (and `crypto.randomUUID`) and forwards each call to the
//  phone's own crypto endpoint. Where the real one exists it does nothing.
//

import Foundation

enum WebCryptoShim {
    static let scriptPath = "/.pockethost/webcrypto.js"

    /// Bumped whenever the script below changes, so a browser that cached an
    /// older copy asks for the new one instead of running the old one.
    static let version = 2

    static var scriptURL: String { "\(scriptPath)?v=\(version)" }

    /// Adds the script to a document, as early as it can run.
    static func injected(into html: String) -> String {
        guard !html.contains(scriptPath) else { return html }

        let block = "<script src=\"\(scriptURL)\"></script>\n    "

        // Inside the head, before anything the page itself loads.
        if let start = html.range(of: "<head", options: [.caseInsensitive]),
           let close = html.range(of: ">", range: start.upperBound..<html.endIndex) {
            return html.replacingCharacters(in: close.upperBound..<close.upperBound, with: block)
        }

        if let end = html.range(of: "</head>", options: [.caseInsensitive]) {
            return html.replacingCharacters(in: end.lowerBound..<end.lowerBound, with: block)
        }

        // No head at all: put it straight after the html element, or at the
        // very top when there is not even that.
        if let htmlTag = html.range(of: "<html", options: [.caseInsensitive]),
           let close = html.range(of: ">", range: htmlTag.upperBound..<html.endIndex) {
            return html.replacingCharacters(in: close.upperBound..<close.upperBound, with: block)
        }

        return block + html
    }

    static func response(forHead: Bool, cacheControl: String, cors: Bool) -> HTTPResponse {
        let data = Data(script.utf8)

        var headers: [String: String] = [
            "Content-Type": "application/javascript; charset=utf-8",
            "Cache-Control": cacheControl,
            "Content-Length": String(data.count)
        ]
        if cors { headers["Access-Control-Allow-Origin"] = "*" }

        return HTTPResponse(
            status: .ok,
            headers: headers,
            body: forHead ? .empty : .data(data)
        )
    }

    // MARK: - Script

    static let script = #"""
(function () {
  'use strict';

  var root = typeof window !== 'undefined' ? window : self;
  var crypto = root.crypto;

  if (!crypto) {
    return;
  }

  if (crypto.subtle && typeof crypto.subtle.digest === 'function') {
    root.PocketHostCrypto = { shim: false, native: true };
    return;
  }

  function getRandomValues(array) {
    if (crypto && typeof crypto.getRandomValues === 'function') {
      return crypto.getRandomValues(array);
    }
    var limit = Math.pow(2, 32);
    for (var i = 0; i < array.length; i++) {
      array[i] = Math.floor(Math.random() * limit) >>> 0;
    }
    return array;
  }

  function randomUUID() {
    var bytes = getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    var hex = [];
    for (var i = 0; i < 16; i++) {
      hex.push((bytes[i] + 0x100).toString(16).substring(1));
    }
    return hex.slice(0, 4).join('') + '-' + hex.slice(4, 6).join('') + '-' +
      hex.slice(6, 8).join('') + '-' + hex.slice(8, 10).join('') + '-' +
      hex.slice(10, 16).join('');
  }

  function bytesOf(value) {
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) {
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    }
    throw new TypeError('Expected an ArrayBuffer or a typed array');
  }

  function toBase64(bytes) {
    var binary = '';
    var chunk = 8192;
    for (var i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return root.btoa(binary);
  }

  function fromBase64(text) {
    var binary = root.atob(text);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return bytes;
  }

  function hashName(algorithm) {
    var raw = typeof algorithm === 'string' ? algorithm : (algorithm && algorithm.name);
    var name = String(raw || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (name === 'SHA1') return 'SHA-1';
    if (name === 'SHA256') return 'SHA-256';
    if (name === 'SHA384') return 'SHA-384';
    if (name === 'SHA512') return 'SHA-512';
    return null;
  }

  function algorithmName(algorithm) {
    return String((algorithm && algorithm.name) || algorithm || '').toUpperCase();
  }

  var endpoint = '/.pockethost/crypto';

  function send(method, url, body) {
    var options = { method: method, cache: 'no-store' };
    if (body !== null && body !== undefined) {
      options.headers = { 'Content-Type': 'application/json' };
      options.body = body;
    }
    return root.fetch(url, options);
  }

  function decodeResponse(response) {
    if (!response.ok) {
      var failure = new Error('PocketHost crypto answered ' + response.status);
      failure.pocketHostStatus = true;
      throw failure;
    }
    return response.json().then(function (json) {
      if (!json.ok) {
        var cryptoFailure = new Error(json.error || 'Crypto operation failed');
        cryptoFailure.pocketHostCrypto = true;
        throw cryptoFailure;
      }
      var bytes = fromBase64(json.data);
      return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    });
  }

  function encodePayload(text) {
    try {
      return toBase64(new TextEncoder().encode(text))
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=+$/, '');
    } catch (error) {
      return null;
    }
  }

  function call(payload) {
    var body = JSON.stringify(payload);

    return send('POST', endpoint, body).then(decodeResponse).catch(function (error) {
      if (error && error.pocketHostCrypto) {
        throw error;
      }

      // A POST can be blocked by something between the page and the server.
      // The same request goes through as a GET with the payload in the query.
      var encoded = encodePayload(body);
      if (!encoded || encoded.length > 8000) {
        throw error;
      }

      return send('GET', endpoint + '?p=' + encoded, null).then(decodeResponse).catch(function () {
        throw error;
      });
    }).catch(function (error) {
      var message = (error && error.message) || String(error);
      if (error && (error.pocketHostCrypto || error.pocketHostStatus)) {
        throw error;
      }
      throw new Error('PocketHost crypto request failed: ' + message);
    });
  }

  function makeKey(kind, algorithm, usages, raw) {
    return {
      type: 'secret',
      extractable: true,
      algorithm: algorithm,
      usages: usages || [],
      _kind: kind,
      _raw: raw
    };
  }

  function rawOf(key) {
    if (!key || !key._raw) {
      throw new TypeError('Unsupported key');
    }
    return key._raw;
  }

  var subtle = {
    digest: function (algorithm, data) {
      var hash = hashName(algorithm);
      if (!hash) return Promise.reject(new Error('Unsupported hash ' + algorithm));
      return call({ op: 'digest', alg: hash, data: toBase64(bytesOf(data)) });
    },

    importKey: function (format, keyData, algorithm, extractable, usages) {
      try {
        if (format !== 'raw') {
          throw new Error('The PocketHost shim only imports raw keys');
        }
        var name = algorithmName(algorithm);
        var raw = bytesOf(keyData);

        if (name === 'HMAC') {
          var hash = hashName(algorithm.hash) || 'SHA-256';
          return Promise.resolve(makeKey('hmac', { name: 'HMAC', hash: { name: hash } }, usages, raw));
        }

        if (name === 'AES-GCM' || name === 'AES-CBC') {
          if ([16, 24, 32].indexOf(raw.length) < 0) {
            throw new Error('AES keys are 16, 24 or 32 bytes');
          }
          return Promise.resolve(makeKey('aes', { name: name, length: raw.length * 8 }, usages, raw));
        }

        if (name === 'PBKDF2' || name === 'HKDF') {
          return Promise.resolve(makeKey('secret', { name: name }, usages, raw));
        }

        throw new Error('Unsupported key algorithm ' + name);
      } catch (error) {
        return Promise.reject(error);
      }
    },

    exportKey: function (format, key) {
      try {
        if (format !== 'raw') {
          throw new Error('The PocketHost shim only exports raw keys');
        }
        var raw = rawOf(key);
        return Promise.resolve(raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength));
      } catch (error) {
        return Promise.reject(error);
      }
    },

    generateKey: function (algorithm, extractable, usages) {
      try {
        var name = algorithmName(algorithm);
        var length = Math.round((algorithm.length || 256) / 8);

        if ([16, 24, 32].indexOf(length) < 0) {
          throw new Error('Unsupported key length');
        }

        var raw = getRandomValues(new Uint8Array(length));

        if (name === 'HMAC') {
          var hash = hashName(algorithm.hash) || 'SHA-256';
          return Promise.resolve(makeKey('hmac', { name: 'HMAC', hash: { name: hash } }, usages, raw));
        }

        if (name === 'AES-GCM' || name === 'AES-CBC') {
          return Promise.resolve(makeKey('aes', { name: name, length: length * 8 }, usages, raw));
        }

        throw new Error('Unsupported key algorithm ' + name);
      } catch (error) {
        return Promise.reject(error);
      }
    },

    sign: function (algorithm, key, data) {
      try {
        if (algorithmName(algorithm) !== 'HMAC') {
          throw new Error('The PocketHost shim only signs with HMAC');
        }
        var hash = hashName(key.algorithm && key.algorithm.hash) || 'SHA-256';
        return call({
          op: 'hmac',
          hash: hash,
          key: toBase64(rawOf(key)),
          data: toBase64(bytesOf(data))
        });
      } catch (error) {
        return Promise.reject(error);
      }
    },

    verify: function (algorithm, key, signature, data) {
      return subtle.sign(algorithm, key, data).then(function (buffer) {
        var expected = new Uint8Array(buffer);
        var actual = bytesOf(signature);
        if (expected.length !== actual.length) return false;
        var difference = 0;
        for (var i = 0; i < expected.length; i++) {
          difference |= expected[i] ^ actual[i];
        }
        return difference === 0;
      });
    },

    encrypt: function (algorithm, key, data) {
      try {
        if (algorithmName(algorithm) !== 'AES-GCM') {
          throw new Error('The PocketHost shim only encrypts with AES-GCM');
        }
        return call({
          op: 'aesgcm-encrypt',
          key: toBase64(rawOf(key)),
          iv: toBase64(bytesOf(algorithm.iv)),
          aad: algorithm.additionalData ? toBase64(bytesOf(algorithm.additionalData)) : null,
          data: toBase64(bytesOf(data))
        });
      } catch (error) {
        return Promise.reject(error);
      }
    },

    decrypt: function (algorithm, key, data) {
      try {
        if (algorithmName(algorithm) !== 'AES-GCM') {
          throw new Error('The PocketHost shim only decrypts AES-GCM');
        }
        return call({
          op: 'aesgcm-decrypt',
          key: toBase64(rawOf(key)),
          iv: toBase64(bytesOf(algorithm.iv)),
          aad: algorithm.additionalData ? toBase64(bytesOf(algorithm.additionalData)) : null,
          data: toBase64(bytesOf(data))
        });
      } catch (error) {
        return Promise.reject(error);
      }
    },

    deriveBits: function (algorithm, baseKey, length) {
      try {
        var name = algorithmName(algorithm);
        if (name !== 'PBKDF2' && name !== 'HKDF') {
          throw new Error('The PocketHost shim only derives with PBKDF2 or HKDF');
        }
        var bits = (length === null || length === undefined) ? 256 : length;
        return call({
          op: name.toLowerCase(),
          hash: hashName(algorithm.hash) || 'SHA-256',
          key: toBase64(rawOf(baseKey)),
          salt: algorithm.salt ? toBase64(bytesOf(algorithm.salt)) : null,
          info: algorithm.info ? toBase64(bytesOf(algorithm.info)) : null,
          iterations: algorithm.iterations || 0,
          length: Math.ceil(bits / 8)
        });
      } catch (error) {
        return Promise.reject(error);
      }
    },

    deriveKey: function (algorithm, baseKey, derivedKeyType, extractable, usages) {
      return subtle.deriveBits(algorithm, baseKey, derivedKeyType.length || 256).then(function (bits) {
        return subtle.importKey('raw', bits, derivedKeyType, extractable, usages);
      });
    },

    wrapKey: function () {
      return Promise.reject(new Error('wrapKey is not available through the PocketHost shim'));
    },

    unwrapKey: function () {
      return Promise.reject(new Error('unwrapKey is not available through the PocketHost shim'));
    }
  };

  // Filling in the property is not always the same as defining it on the object:
  // WebKit exposes `subtle` on the Crypto prototype, and a browser may hand out
  // a fresh Crypto wrapper. Each step is checked, and the next only runs when
  // the previous one did not take.
  function define(target, name, value) {
    try {
      Object.defineProperty(target, name, { value: value, configurable: true, writable: true });
      return target[name] === value;
    } catch (error) {
      try { target[name] = value; } catch (ignored) {}
      return target[name] === value;
    }
  }

  function installSubtle() {
    if (crypto.subtle && typeof crypto.subtle.digest === 'function') return true;
    if (define(crypto, 'subtle', subtle)) return true;

    var proto = null;
    try { proto = Object.getPrototypeOf(crypto); } catch (error) {}
    if (proto && define(proto, 'subtle', subtle)) return true;
    if (crypto.subtle === subtle) return true;

    var replacement = null;
    try { replacement = Object.create(crypto); } catch (error) { replacement = null; }
    if (!replacement) replacement = {};
    define(replacement, 'subtle', subtle);
    define(replacement, 'getRandomValues', function (array) { return getRandomValues(array); });
    define(replacement, 'randomUUID', randomUUID);

    if (define(root, 'crypto', replacement)) return true;

    return !!(root.crypto && root.crypto.subtle === subtle);
  }

  var installed = installSubtle();

  if (root.crypto && typeof root.crypto.randomUUID !== 'function') {
    define(root.crypto, 'randomUUID', randomUUID);
  }

  try {
    root.PocketHostCrypto = {
      shim: true,
      native: false,
      installed: !!installed,
      endpoint: '/.pockethost/crypto'
    };
  } catch (ignored) {}
})();
"""#
}
