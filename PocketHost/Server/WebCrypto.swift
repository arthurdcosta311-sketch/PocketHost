//
//  WebCrypto.swift
//  PocketHost
//
//  The cryptography behind the Web Crypto shim. Browsers only expose
//  `crypto.subtle` in a secure context, and PocketHost serves plain HTTP over
//  the network, so pages call this endpoint instead and the work is done here
//  with CryptoKit, on the device.
//

import CommonCrypto
import CryptoKit
import Foundation

enum WebCrypto {
    static let endpointPath = "/.pockethost/crypto"

    /// The body is base64, so it can be a few times the size of the data.
    static let maximumBodyBytes = 16 * 1024 * 1024

    // MARK: - Hashes

    enum Hash {
        case sha1
        case sha256
        case sha384
        case sha512

        init?(_ raw: String?) {
            switch (raw ?? "").uppercased().replacingOccurrences(of: "-", with: "") {
            case "SHA1": self = .sha1
            case "SHA256": self = .sha256
            case "SHA384": self = .sha384
            case "SHA512": self = .sha512
            default: return nil
            }
        }

        var pseudoRandom: CCPseudoRandomAlgorithm {
            switch self {
            case .sha1: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
            case .sha256: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
            case .sha384: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
            case .sha512: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
            }
        }
    }

    // MARK: - Wire format

    private struct Payload: Decodable {
        let op: String
        let alg: String?
        let hash: String?
        let key: String?
        let data: String?
        let iv: String?
        let aad: String?
        let salt: String?
        let info: String?
        let iterations: Int?
        let length: Int?
    }

    private struct Answer: Encodable {
        let ok: Bool
        let data: String?
        let error: String?
    }

    private enum CryptoError: Error {
        case message(String)

        var text: String {
            switch self {
            case .message(let text): return text
            }
        }
    }

    // MARK: - Endpoint

