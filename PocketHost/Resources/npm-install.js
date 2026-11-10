'use strict';

/**
 * PocketHost dependency installer.
 *
 * A registry client that runs inside the embedded Node.js engine: it reads
 * package.json, resolves the dependency graph (from package-lock.json when one
 * is there, from the registry otherwise), downloads the tarballs over HTTPS,
 * checks their integrity, unpacks them into node_modules and links the bins.
 *
 * Lifecycle scripts run in this process instead of a shell, because iOS does
 * not allow spawning processes: a script whose command is `node <file>` (or
 * `node -e`) is executed as it would be by npm, anything else is reported and
 * skipped. Native addons cannot be compiled on the phone and are reported the
 * same way.
 *
 * Exposed as `install(options)`; running the file directly installs into the
 * folder given as the first argument.
 */

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const zlib = require('zlib');

const DEFAULT_REGISTRY = 'https://registry.npmjs.org';
const USER_AGENT = 'PocketHost-npm-install';
const DOWNLOAD_CONCURRENCY = 6;
const PACKAGE_LIFECYCLE = ['preinstall', 'install', 'postinstall'];
const ROOT_LIFECYCLE = ['preinstall', 'install', 'postinstall', 'prepare'];
const STATE_DIRECTORY = path.join('node_modules', '.pockethost');
const STATE_FILE = path.join(STATE_DIRECTORY, 'state.json');

class InstallError extends Error {
  constructor(message) {
    super(message);
    this.name = 'InstallError';
  }
}

// MARK: - Semver

function parseVersion(text) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(
    String(text === undefined || text === null ? '' : text).trim()
  );
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    pre: match[4] ? match[4].split('.') : []
  };
}

function comparePre(a, b) {
  if (!a.length && !b.length) return 0;
  if (!a.length) return 1;
  if (!b.length) return -1;

  const length = Math.max(a.length, b.length);
  for (let index = 0; index < length; index += 1) {
    const left = a[index];
    const right = b[index];
    if (left === undefined) return -1;
    if (right === undefined) return 1;
    const leftNumeric = /^\d+$/.test(left);
    const rightNumeric = /^\d+$/.test(right);
    if (leftNumeric && rightNumeric) {
      if (Number(left) !== Number(right)) return Number(left) < Number(right) ? -1 : 1;
    } else if (leftNumeric) {
      return -1;
    } else if (rightNumeric) {
      return 1;
    } else if (left !== right) {
      return left < right ? -1 : 1;
    }
  }
  return 0;
}

function compareParsed(a, b) {
  if (a.major !== b.major) return a.major < b.major ? -1 : 1;
  if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
  if (a.patch !== b.patch) return a.patch < b.patch ? -1 : 1;
  return comparePre(a.pre, b.pre);
}

function compareVersions(a, b) {
  const left = parseVersion(a);
  const right = parseVersion(b);
  if (!left || !right) return 0;
  return compareParsed(left, right);
}

function comparator(op, major, minor, patch, pre) {
  return {
    op: op,
    version: {
      major: major,
      minor: minor === undefined || minor === null ? 0 : minor,
      patch: patch === undefined || patch === null ? 0 : patch,
      pre: pre || []
    }
  };
}

function parseComparatorToken(rawToken) {
  let token = String(rawToken).trim();
  if (!token) return [];

  let op = '=';
  const match = /^(\^|~|>=|<=|>|<|=)\s*(.*)$/.exec(token);
  if (match) {
    op = match[1];
    token = match[2].trim();
  }

  if (token === '' || token === '*' || token === 'x' || token === 'X') {
    if (op === '>' || op === '<') return [comparator('>=', 0, 0, 0)];
    return [];
  }

  const plus = token.indexOf('+');
  if (plus !== -1) token = token.slice(0, plus);

  const parts = token.split('.');
  const numbers = [];
  const pre = [];
  let sawPre = false;

  for (const part of parts) {
    if (sawPre) {
      pre.push(part);
      continue;
    }
    let value = part;
    const dash = value.indexOf('-');
    if (dash !== -1) {
      pre.push(value.slice(dash + 1));
      value = value.slice(0, dash);
      sawPre = true;
    }
    if (value === '' || value === 'x' || value === 'X' || value === '*') {
      numbers.push(null);
      continue;
    }
    const number = Number(value);
    if (!Number.isInteger(number) || number < 0) return null;
    numbers.push(number);
  }

  const major = numbers.length > 0 ? numbers[0] : null;
  const minor = numbers.length > 1 ? numbers[1] : null;
  const patch = numbers.length > 2 ? numbers[2] : null;

  if (op === '^') {
    if (major === null) return [];
    if (minor === null) return [comparator('>=', major, 0, 0), comparator('<', major + 1, 0, 0)];
    if (patch === null) {
      if (major === 0) return [comparator('>=', 0, minor, 0), comparator('<', 0, minor + 1, 0)];
      return [comparator('>=', major, minor, 0), comparator('<', major + 1, 0, 0)];
    }
    if (major > 0) return [comparator('>=', major, minor, patch, pre), comparator('<', major + 1, 0, 0)];
    if (minor > 0) return [comparator('>=', 0, minor, patch, pre), comparator('<', 0, minor + 1, 0)];
    return [comparator('>=', 0, 0, patch, pre), comparator('<', 0, 0, patch + 1)];
  }

  if (op === '~') {
    if (major === null) return [];
    if (minor === null) return [comparator('>=', major, 0, 0), comparator('<', major + 1, 0, 0)];
    return [comparator('>=', major, minor, patch === null ? 0 : patch, pre), comparator('<', major, minor + 1, 0)];
  }

  if (op === '=') {
    if (major === null) return [];
    if (minor === null) return [comparator('>=', major, 0, 0), comparator('<', major + 1, 0, 0)];
    if (patch === null) return [comparator('>=', major, minor, 0), comparator('<', major, minor + 1, 0)];
    return [comparator('=', major, minor, patch, pre)];
  }

  if (op === '>') {
    if (major === null) return [];
    if (minor === null) return [comparator('>=', major + 1, 0, 0)];
    if (patch === null) return [comparator('>=', major, minor + 1, 0)];
    return [comparator('>', major, minor, patch, pre)];
  }

  if (op === '>=') {
    if (major === null) return [comparator('>=', 0, 0, 0)];
    if (minor === null) return [comparator('>=', major, 0, 0)];
    if (patch === null) return [comparator('>=', major, minor, 0)];
    return [comparator('>=', major, minor, patch, pre)];
  }

  if (op === '<') {
    if (major === null) return [comparator('<', 0, 0, 0)];
    if (minor === null) return [comparator('<', major, 0, 0)];
    if (patch === null) return [comparator('<', major, minor, 0)];
    return [comparator('<', major, minor, patch, pre)];
  }

  if (op === '<=') {
    if (major === null) return [];
    if (minor === null) return [comparator('<', major + 1, 0, 0)];
    if (patch === null) return [comparator('<', major, minor + 1, 0)];
    return [comparator('<=', major, minor, patch, pre)];
  }

  return null;
}

