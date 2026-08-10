// Rewinder — at-rest encryption for frame data.
//
// Every stored artifact (image, OCR text, app-meta json) is sealed with
// AES-256-GCM under one symmetric key held in the login Keychain. The
// Keychain ACL ties the key to this app's code signature, so any other
// process asking for it triggers a user-visible prompt. Encrypted files
// carry an 8-byte magic prefix; readers pass pre-encryption plaintext
// files through untouched, so mixed histories just work.

import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security

let ENC_MAGIC = Data("RWENC001".utf8)
private let KEY_SERVICE = "com.dtav.rewinder"
private let KEY_ACCOUNT = "frame-key"

private let keyLock = NSLock()
private var cachedKey: SymmetricKey?

private func keychainQuery() -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: KEY_SERVICE,
     kSecAttrAccount as String: KEY_ACCOUNT]
}

private func readKeychainKey() -> SymmetricKey? {
    var q = keychainQuery()
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
          let d = out as? Data, d.count == 32 else { return nil }
    return SymmetricKey(data: d)
}

// Returns the frame key, minting and storing one on first use.
// nil only when the Keychain is unavailable — callers fall back to plaintext
// rather than dropping frames.
func frameKey() -> SymmetricKey? {
    keyLock.lock(); defer { keyLock.unlock() }
    if let k = cachedKey { return k }
    if let k = readKeychainKey() { cachedKey = k; return k }
    let fresh = SymmetricKey(size: .bits256)
    var q = keychainQuery()
    q[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
    q[kSecAttrLabel as String] = "Rewinder frame encryption key"
    switch SecItemAdd(q as CFDictionary, nil) {
    case errSecSuccess: cachedKey = fresh
    case errSecDuplicateItem: cachedKey = readKeychainKey()  // lost a race; use the winner
    default: return nil
    }
    return cachedKey
}

// Replaces the stored key (key import on a restored Mac). Frames sealed
// under the old key become unreadable — callers must confirm with the user.
func replaceFrameKey(_ raw: Data) -> Bool {
    guard raw.count == 32 else { return false }
    keyLock.lock(); defer { keyLock.unlock() }
    SecItemDelete(keychainQuery() as CFDictionary)
    var q = keychainQuery()
    q[kSecValueData as String] = raw
    q[kSecAttrLabel as String] = "Rewinder frame encryption key"
    guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
    cachedKey = SymmetricKey(data: raw)
    return true
}

func exportableFrameKey() -> String? {
    frameKey().map { $0.withUnsafeBytes { Data($0) }.base64EncodedString() }
}

func encryptFrameData(_ data: Data) -> Data {
    guard !data.starts(with: ENC_MAGIC), let key = frameKey(),
          let sealed = try? AES.GCM.seal(data, using: key).combined else { return data }
    return ENC_MAGIC + sealed
}

func decryptFrameData(_ data: Data) -> Data {
    guard data.starts(with: ENC_MAGIC), let key = frameKey(),
          let box = try? AES.GCM.SealedBox(combined: data.dropFirst(ENC_MAGIC.count)),
          let plain = try? AES.GCM.open(box, using: key) else { return data }
    return plain
}

// Seals an on-disk file in place (atomically). No-op if already sealed
// or no key is available.
func encryptFileInPlace(_ path: String) {
    let fm = FileManager.default
    guard let d = fm.contents(atPath: path), !d.starts(with: ENC_MAGIC) else { return }
    let e = encryptFrameData(d)
    guard e.starts(with: ENC_MAGIC) else { return }
    let tmp = path + ".enctmp"
    do {
        try e.write(to: URL(fileURLWithPath: tmp))
        _ = try fm.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
    } catch {
        try? fm.removeItem(atPath: tmp)
    }
}

// MARK: - view gate (Touch ID / account password before frames are served)

private let gateLock = NSLock()
private var viewUnlocked = false

func viewingBlocked() -> Bool {
    guard loadRawConfig()["require_unlock"] as? Bool ?? false else { return false }
    gateLock.lock(); defer { gateLock.unlock() }
    return !viewUnlocked
}

func lockViewing() {
    gateLock.lock(); viewUnlocked = false; gateLock.unlock()
}

// Blocks its (per-connection) thread on the system auth prompt.
func requestUnlock() -> Bool {
    let ctx = LAContext()
    var err: NSError?
    guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    ctx.evaluatePolicy(.deviceOwnerAuthentication,
                       localizedReason: "view your screen history") { success, _ in
        ok = success
        sem.signal()
    }
    sem.wait()
    if ok { gateLock.lock(); viewUnlocked = true; gateLock.unlock() }
    return ok
}