    static func handle(_ body: Data) -> HTTPResponse {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: body)
        } catch {
            return answer(Answer(ok: false, data: nil, error: "PocketHost could not read the crypto request."))
        }

        do {
            let output = try run(payload)
            return answer(Answer(ok: true, data: output.base64EncodedString(), error: nil))
        } catch let error as CryptoError {
            return answer(Answer(ok: false, data: nil, error: error.text))
        } catch {
            return answer(Answer(ok: false, data: nil, error: error.localizedDescription))
        }
    }

    /// GET fallback: the same JSON payload, base64url in `p`. A browser that
    /// cannot POST for any reason still gets working crypto through this.
    static func handle(query: String?) -> HTTPResponse {
        guard let text = queryValue("p", in: query),
              let data = decodeBase64URL(text)
        else {
            return answer(Answer(ok: false, data: nil, error: "PocketHost got no crypto request."))
        }

        return handle(data)
    }

    static func options() -> HTTPResponse {
        answer(Answer(ok: true, data: nil, error: nil), status: .ok, allowOptions: true)
    }

    // MARK: - Operations

    private static func run(_ payload: Payload) throws -> Data {
        switch payload.op {
        case "digest":
            guard let hash = Hash(payload.alg) else { throw CryptoError.message("Unsupported hash.") }
            return digest(hash, data(payload.data))

        case "hmac":
            guard let hash = Hash(payload.hash) else { throw CryptoError.message("Unsupported HMAC hash.") }
            return hmac(hash, key: data(payload.key), message: data(payload.data))

        case "aesgcm-encrypt":
            return try sealed(encrypt: true, payload)

        case "aesgcm-decrypt":
            return try sealed(encrypt: false, payload)

        case "pbkdf2":
            guard let hash = Hash(payload.hash) else { throw CryptoError.message("Unsupported PBKDF2 hash.") }
            let length = payload.length ?? 32
            guard length > 0, length <= 1024 else { throw CryptoError.message("Unsupported derived length.") }
            let iterations = payload.iterations ?? 100_000
            guard iterations > 0, iterations <= 5_000_000 else {
                throw CryptoError.message("Unsupported iteration count.")
            }
            guard let derived = pbkdf2(
                password: data(payload.key),
                salt: data(payload.salt),
                iterations: iterations,
                length: length,
                hash: hash
            ) else { throw CryptoError.message("The key could not be derived.") }
            return derived

        case "hkdf":
            guard let hash = Hash(payload.hash) else { throw CryptoError.message("Unsupported HKDF hash.") }
            let length = payload.length ?? 32
            guard length > 0, length <= 1024 else { throw CryptoError.message("Unsupported derived length.") }
            return hkdf(
                hash,
                key: data(payload.key),
                salt: data(payload.salt),
                info: data(payload.info),
                length: length
            )

        default:
            throw CryptoError.message("Unsupported crypto operation: \(payload.op)")
        }
    }

    private static func digest(_ hash: Hash, _ message: Data) -> Data {
        switch hash {
        case .sha1: return Data(Insecure.SHA1.hash(data: message))
        case .sha256: return Data(SHA256.hash(data: message))
        case .sha384: return Data(SHA384.hash(data: message))
        case .sha512: return Data(SHA512.hash(data: message))
        }
    }

    private static func hmac(_ hash: Hash, key: Data, message: Data) -> Data {
        let key = SymmetricKey(data: key)

        switch hash {
        case .sha1: return Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: return Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha384: return Data(HMAC<SHA384>.authenticationCode(for: message, using: key))
        case .sha512: return Data(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
    }

    private static func sealed(encrypt: Bool, _ payload: Payload) throws -> Data {
        let keyData = data(payload.key)
        guard [16, 24, 32].contains(keyData.count) else {
            throw CryptoError.message("AES keys are 16, 24 or 32 bytes.")
        }

        let iv = data(payload.iv)
        guard (12...16).contains(iv.count) else {
            throw CryptoError.message("AES-GCM needs a 12 to 16 byte IV.")
        }

        let key = SymmetricKey(data: keyData)
        let nonce: AES.GCM.Nonce
        do {
            nonce = try AES.GCM.Nonce(data: iv)
        } catch {
            throw CryptoError.message("That IV is not valid for AES-GCM.")
        }

        let additionalData: Data? = payload.aad == nil ? nil : data(payload.aad)
        let plaintext = data(payload.data)

        if encrypt {
            let box: AES.GCM.SealedBox
            do {
                if let additionalData {
                    box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: additionalData)
                } else {
                    box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
                }
            } catch {
                throw CryptoError.message("The data could not be encrypted.")
            }

            // Web Crypto appends the tag to the ciphertext; so does this.
            var combined = Data(box.ciphertext)
            combined.append(box.tag)
            return combined
        }

        let combined = data(payload.data)
        guard combined.count >= 16 else { throw CryptoError.message("The ciphertext is too short.") }

        do {
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: combined.dropLast(16),
                tag: combined.suffix(16)
            )

            if let additionalData {
                return try AES.GCM.open(box, using: key, authenticating: additionalData)
            }
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.message("The data could not be decrypted.")
        }
    }

    private static func pbkdf2(
        password: Data,
        salt: Data,
        iterations: Int,
        length: Int,
        hash: Hash
    ) -> Data? {
        var derived = Data(count: length)

        let status = derived.withUnsafeMutableBytes { derivedBytes -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                password.withUnsafeBytes { passwordBytes -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        hash.pseudoRandom,
                        UInt32(iterations),
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        length
                    )
                }
            }
        }

        return status == kCCSuccess ? derived : nil
    }

    private static func hkdf(_ hash: Hash, key: Data, salt: Data, info: Data, length: Int) -> Data {
        let input = SymmetricKey(data: key)

        switch hash {
        case .sha1:
            return HKDF<Insecure.SHA1>.deriveKey(
                inputKeyMaterial: input,
                salt: salt,
                info: info,
                outputByteCount: length
            ).withUnsafeBytes { Data($0) }

        case .sha256:
            return HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input,
                salt: salt,
                info: info,
                outputByteCount: length
            ).withUnsafeBytes { Data($0) }

        case .sha384:
            return HKDF<SHA384>.deriveKey(
                inputKeyMaterial: input,
                salt: salt,
                info: info,
                outputByteCount: length
            ).withUnsafeBytes { Data($0) }

        case .sha512:
            return HKDF<SHA512>.deriveKey(
                inputKeyMaterial: input,
                salt: salt,
                info: info,
                outputByteCount: length
            ).withUnsafeBytes { Data($0) }
        }
    }

    // MARK: - Helpers

    private static func data(_ value: String?) -> Data {
        guard let value, let decoded = Data(base64Encoded: value) else { return Data() }
        return decoded
    }

    private static func queryValue(_ name: String, in query: String?) -> String? {
        guard let query else { return nil }

        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == Substring(name) else { continue }
            return String(parts[1])
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding
        }

        return nil
    }

    private static func decodeBase64URL(_ text: String) -> Data? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: value)
    }

    private static func answer(
        _ answer: Answer,
        status: HTTPStatus = .ok,
        allowOptions: Bool = false
    ) -> HTTPResponse {
        let json = (try? JSONEncoder().encode(answer)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)

        var headers: [String: String] = [
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
            "Content-Length": String(json.count),
            "Access-Control-Allow-Origin": "*"
        ]
        if allowOptions {
            headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS"
            headers["Access-Control-Allow-Headers"] = "Content-Type"
        }

        return HTTPResponse(
            status: status,
            headers: headers,
            body: .data(json)
        )
    }
}