function parseRange(range) {
  const text = String(range === undefined || range === null ? '' : range).trim();
  if (!text || text === '*' || text === 'x' || text === 'X' || text === 'latest') return [[]];

  const sets = [];
  for (const rawSet of text.split('||')) {
    let setText = rawSet.trim();
    if (!setText) continue;

    const hyphen = /^(\S+)\s+-\s+(\S+)$/.exec(setText);
    if (hyphen) {
      const low = parseComparatorToken('>=' + hyphen[1]);
      const high = parseComparatorToken('<=' + hyphen[2]);
      if (!low || !high) return null;
      sets.push(low.concat(high));
      continue;
    }

    setText = setText.replace(/(\^|~|>=|<=|>|<|=)\s+/g, '$1');
    const tokens = setText.split(/\s+/).filter(Boolean);
    let comparators = [];
    for (const token of tokens) {
      const parsed = parseComparatorToken(token);
      if (parsed === null) return null;
      comparators = comparators.concat(parsed);
    }
    sets.push(comparators);
  }

  return sets.length ? sets : [[]];
}

function matchesComparator(version, item) {
  const order = compareParsed(version, item.version);
  switch (item.op) {
    case '=': return order === 0;
    case '>': return order > 0;
    case '>=': return order >= 0;
    case '<': return order < 0;
    case '<=': return order <= 0;
    default: return false;
  }
}

function satisfies(versionText, range) {
  const version = parseVersion(versionText);
  if (!version) return false;
  const sets = parseRange(range);
  if (!sets) return false;

  return sets.some(set => {
    for (const item of set) {
      if (!matchesComparator(version, item)) return false;
    }
    if (version.pre.length) {
      return set.some(item =>
        item.version.pre.length > 0 &&
        item.version.major === version.major &&
        item.version.minor === version.minor &&
        item.version.patch === version.patch
      );
    }
    return true;
  });
}

// MARK: - HTTP

function requestBuffer(url, options) {
  const settings = options || {};
  const redirects = settings.redirects === undefined ? 5 : settings.redirects;

  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL(url);
    } catch (error) {
      reject(new InstallError('Invalid URL: ' + url));
      return;
    }

    const client = parsed.protocol === 'http:' ? http : https;
    const headers = Object.assign({
      'user-agent': USER_AGENT,
      'accept-encoding': 'gzip'
    }, settings.headers || {});

    const request = client.get(parsed, { headers: headers }, response => {
      const status = response.statusCode || 0;

      if ([301, 302, 303, 307, 308].indexOf(status) !== -1 && response.headers.location) {
        response.resume();
        if (redirects <= 0) {
          reject(new InstallError('Too many redirects for ' + url));
          return;
        }
        const next = new URL(response.headers.location, parsed).toString();
        requestBuffer(next, Object.assign({}, settings, { redirects: redirects - 1 })).then(resolve, reject);
        return;
      }

      const chunks = [];
      response.on('data', chunk => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => {
        let body = Buffer.concat(chunks);
        const encoding = String(response.headers['content-encoding'] || '').toLowerCase();
        try {
          if (encoding.indexOf('gzip') !== -1) body = zlib.gunzipSync(body);
          else if (encoding.indexOf('deflate') !== -1) body = zlib.inflateSync(body);
        } catch (error) {
          reject(new InstallError('Could not decompress ' + url + ': ' + error.message));
          return;
        }
        resolve({ status: status, headers: response.headers, body: body });
      });
    });

    request.setTimeout(120000, () => {
      request.destroy(new InstallError('Timed out downloading ' + url));
    });
    request.on('error', error => {
      reject(error instanceof InstallError ? error : new InstallError('Network error for ' + url + ': ' + error.message));
    });
  });
}

