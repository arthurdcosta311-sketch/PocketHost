//
//  NodeRuntime.swift
//  PocketHost
//
//  Runs a hosted Node.js project through the embedded NodeMobile runtime.
//  NodeMobile supports one runtime per app process, so a small control server
//  stays alive while individual project entry points are started and stopped.
//

import Combine
import Darwin
import Foundation
import NodeMobile

struct NodeRuntimeLog: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

final class NodeRuntimeManager: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed

        var title: String {
            switch self {
            case .idle: return "Stopped"
            case .starting: return "Starting"
            case .running: return "Running"
            case .stopping: return "Stopping"
            case .failed: return "Error"
            }
        }
    }

    @Published private(set) var state: State = .idle {
        didSet {
            if Self.isActive(state) != Self.isActive(oldValue) {
                onActivityChange?(Self.isActive(state))
            }
        }
    }
    @Published private(set) var message: String?
    @Published private(set) var projectPort: Int?
    @Published private(set) var logs: [NodeRuntimeLog] = []
    @Published var entrypoint = UserDefaults.standard.string(forKey: "pockethost.node.entrypoint") ?? "server.js" {
        didSet { UserDefaults.standard.set(entrypoint, forKey: "pockethost.node.entrypoint") }
    }

    var onActivityChange: ((Bool) -> Void)?

    private var projectRoot: URL?
    private var runtimeDirectory: URL?
    private var readyFile: URL?
    private var runtimePort: Int?
    private var runtimeToken: String?
    private var runtimeReady = false
    private var engineHasStarted = false
    private var readinessTimer: Timer?
    private var logTimer: Timer?
    private var readinessAttempts = 0
    private var logSequence = 0
    private var isFetchingLogs = false

    var isActive: Bool { Self.isActive(state) }
    var isProjectRunning: Bool { state == .running }

    func start(projectRoot: URL, preferredPort: Int) {
        guard state != .starting, state != .running, state != .stopping else { return }

        let script = entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else {
            fail("Enter a JavaScript entry file inside www.")
            return
        }

        self.projectRoot = projectRoot.standardizedFileURL
        let firstNodePort = NetworkInfo.firstAvailablePort(startingAt: 3000)
        self.projectPort = firstNodePort == preferredPort
            ? NetworkInfo.firstAvailablePort(startingAt: min(firstNodePort + 1, 65535))
            : firstNodePort
        message = nil
        logs.removeAll()
        logSequence = 0
        state = .starting

        if runtimeReady {
            startProject(script: script)
        } else if engineHasStarted {
            fail("The embedded Node.js runtime stopped. Relaunch PocketHost before starting it again.")
        } else {
            launchEngine()
        }
    }

    func stop() {
        guard state == .running else { return }
        state = .stopping
        request(path: "/stop", method: "POST", payload: [:]) { [weak self] result in
            guard let self else { return }
            self.logTimer?.invalidate()
            self.logTimer = nil

            switch result {
            case .success(let response):
                self.message = response["message"] as? String ?? "Project stopped. The embedded runtime remains ready."
                self.state = .idle
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func launchEngine() {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let directory = support.appendingPathComponent("PocketHost/NodeRuntime", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let bootstrap = directory.appendingPathComponent("bootstrap.js")
            let readyFile = directory.appendingPathComponent("ready.json")
            try Self.bootstrap.write(to: bootstrap, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: readyFile)

            let token = UUID().uuidString
            runtimeDirectory = directory
            self.readyFile = readyFile
            runtimeToken = token
            engineHasStarted = true

            let arguments = ["node", bootstrap.path, projectRoot?.path ?? "", readyFile.path, token]
            let thread = Thread { [weak self] in
                let cArguments: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
                guard cArguments.allSatisfy({ $0 != nil }) else {
                    cArguments.forEach { if let pointer = $0 { free(pointer) } }
                    DispatchQueue.main.async { [weak self] in
                        self?.fail("The Node.js runtime could not prepare its launch arguments.")
                    }
                    return
                }

                let result = cArguments.withUnsafeBufferPointer { buffer -> Int32 in
                    guard let address = buffer.baseAddress else { return -1 }
                    return node_start(Int32(buffer.count), UnsafeMutablePointer(mutating: address))
                }
                cArguments.forEach { if let pointer = $0 { free(pointer) } }

                DispatchQueue.main.async { [weak self] in
                    self?.runtimeDidExit(result)
                }
            }
            thread.name = "com.pockethost.node-runtime"
            thread.stackSize = 2 * 1024 * 1024
            thread.start()
            waitForRuntimeReady()
        } catch {
            fail("Could not prepare the Node.js runtime: \(error.localizedDescription)")
        }
    }

    private func waitForRuntimeReady() {
        readinessAttempts = 0
        readinessTimer?.invalidate()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            self.readinessAttempts += 1
            if let readyFile = self.readyFile,
               let data = try? Data(contentsOf: readyFile),
               let ready = try? JSONDecoder().decode(ReadyFile.self, from: data),
               (1...65535).contains(ready.port) {
                timer.invalidate()
                self.readinessTimer = nil
                self.runtimePort = ready.port
                self.runtimeReady = true
                let script = self.entrypoint.trimmingCharacters(in: .whitespacesAndNewlines)
                self.startProject(script: script)
            } else if self.readinessAttempts >= 300 {
                timer.invalidate()
                self.readinessTimer = nil
                self.fail("Node.js did not start its local control service within 30 seconds.")
            }
        }
    }

    private func startProject(script: String) {
        guard runtimeReady, projectRoot != nil, let projectPort else {
            fail("The Node.js runtime is not ready yet.")
            return
        }

        request(
            path: "/start",
            method: "POST",
            payload: ["entrypoint": script, "port": projectPort]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let response):
                self.message = response["message"] as? String ?? "Node project is running."
                self.state = .running
                self.startLogPolling()
            case .failure(let error):
                self.fail(error.localizedDescription)
            }
        }
    }

    private func startLogPolling() {
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.fetchLogs()
        }
        fetchLogs()
    }

    private func fetchLogs() {
        guard !isFetchingLogs, runtimeReady, runtimePort != nil else { return }
        isFetchingLogs = true
        request(path: "/logs?after=\(logSequence)", method: "GET", payload: nil) { [weak self] result in
            guard let self else { return }
            self.isFetchingLogs = false
            guard case .success(let response) = result,
                  let rows = response["items"] as? [[String: Any]]
            else { return }

            for row in rows {
                if let sequence = row["sequence"] as? Int { self.logSequence = max(self.logSequence, sequence) }
                if let text = row["text"] as? String { self.logs.append(NodeRuntimeLog(text: text)) }
            }
            if self.logs.count > 100 {
                self.logs.removeFirst(self.logs.count - 100)
            }
        }
    }

    private func request(
        path: String,
        method: String,
        payload: [String: Any]?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        guard let runtimePort,
              let url = URL(string: "http://127.0.0.1:\(runtimePort)\(path)")
        else {
            DispatchQueue.main.async {
                completion(.failure(Self.error("The Node.js control service is unavailable.")))
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.setValue(runtimeToken, forHTTPHeaderField: "X-PocketHost-Token")
        if let payload {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<[String: Any], Error>
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse,
                      let data,
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if (200..<300).contains(response.statusCode) {
                    result = .success(object)
                } else {
                    result = .failure(Self.error(object["error"] as? String ?? "Node.js returned HTTP \(response.statusCode)."))
                }
            } else {
                result = .failure(Self.error("The Node.js control service returned an invalid response."))
            }

            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func runtimeDidExit(_ code: Int32) {
        runtimeReady = false
        runtimePort = nil
        readinessTimer?.invalidate()
        readinessTimer = nil
        logTimer?.invalidate()
        logTimer = nil
        fail("The embedded Node.js runtime exited with status \(code). Relaunch PocketHost to start a new runtime.")
    }

    private func fail(_ text: String) {
        message = text
        state = .failed
    }

    private static func isActive(_ state: State) -> Bool {
        state == .starting || state == .running || state == .stopping
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "NodeRuntime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private struct ReadyFile: Decodable {
        let port: Int
    }

    private static let bootstrap = #"""
    'use strict';

    const fs = require('fs');
    const http = require('http');
    const net = require('net');
    const path = require('path');
    const Module = require('module');
    const { pathToFileURL } = require('url');

    const projectRoot = path.resolve(process.argv[2]);
    const readyFile = process.argv[3];
    const token = process.argv[4];
    const logBuffer = [];
    const projectServers = new Set();
    const projectTimers = new Map();
    let sequence = 0;
    let projectState = 'idle';
    let active = false;
    let activeModule = null;
    let previousPort;
    let previousHost;

    function writeLog(text) {
      const line = { sequence: ++sequence, text: String(text) };
      logBuffer.push(line);
      if (logBuffer.length > 200) logBuffer.shift();
    }

    function format(value) {
      if (typeof value === 'string') return value;
      try { return JSON.stringify(value); } catch (_) { return String(value); }
    }

    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      const original = console[level].bind(console);
      console[level] = (...values) => {
        writeLog(`[${level}] ${values.map(format).join(' ')}`);
        original(...values);
      };
    }

    const originalListen = net.Server.prototype.listen;
    net.Server.prototype.listen = function (...args) {
      if (active) projectServers.add(this);
      return originalListen.apply(this, args);
    };

    const originalSetTimeout = global.setTimeout.bind(global);
    const originalClearTimeout = global.clearTimeout.bind(global);
    const originalSetInterval = global.setInterval.bind(global);
    const originalClearInterval = global.clearInterval.bind(global);
    const originalSetImmediate = global.setImmediate.bind(global);
    const originalClearImmediate = global.clearImmediate.bind(global);

    global.setTimeout = function (callback, delay, ...args) {
      if (!active) return originalSetTimeout(callback, delay, ...args);
      let handle;
      handle = originalSetTimeout(function (...callbackArgs) {
        projectTimers.delete(handle);
        return callback.apply(this, callbackArgs);
      }, delay, ...args);
      projectTimers.set(handle, originalClearTimeout);
      return handle;
    };
    global.clearTimeout = function (handle) {
      projectTimers.delete(handle);
      return originalClearTimeout(handle);
    };
    global.setInterval = function (callback, delay, ...args) {
      const handle = originalSetInterval(callback, delay, ...args);
      if (active) projectTimers.set(handle, originalClearInterval);
      return handle;
    };
    global.clearInterval = function (handle) {
      projectTimers.delete(handle);
      return originalClearInterval(handle);
    };
    global.setImmediate = function (callback, ...args) {
      if (!active) return originalSetImmediate(callback, ...args);
      let handle;
      handle = originalSetImmediate(function (...callbackArgs) {
        projectTimers.delete(handle);
        return callback.apply(this, callbackArgs);
      }, ...args);
      projectTimers.set(handle, originalClearImmediate);
      return handle;
    };
    global.clearImmediate = function (handle) {
      projectTimers.delete(handle);
      return originalClearImmediate(handle);
    };

    function send(response, status, body) {
      const data = Buffer.from(JSON.stringify(body));
      response.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': data.length,
        'Cache-Control': 'no-store'
      });
      response.end(data);
    }

    function readBody(request) {
      return new Promise((resolve, reject) => {
        let body = '';
        request.on('data', chunk => {
          body += chunk;
          if (body.length > 65536) reject(new Error('Request body is too large.'));
        });
        request.on('end', () => {
          try { resolve(body ? JSON.parse(body) : {}); }
          catch (_) { reject(new Error('Request body must be JSON.')); }
        });
        request.on('error', reject);
      });
    }

    function resolveEntry(input) {
      let entry = path.resolve(projectRoot, String(input || 'server.js'));
      if (entry !== projectRoot && !entry.startsWith(projectRoot + path.sep)) {
        throw new Error('The entry file must stay inside the hosted www folder.');
      }

      let stat;
      try { stat = fs.statSync(entry); }
      catch (_) { throw new Error(`Entry file not found: ${path.relative(projectRoot, entry)}`); }

      if (stat.isDirectory()) {
        const packageFile = path.join(entry, 'package.json');
        let main = 'server.js';
        if (fs.existsSync(packageFile)) {
          try { main = JSON.parse(fs.readFileSync(packageFile, 'utf8')).main || 'index.js'; }
          catch (_) { throw new Error('The project package.json is not valid JSON.'); }
        }
        entry = path.resolve(entry, main);
      } else if (path.basename(entry).toLowerCase() === 'package.json') {
        let main;
        try { main = JSON.parse(fs.readFileSync(entry, 'utf8')).main || 'index.js'; }
        catch (_) { throw new Error('The project package.json is not valid JSON.'); }
        entry = path.resolve(path.dirname(entry), main);
      }

      if (entry !== projectRoot && !entry.startsWith(projectRoot + path.sep)) {
        throw new Error('The package main file must stay inside the hosted www folder.');
      }
      if (!fs.existsSync(entry) || !fs.statSync(entry).isFile()) {
        throw new Error(`Entry file not found: ${path.relative(projectRoot, entry)}`);
      }
      if (!['.js', '.cjs', '.mjs'].includes(path.extname(entry).toLowerCase())) {
        throw new Error('Node projects need a .js, .cjs or .mjs entry file.');
      }
      return entry;
    }

    function clearProjectModuleCache() {
      for (const filename of Object.keys(require.cache)) {
        if (filename === projectRoot || filename.startsWith(projectRoot + path.sep)) {
          delete require.cache[filename];
        }
      }
    }

    async function stopProject() {
      if (!active) return;
      projectState = 'stopping';
      const exported = activeModule && activeModule.exports;
      if (exported && typeof exported.stop === 'function') {
        try { await exported.stop(); }
        catch (error) { writeLog(`[error] ${error.stack || error}`); }
      }

      active = false;
      for (const [handle, clear] of projectTimers) {
        try { clear(handle); } catch (_) {}
      }
      projectTimers.clear();

      const servers = Array.from(projectServers);
      projectServers.clear();
      await Promise.all(servers.map(server => new Promise(resolve => {
        let finished = false;
        const done = () => {
          if (finished) return;
          finished = true;
          resolve();
        };
        try {
          server.close(done);
          if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
          originalSetTimeout(done, 1500);
        } catch (_) { done(); }
      })));

      clearProjectModuleCache();
      if (previousPort === undefined) delete process.env.PORT;
      else process.env.PORT = previousPort;
      if (previousHost === undefined) delete process.env.HOST;
      else process.env.HOST = previousHost;
      process.chdir(projectRoot);
      activeModule = null;
      projectState = 'idle';
      writeLog('[runtime] Project stopped. The embedded Node.js engine remains ready.');
    }

    async function startProject(options) {
      if (active) throw new Error('Stop the current Node project before starting another.');
      const entry = resolveEntry(options.entrypoint);
      const port = Number(options.port);
      if (!Number.isInteger(port) || port < 1024 || port > 65535) {
        throw new Error('PocketHost could not reserve a valid project port.');
      }

      projectState = 'starting';
      previousPort = process.env.PORT;
      previousHost = process.env.HOST;
      process.env.PORT = String(port);
      process.env.HOST = '0.0.0.0';
      process.chdir(path.dirname(entry));
      active = true;

      try {
        if (path.extname(entry).toLowerCase() === '.mjs') {
          await import(`${pathToFileURL(entry).href}?pockethost=${Date.now()}`);
        } else {
          const entryModule = new Module(entry);
          entryModule.filename = entry;
          entryModule.paths = Module._nodeModulePaths(path.dirname(entry));
          const previousMain = require.main;
          const previousProcessMain = process.mainModule;
          require.main = entryModule;
          process.mainModule = entryModule;
          try { entryModule.load(entry); }
          finally {
            require.main = previousMain;
            process.mainModule = previousProcessMain;
          }
          activeModule = entryModule;
          const exported = entryModule.exports;
          if (typeof exported === 'function') await exported();
          else if (exported && typeof exported.start === 'function') await exported.start();
        }
        projectState = 'running';
        writeLog(`[runtime] Running ${path.relative(projectRoot, entry)} with PORT=${port}.`);
        return { message: `Running ${path.relative(projectRoot, entry)} on port ${port}.` };
      } catch (error) {
        writeLog(`[error] ${error.stack || error}`);
        await stopProject();
        projectState = 'error';
        throw new Error(error.message || String(error));
      }
    }

    const controlServer = http.createServer(async (request, response) => {
      if (request.socket.remoteAddress !== '127.0.0.1' && request.socket.remoteAddress !== '::ffff:127.0.0.1') {
        send(response, 403, { error: 'Local control requests only.' });
        return;
      }
      if (request.headers['x-pockethost-token'] !== token) {
        send(response, 401, { error: 'Unauthorized.' });
        return;
      }

      const url = new URL(request.url, 'http://127.0.0.1');
      if (request.method === 'GET' && url.pathname === '/health') {
        send(response, 200, { state: projectState });
        return;
      }
      if (request.method === 'GET' && url.pathname === '/logs') {
        const after = Number(url.searchParams.get('after') || 0);
        send(response, 200, { items: logBuffer.filter(line => line.sequence > after) });
        return;
      }
      if (request.method === 'POST' && url.pathname === '/start') {
        try {
          const options = await readBody(request);
          const result = await startProject(options);
          send(response, 200, result);
        } catch (error) {
          send(response, 400, { error: error.message || String(error) });
        }
        return;
      }
      if (request.method === 'POST' && url.pathname === '/stop') {
        await stopProject();
        send(response, 200, { message: 'Project stopped. The embedded runtime remains ready.' });
        return;
      }
      send(response, 404, { error: 'No such runtime control route.' });
    });

    process.chdir(projectRoot);
    controlServer.listen(0, '127.0.0.1', () => {
      fs.writeFileSync(readyFile, JSON.stringify({ port: controlServer.address().port }), { mode: 0o600 });
      writeLog('[runtime] Embedded Node.js control service is ready.');
    });
    """#
}