// MARK: - Integrity

function verifyIntegrity(buffer, integrity) {
  if (!integrity) return null;

  const tokens = String(integrity).trim().split(/\s+/).filter(Boolean);
  let checked = false;

  for (const token of tokens) {
    const dash = token.indexOf('-');
    if (dash === -1) continue;
    const algorithm = token.slice(0, dash);
    if (['sha512', 'sha384', 'sha256', 'sha1'].indexOf(algorithm) === -1) continue;
    checked = true;
    const expected = token.slice(dash + 1);
    const actual = crypto.createHash(algorithm).update(buffer).digest('base64');
    if (actual === expected) return algorithm;
  }

  return checked ? false : null;
}

// MARK: - Tar

function readString(buffer, start, length) {
  const end = Math.min(start + length, buffer.length);
  let text = '';
  for (let index = start; index < end; index += 1) {
    const byte = buffer[index];
    if (byte === 0) break;
    text += String.fromCharCode(byte);
  }
  return text;
}

function readPaxPath(data) {
  let offset = 0;
  let found = null;
  while (offset < data.length) {
    let space = offset;
    while (space < data.length && data[space] !== 32) space += 1;
    if (space >= data.length) break;
    const length = parseInt(data.subarray(offset, space).toString('utf8'), 10);
    if (!Number.isFinite(length) || length <= 0) break;
    const record = data.subarray(space + 1, offset + length - 1).toString('utf8');
    const equals = record.indexOf('=');
    if (equals !== -1) {
      const key = record.slice(0, equals);
      const value = record.slice(equals + 1);
      if (key === 'path') found = value;
    }
    offset += length;
  }
  return found;
}

function parseTar(buffer) {
  const entries = [];
  let offset = 0;
  let longName = null;
  let paxPath = null;

  while (offset + 512 <= buffer.length) {
    const header = buffer.subarray(offset, offset + 512);
    let empty = true;
    for (let index = 0; index < 512; index += 1) {
      if (header[index] !== 0) { empty = false; break; }
    }
    if (empty) break;

    const name = readString(header, 0, 100);
    const mode = parseInt(readString(header, 100, 8).trim() || '0', 8) || 0;
    const size = parseInt(readString(header, 124, 12).trim() || '0', 8) || 0;
    const flag = header[156] === 0 ? '0' : String.fromCharCode(header[156]);
    const prefix = readString(header, 345, 155);
    const linkName = readString(header, 157, 100);

    const dataStart = offset + 512;
    const data = buffer.subarray(dataStart, Math.min(dataStart + size, buffer.length));
    offset = dataStart + Math.ceil(size / 512) * 512;

    if (flag === 'x' || flag === 'X') {
      const path = readPaxPath(data);
      if (path) paxPath = path;
      continue;
    }
    if (flag === 'g') continue;
    if (flag === 'L') {
      longName = data.toString('utf8').replace(/\0[\s\S]*$/, '');
      continue;
    }

    const entryName = paxPath || longName || (prefix ? prefix + '/' + name : name);
    paxPath = null;
    longName = null;

    entries.push({
      name: entryName.replace(/\\/g, '/').replace(/\/+$/, ''),
      mode: mode,
      type: flag,
      linkName: linkName,
      data: data
    });
  }

  return entries;
}

function extractTarball(buffer, targetDirectory) {
  let archive = buffer;
  if (archive.length > 2 && archive[0] === 0x1f && archive[1] === 0x8b) {
    archive = zlib.gunzipSync(archive);
  }

  const entries = parseTar(archive);
  if (!entries.length) {
    throw new InstallError('The downloaded archive is not a readable tarball.');
  }

  const root = path.resolve(targetDirectory);
  let files = 0;
  let bytes = 0;
  const pendingLinks = [];

  for (const entry of entries) {
    const segments = entry.name.split('/').filter(segment => segment.length && segment !== '.');
    if (segments.length <= 1) continue; // drop the leading "package/" folder
    const relative = segments.slice(1).join('/');
    if (!relative || relative.indexOf('..') !== -1) continue;

    const destination = path.resolve(root, relative);
    if (destination !== root && destination.indexOf(root + path.sep) !== 0) continue;

    if (entry.type === '5') {
      fs.mkdirSync(destination, { recursive: true });
      continue;
    }

    if (entry.type === '2' || entry.type === '1') {
      pendingLinks.push({ type: entry.type, destination: destination, target: entry.linkName });
      continue;
    }
    if (entry.type !== '0' && entry.type !== '') continue;

    fs.mkdirSync(path.dirname(destination), { recursive: true });
    const mode = entry.mode & 0o777;
    fs.writeFileSync(destination, entry.data, { mode: mode === 0 ? 0o644 : mode });
    files += 1;
    bytes += entry.data.length;
  }

  for (const link of pendingLinks) {
    try {
      fs.mkdirSync(path.dirname(link.destination), { recursive: true });
      if (link.type === '2') {
        fs.symlinkSync(link.target, link.destination);
      } else {
        const source = path.resolve(path.dirname(link.destination), link.target);
        if (source.indexOf(root + path.sep) === 0 && fs.existsSync(source)) {
          fs.copyFileSync(source, link.destination);
        }
      }
    } catch (error) {
      // A tarball with a link the phone will not take is not fatal.
    }
  }

  return { files: files, bytes: bytes };
}

// MARK: - Lockfile

function normaliseLockPath(key) {
  return String(key).replace(/\\/g, '/').replace(/^\.\//, '').replace(/\/+$/, '');
}

function nameFromPackagePath(lockPath) {
  const marker = '/node_modules/';
  const index = lockPath.lastIndexOf('node_modules/');
  if (index === -1) return null;
  return lockPath.slice(index + 'node_modules/'.length);
}

function entriesFromModernLock(packages) {
  const result = new Map();
  for (const key of Object.keys(packages)) {
    const lockPath = normaliseLockPath(key);
    if (!lockPath) continue;
    if (lockPath.indexOf('node_modules/') !== 0) continue;

    const raw = packages[key] || {};
    if (typeof raw !== 'object') continue;

    result.set(lockPath, {
      path: lockPath,
      name: raw.name || nameFromPackagePath(lockPath),
      version: raw.version,
      resolved: raw.resolved,
      integrity: raw.integrity,
      dev: raw.dev === true,
      optional: raw.optional === true,
      link: raw.link === true,
      hasInstallScript: raw.hasInstallScript === true,
      dependencies: raw.dependencies || {},
      optionalDependencies: raw.optionalDependencies || {},
      peerDependencies: raw.peerDependencies || {},
      os: raw.os,
      cpu: raw.cpu,
      bin: raw.bin
    });
  }
  return result;
}

function entriesFromLegacyLock(dependencies, parentPath, result) {
  for (const name of Object.keys(dependencies || {})) {
    const raw = dependencies[name] || {};
    if (typeof raw !== 'object') continue;
    const lockPath = parentPath ? parentPath + '/node_modules/' + name : 'node_modules/' + name;
    result.set(lockPath, {
      path: lockPath,
      name: name,
      version: raw.version,
      resolved: raw.resolved,
      integrity: raw.integrity,
      dev: raw.dev === true,
      optional: raw.optional === true,
      link: false,
      hasInstallScript: raw.requires === undefined ? false : false,
      dependencies: raw.requires || {},
      optionalDependencies: {},
      peerDependencies: {},
      os: undefined,
      cpu: undefined,
      bin: undefined,
      legacy: true
    });
    entriesFromLegacyLock(raw.dependencies, lockPath, result);
  }
  return result;
}

function resolutionDirectories(fromPath) {
  const directories = [];
  let directory = fromPath || '';
  while (true) {
    directories.push(directory);
    if (!directory) break;
    const index = directory.lastIndexOf('/');
    directory = index === -1 ? '' : directory.slice(0, index);
  }
  return directories;
}

function joinModulePath(directory, name) {
  return (directory ? directory + '/' : '') + 'node_modules/' + name;
}

function resolveLockedPath(packages, fromPath, name) {
  for (const directory of resolutionDirectories(fromPath)) {
    const candidate = joinModulePath(directory, name);
    if (packages.has(candidate)) return candidate;
  }
  return null;
}

function selectLockedPackages(packages, manifest, includeDev) {
  const selected = new Map();
  const queue = [];

  const pushAll = (from, dependencies, optional) => {
    for (const name of Object.keys(dependencies || {})) {
      queue.push({ from: from, name: name, optional: optional === true });
    }
  };

  pushAll('', manifest.dependencies, false);
  pushAll('', manifest.optionalDependencies, true);
  if (includeDev) pushAll('', manifest.devDependencies, false);

  while (queue.length) {
    const item = queue.shift();
    const lockPath = resolveLockedPath(packages, item.from, item.name);
    if (!lockPath) continue;
    if (selected.has(lockPath)) continue;

    const entry = packages.get(lockPath);
    selected.set(lockPath, entry);

    pushAll(lockPath, entry.dependencies, false);
    pushAll(lockPath, entry.optionalDependencies, true);
    pushAll(lockPath, entry.peerDependencies, true);
  }

  return selected;
}

// MARK: - Registry resolution

function packumentURL(registry, name) {
  if (name.charAt(0) === '@') {
    return registry + '/' + name.replace('/', '%2f');
  }
  return registry + '/' + encodeURIComponent(name);
}

function pickVersion(document, name, range) {
  const tags = document['dist-tags'] || {};
  if (tags[range]) return tags[range];

  const versions = Object.keys(document.versions || {}).filter(version => parseVersion(version));
  const matching = versions.filter(version => satisfies(version, range));

  if (!matching.length) {
    throw new InstallError('No published version of ' + name + ' matches "' + range + '".');
  }

  matching.sort(compareVersions);
  return matching[matching.length - 1];
}

function listAllows(list, value) {
  if (!Array.isArray(list) || list.length === 0) return true;
  const entries = list.filter(item => typeof item === 'string');
  if (!entries.length) return true;
  if (entries.indexOf('!' + value) !== -1) return false;
  const allowed = entries.filter(item => item.charAt(0) !== '!');
  if (!allowed.length) return true;
  return allowed.indexOf(value) !== -1 || allowed.indexOf('any') !== -1 || allowed.indexOf('*') !== -1;
}

function platformAllows(entry) {
  return listAllows(entry.os, process.platform) && listAllows(entry.cpu, process.arch);
}

function tarballURLFor(registry, name, version) {
  const unscoped = name.charAt(0) === '@' ? name.slice(name.indexOf('/') + 1) : name;
  return registry + '/' + (name.charAt(0) === '@' ? name.replace('/', '%2f') : encodeURIComponent(name)) + '/-/' + unscoped + '-' + version + '.tgz';
}

async function resolveFromRegistry(context) {
  const packages = new Map();
  const documents = new Map();
  const queue = [];
  let fetched = 0;

  const enqueue = (from, dependencies, optional) => {
    for (const name of Object.keys(dependencies || {})) {
      queue.push({ from: from, name: name, range: dependencies[name], optional: optional === true });
    }
  };

  const placedSatisfying = (from, name, range) => {
    for (const directory of resolutionDirectories(from)) {
      const candidate = joinModulePath(directory, name);
      const placed = packages.get(candidate);
      if (placed && satisfies(placed.version, range)) return candidate;
    }
    return null;
  };

  const placementFor = (from, name) => {
    const directories = resolutionDirectories(from).reverse();
    for (const directory of directories) {
      const candidate = joinModulePath(directory, name);
      if (!packages.has(candidate)) return candidate;
    }
    return joinModulePath(from, name);
  };

  const loadDocument = async name => {
    if (documents.has(name)) return documents.get(name);
    const response = await requestBuffer(packumentURL(context.registry, name), {
      headers: { accept: 'application/vnd.npm.install-v1+json' }
    });
    if (response.status === 404) throw new InstallError('The npm registry has no package "' + name + '".');
    if (response.status !== 200) throw new InstallError('The npm registry returned ' + response.status + ' for ' + name + '.');
    let document;
    try {
      document = JSON.parse(response.body.toString('utf8'));
    } catch (error) {
      throw new InstallError('The npm registry sent invalid JSON for ' + name + '.');
    }
    documents.set(name, document);
    return document;
  };

  enqueue('', context.manifest.dependencies, false);
  enqueue('', context.manifest.optionalDependencies, true);
  if (context.includeDev) enqueue('', context.manifest.devDependencies, false);

  while (queue.length) {
    const item = queue.shift();
    if (context.isCancelled()) throw new InstallError('Installation cancelled.');
    if (placedSatisfying(item.from, item.name, item.range)) continue;

    let document;
    try {
      document = await loadDocument(item.name);
    } catch (error) {
      if (item.optional) {
        context.warnings.push('Skipped optional ' + item.name + ': ' + error.message);
        continue;
      }
      throw error;
    }

    let version;
    try {
      version = pickVersion(document, item.name, item.range);
    } catch (error) {
      if (item.optional) {
        context.warnings.push('Skipped optional ' + item.name + ': ' + error.message);
        continue;
      }
      throw error;
    }

    const manifest = document.versions[version] || {};
    const entry = {
      path: placementFor(item.from, item.name),
      name: item.name,
      version: version,
      resolved: manifest.dist && manifest.dist.tarball ? manifest.dist.tarball : tarballURLFor(context.registry, item.name, version),
      integrity: manifest.dist ? manifest.dist.integrity : undefined,
      dependencies: manifest.dependencies || {},
      optionalDependencies: manifest.optionalDependencies || {},
      peerDependencies: manifest.peerDependencies || {},
      os: manifest.os,
      cpu: manifest.cpu,
      optional: item.optional,
      dev: false,
      deprecated: manifest.deprecated
    };

    if (manifest.repository && typeof manifest.repository === 'object' && manifest.repository.type === 'git') {
      // Nothing to do: tarball installs from the registry are fine.
    }

    if (!platformAllows(entry)) {
      if (item.optional) {
        context.platformSkips += 1;
        continue;
      }
      throw new InstallError(item.name + '@' + version + ' does not support ' + process.platform + '/' + process.arch + '.');
    }

    if (manifest.deprecated) {
      context.warnings.push(item.name + '@' + version + ' is deprecated: ' + String(manifest.deprecated));
    }

    packages.set(entry.path, entry);
    fetched += 1;
    context.log('[npm] Resolved ' + item.name + '@' + version + ' (' + fetched + ')');

    enqueue(entry.path, entry.dependencies, false);
    enqueue(entry.path, entry.optionalDependencies, true);
    enqueue(entry.path, entry.peerDependencies, true);
  }

  return packages;
}

// MARK: - Downloading

function toDiskPath(projectRoot, lockPath) {
  return path.join(projectRoot, lockPath.split('/').join(path.sep));
}

function cacheFileName(entry) {
  const seed = entry.integrity || entry.resolved || entry.path;
  return crypto.createHash('sha256').update(String(seed)).digest('hex') + '.tgz';
}

async function readCachedTarball(cacheDirectory, entry) {
  const file = path.join(cacheDirectory, cacheFileName(entry));
  let data;
  try {
    data = fs.readFileSync(file);
  } catch (error) {
    return null;
  }
  const verified = verifyIntegrity(data, entry.integrity);
  if (verified === false) {
    try { fs.unlinkSync(file); } catch (error) { /* ignore */ }
    return null;
  }
  return data;
}

function writeCachedTarball(cacheDirectory, entry, data) {
  try {
    fs.mkdirSync(cacheDirectory, { recursive: true });
    fs.writeFileSync(path.join(cacheDirectory, cacheFileName(entry)), data);
  } catch (error) {
    // A cache that cannot be written only costs a download next time.
  }
}

async function installEntry(context, entry) {
  if (entry.link) {
    context.warnings.push('Skipped ' + entry.path + ': linked dependencies cannot be installed on the phone.');
    return 0;
  }

  const resolved = entry.resolved ? String(entry.resolved) : '';
  if (resolved && !/^https?:\/\//i.test(resolved)) {
    const colon = resolved.indexOf(':');
    const scheme = colon === -1 ? 'unresolved' : resolved.slice(0, colon);
    context.warnings.push('Skipped ' + entry.name + ': PocketHost installs from the npm registry, not from ' + scheme + ' dependencies.');
    return 0;
  }

  const target = toDiskPath(context.projectRoot, entry.path);
  let tarball = await readCachedTarball(context.cacheDirectory, entry);
  let downloaded = 0;

  if (!tarball) {
    const url = resolved || tarballURLFor(context.registry, entry.name, entry.version);
    const response = await requestBuffer(url, { headers: { accept: 'application/octet-stream', 'accept-encoding': 'identity' } });
    if (response.status !== 200) {
      throw new InstallError('Could not download ' + entry.name + '@' + entry.version + ' (HTTP ' + response.status + ').');
    }
    tarball = response.body;
    downloaded = tarball.length;

    const verified = verifyIntegrity(tarball, entry.integrity);
    if (verified === false) {
      throw new InstallError('The download for ' + entry.name + '@' + entry.version + ' does not match its integrity checksum.');
    }
    writeCachedTarball(context.cacheDirectory, entry, tarball);
  }

  fs.rmSync(target, { recursive: true, force: true });
  fs.mkdirSync(target, { recursive: true });

  const result = extractTarball(tarball, target);
  context.files += result.files;

  if (fs.existsSync(path.join(target, 'binding.gyp'))) {
    context.warnings.push(entry.name + '@' + entry.version + ' contains a native addon (binding.gyp); it cannot be compiled on the phone.');
  }

  return downloaded;
}

async function installEntries(context, packages) {
  const queue = Array.from(packages.values());
  const total = queue.length;
  let completed = 0;
  let bytes = 0;
  let next = 0;

  const worker = async () => {
    while (next < queue.length) {
      if (context.isCancelled()) throw new InstallError('Installation cancelled.');
      const entry = queue[next];
      next += 1;
      try {
        bytes += await installEntry(context, entry);
      } catch (error) {
        if (entry.optional) {
          context.warnings.push('Skipped optional ' + entry.name + ': ' + error.message);
          continue;
        }
        throw error;
      }
      completed += 1;
      if (completed % 10 === 0 || completed === total) {
        context.log('[npm] Installed ' + completed + '/' + total + ' packages');
      }
    }
  };

  const workers = [];
  const count = Math.max(1, Math.min(DOWNLOAD_CONCURRENCY, total));
  for (let index = 0; index < count; index += 1) workers.push(worker());
  await Promise.all(workers);

  return { bytes: bytes, installed: total };
}

// MARK: - Lifecycle scripts

function tokenizeShell(command) {
  const tokens = [];
  let current = '';
  let quote = null;

  for (let index = 0; index < command.length; index += 1) {
    const character = command.charAt(index);
    if (quote) {
      if (character === quote) quote = null;
      else if (character === '\\' && quote === '"' && index + 1 < command.length) {
        index += 1;
        current += command.charAt(index);
      } else current += character;
    } else if (character === '"' || character === "'") {
      quote = character;
    } else if (/\s/.test(character)) {
      if (current) {
        tokens.push(current);
        current = '';
      }
    } else {
      current += character;
    }
  }
  if (current) tokens.push(current);
  return tokens;
}

function parseNodeCommand(command) {
  const text = String(command || '').trim();
  if (!text) return null;
  if (/[;&|]/.test(text)) return null;

  const tokens = tokenizeShell(text);
  if (!tokens.length) return null;

  let executable = path.basename(tokens[0]);
  if (executable === 'sh' || executable === 'bash' || executable === 'zsh') {
    const flagIndex = tokens.indexOf('-c');
    if (flagIndex === -1 || flagIndex + 1 >= tokens.length) return null;
    return parseNodeCommand(tokens.slice(flagIndex + 1).join(' '));
  }

  if (executable !== 'node' && executable !== 'nodejs') return null;

  const rest = tokens.slice(1);
  if (!rest.length) return null;
  if (rest[0] === '-e' || rest[0] === '--eval') {
    return { eval: rest.slice(1).join(' ') };
  }

  let index = 0;
  while (index < rest.length && rest[index].charAt(0) === '-') index += 1;
  if (index >= rest.length) return null;
  return { file: rest[index], args: rest.slice(index + 1) };
}

function runLifecycleCommand(invocation, directory, environment, timeoutMs) {
  const previousDirectory = process.cwd();
  const previousEnvironment = {};
  const previousArgv = process.argv;

  for (const key of Object.keys(environment)) {
    previousEnvironment[key] = process.env[key];
    process.env[key] = environment[key];
  }

  process.chdir(directory);
  process.argv = ['node', invocationsFile(invocation) || 'node'].concat(invocation.args || []);

  try {
    if (invocation.eval !== undefined) {
      const script = invocation.eval;
      // eslint-disable-next-line no-new-func
      const run = new Function('require', 'module', 'exports', '__filename', '__dirname', script);
      const module = { exports: {} };
      run(require, module, module.exports, path.join(directory, '<eval>'), directory);
    } else {
      const file = path.resolve(directory, invocation.file);
      if (!fs.existsSync(file)) throw new Error('Install script not found: ' + invocation.file);
      try { delete require.cache[require.resolve(file)]; } catch (error) { /* ignore */ }
      require(file);
    }
  } finally {
    process.argv = previousArgv;
    process.chdir(previousDirectory);
    for (const key of Object.keys(environment)) {
      if (previousEnvironment[key] === undefined) delete process.env[key];
      else process.env[key] = previousEnvironment[key];
    }
  }

  return new Promise(resolve => setTimeout(resolve, Math.min(timeoutMs || 0, 1000)));
}

function invocationsFile(invocation) {
  return invocation.file || null;
}

async function runLifecycleScripts(context, packages) {
  const ran = [];
  const skipped = [];

  const runFor = async (name, version, directory, scripts, lifecycle) => {
    for (const stage of lifecycle) {
      const command = scripts[stage];
      if (!command) continue;

      const invocation = parseNodeCommand(command);
      if (!invocation) {
        skipped.push({ package: name, stage: stage, command: command, reason: 'needs a shell or another program' });
        context.log('[npm] Skipped ' + stage + ' of ' + name + ': `' + command + '` (iOS cannot spawn processes)');
        continue;
      }

      context.log('[npm] Running ' + stage + ' of ' + name + '@' + version);
      try {
        await runLifecycleCommand(invocation, directory, {
          npm_package_name: name,
          npm_package_version: String(version || ''),
          npm_lifecycle_event: stage,
          npm_config_registry: context.registry,
          INIT_CWD: context.projectRoot
        }, 250);
        ran.push({ package: name, stage: stage });
      } catch (error) {
        skipped.push({ package: name, stage: stage, command: command, reason: error.message });
        context.warnings.push('The ' + stage + ' script of ' + name + ' failed: ' + error.message);
      }
    }
  };

  for (const entry of packages.values()) {
    const directory = toDiskPath(context.projectRoot, entry.path);
    let manifest;
    try {
      manifest = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
    } catch (error) {
      continue;
    }
    if (!manifest.scripts) continue;
    const hasLifecycle = PACKAGE_LIFECYCLE.some(stage => manifest.scripts[stage]);
    if (!hasLifecycle) continue;
    await runFor(manifest.name || entry.name, manifest.version || entry.version, directory, manifest.scripts, PACKAGE_LIFECYCLE);
  }

  if (context.manifest.scripts) {
    await runFor(context.manifest.name || 'project', context.manifest.version, context.projectRoot, context.manifest.scripts, ROOT_LIFECYCLE);
  }

  return { ran: ran, skipped: skipped };
}

// MARK: - Bins

function linkBins(projectRoot, packages, log) {
  const binDirectory = path.join(projectRoot, 'node_modules', '.bin');
  const linked = [];

  for (const entry of packages.values()) {
    const directory = toDiskPath(projectRoot, entry.path);
    let manifest;
    try {
      manifest = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
    } catch (error) {
      continue;
    }
    if (!manifest.bin) continue;

    const pairs = typeof manifest.bin === 'string'
      ? [[manifest.name, manifest.bin]]
      : Object.keys(manifest.bin).map(name => [name, manifest.bin[name]]);

    for (const pair of pairs) {
      const name = String(pair[0] || '').replace(/[\\/]/g, '__');
      const relative = String(pair[1] || '');
      if (!name || !relative) continue;

      const linkPath = path.join(binDirectory, name);
      if (fs.existsSync(linkPath)) continue;

      const targetPath = path.resolve(directory, relative);
      if (!fs.existsSync(targetPath)) continue;

      try {
        fs.mkdirSync(binDirectory, { recursive: true });
        fs.chmodSync(targetPath, 0o755);
        fs.symlinkSync(path.relative(binDirectory, targetPath), linkPath);
        linked.push(name);
      } catch (error) {
        log('[npm] Could not link ' + name + ': ' + error.message);
      }
    }
  }

  return linked;
}

// MARK: - Entry point

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (error) {
    return null;
  }
}

async function install(options) {
  const settings = options || {};
  const started = Date.now();
  const projectRoot = path.resolve(settings.projectRoot || process.cwd());
  const log = typeof settings.log === 'function' ? settings.log : () => {};
  const warnings = [];
  const isCancelled = typeof settings.isCancelled === 'function' ? settings.isCancelled : () => false;
  const registry = String(settings.registry || process.env.POCKETHOST_NPM_REGISTRY || DEFAULT_REGISTRY).replace(/\/+$/, '');
  const includeDev = settings.includeDev !== false;
  const force = settings.force === true;

  const packageFile = path.join(projectRoot, 'package.json');
  if (!fs.existsSync(packageFile)) {
    throw new InstallError('No package.json in this project.');
  }

  const manifest = readJSON(packageFile);
  if (!manifest || typeof manifest !== 'object') {
    throw new InstallError('package.json is not valid JSON.');
  }

  const lockFile = path.join(projectRoot, 'package-lock.json');
  const lockText = fs.existsSync(lockFile) ? fs.readFileSync(lockFile, 'utf8') : null;
  const fingerprint = crypto.createHash('sha256')
    .update(manifest === null ? '' : JSON.stringify(manifest))
    .update(lockText || '')
    .digest('hex');

  const modulesDirectory = path.join(projectRoot, 'node_modules');
  const stateFile = path.join(projectRoot, STATE_FILE);
  const cacheDirectory = settings.cacheDirectory
    ? path.resolve(settings.cacheDirectory)
    : path.join(projectRoot, STATE_DIRECTORY);

  if (!force) {
    const state = readJSON(stateFile);
    if (state && state.fingerprint === fingerprint && fs.existsSync(modulesDirectory)) {
      log('[npm] node_modules already matches package.json (' + (state.packages || 0) + ' packages).');
      return {
        status: 'up-to-date',
        packages: state.packages || 0,
        bytes: 0,
        durationMs: Date.now() - started,
        warnings: [],
        fromLock: state.fromLock === true
      };
    }
  }

  log('[npm] Installing dependencies into ' + projectRoot);

  const context = {
    projectRoot: projectRoot,
    registry: registry,
    cacheDirectory: cacheDirectory,
    includeDev: includeDev,
    manifest: manifest,
    warnings: warnings,
    log: log,
    isCancelled: isCancelled,
    files: 0,
    platformSkips: 0
  };

  let packages;
  let fromLock = false;

  if (lockText) {
    const lock = readJSON(lockFile);
    if (!lock) throw new InstallError('package-lock.json is not valid JSON.');

    let locked;
    if (lock.packages) {
      locked = entriesFromModernLock(lock.packages);
      locked = selectLockedPackages(locked, manifest, includeDev);
    } else if (lock.dependencies) {
      locked = entriesFromLegacyLock(lock.dependencies, '', new Map());
    } else {
      locked = new Map();
    }

    packages = locked;
    fromLock = true;
    log('[npm] Using package-lock.json (' + packages.size + ' packages).');
  } else {
    packages = await resolveFromRegistry(context);
  }

  const result = await installEntries(context, packages);
  const linked = linkBins(projectRoot, packages, log);
  const scripts = await runLifecycleScripts(context, packages);

  try {
    fs.mkdirSync(path.join(projectRoot, STATE_DIRECTORY), { recursive: true });
    fs.writeFileSync(stateFile, JSON.stringify({
      fingerprint: fingerprint,
      packages: packages.size,
      files: context.files,
      bins: linked.length,
      fromLock: fromLock,
      installedAt: new Date().toISOString()
    }, null, 2));
  } catch (error) {
    log('[npm] Could not record the install state: ' + error.message);
  }

  const durationMs = Date.now() - started;
  const megabytes = (result.bytes / (1024 * 1024)).toFixed(1);

  log('[npm] Added ' + packages.size + ' packages in ' + (durationMs / 1000).toFixed(1) + 's (' + megabytes + ' MB downloaded).');
  if (context.platformSkips) {
    log('[npm] Skipped ' + context.platformSkips + ' optional package' + (context.platformSkips === 1 ? '' : 's') + ' built for another platform.');
  }
  if (linked.length) log('[npm] Linked ' + linked.length + ' bin' + (linked.length === 1 ? '' : 's') + ' in node_modules/.bin.');
  for (const warning of warnings) log('[npm] ' + warning);

  return {
    status: 'installed',
    packages: packages.size,
    bytes: result.bytes,
    durationMs: durationMs,
    warnings: warnings,
    fromLock: fromLock,
    bins: linked.length,
    scripts: scripts
  };
}

module.exports = {
  install: install,
  // Exported for the tests that run this file outside the app.
  satisfies: satisfies,
  parseRange: parseRange,
  parseVersion: parseVersion,
  extractTarball: extractTarball,
  verifyIntegrity: verifyIntegrity
};

if (require.main === module) {
  const argumentsList = process.argv.slice(2).filter(argument => argument.charAt(0) !== '-');
  install({
    projectRoot: arguments[0] || process.cwd(),
    force: process.argv.indexOf('--force') !== -1,
    cacheDirectory: arguments[1] || undefined,
    log: text => console.log(text)
  }).then(result => {
    if (result.warnings.length) {
      for (const warning of result.warnings) console.log('[npm] ' + warning);
    }
    console.log('[npm] Done: ' + result.status);
  }).catch(error => {
    console.error('[npm] ' + (error && error.message ? error.message : error));
    process.exitCode = 1;
  });
}
