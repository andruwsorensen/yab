import Foundation
import YabStore
import Security
import Darwin

/// The outer, signed app owns Chromium's existing secret. No secret crosses
/// argv, environment, a file, the page protocol or the original-caller stdin.
enum ChromiumSafeStorage {
    static let service = DevelopmentKeychain.service("Yab Safe Storage")
    static let account = "Yab"
    static let limit = 4096

    struct Failure: Error { let status: OSStatus }

    /// Separate lookup from creation: denied/unreadable is never 'not found'.
    /// Duplicate creation is an inter-process race, resolved by reading the
    /// winning item; an existing secret is never updated or replaced.
    static func obtain(read: () -> (OSStatus, Data?), add: (Data) -> OSStatus,
                       random: () throws -> Data) throws -> Data {
        let (status, existing) = read()
        if status == errSecSuccess { return try validated(existing) }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        let fresh = try validated(random())
        let saved = add(fresh)
        if saved == errSecDuplicateItem {
            let (status, winner) = read()
            guard status == errSecSuccess else { throw Failure(status: status) }
            return try validated(winner)
        }
        guard saved == errSecSuccess else { throw Failure(status: saved) }
        return fresh
    }

    private static func validated(_ data: Data?) throws -> Data {
        guard let data, !data.isEmpty, data.count <= limit else { throw Failure(status: errSecDecode) }
        return data
    }

    /// Retain Keychain's code-identity boundary when the owner delegates its
    /// secret: the child must be the sealed nested image, not just any program
    /// the same uid managed to place at its path. All validation runs on the
    /// broker queue, before the Keychain read.
    static func authorizes(pid: pid_t, helper: URL) -> Bool {
        var owner: SecCode?, sealedOwner: SecStaticCode?, image: SecStaticCode?
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecCodeCopySelf([], &owner) == errSecSuccess, let owner,
              SecCodeCheckValidity(owner, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(owner, [], &sealedOwner) == errSecSuccess, let sealedOwner,
              SecStaticCodeCheckValidity(sealedOwner, strict, nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(helper as CFURL, [], &image) == errSecSuccess, let image,
              SecStaticCodeCheckValidity(image, [], nil) == errSecSuccess else { return false }
        var requirement: SecRequirement?, peer: SecCode?
        guard SecCodeCopyDesignatedRequirement(image, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &peer) == errSecSuccess, let peer,
              SecCodeCheckValidity(peer, [], requirement) == errSecSuccess else { return false }
        var expected: CFDictionary?, actual: CFDictionary?
        var peerImage: SecStaticCode?
        let information = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(image, information, &expected) == errSecSuccess,
              SecCodeCopyStaticCode(peer, [], &peerImage) == errSecSuccess, let peerImage,
              SecCodeCopySigningInformation(peerImage, information, &actual) == errSecSuccess,
              let wanted = (expected as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              let got = (actual as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return false }
        return wanted == got && SecCodeCheckValidity(peer, [], nil) == errSecSuccess
    }

    static func password() throws -> Data {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne, kSecReturnData: true]
        var attributes: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlocked]
        // A real-Keychain probe must not consult the person's login Keychain.
        // Match the existing r1-production fixture, now read by the outer app.
        if Store.testing, let home = ProcessInfo.processInfo.environment["YAB_REAL_KEYCHAIN"], !home.isEmpty {
            var keychain: SecKeychain?
            let status = SecKeychainOpen(home + "/test.keychain-db", &keychain)
            guard status == errSecSuccess, let keychain else { throw Failure(status: status) }
            query[kSecMatchSearchList] = [keychain]
            attributes[kSecUseKeychain] = keychain
        }
        return try obtain(read: {
            var result: CFTypeRef?
            // An old helper-created item's ACL may need the person's consent
            // for the signed outer app. Do not change that ACL or replace its
            // secret if access is refused. Automated fixtures never show UI.
            let status = Store.testing
                ? Keychain.copyMatching(query as CFDictionary, &result)
                : Keychain.copyMatchingAsking(query as CFDictionary, &result)
            return (status, result as? Data)
        }, add: { data in
            var item = attributes
            item[kSecValueData] = data
            return Keychain.add(item as CFDictionary, nil)
        }, random: {
            // Same 128-bit random, base64-encoded passphrase as Chromium.
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw Failure(status: status) }
            return Data(Data(bytes).base64EncodedString().utf8)
        })
    }
}

/// A one-use extension of the private launch channel, available before CEF
/// initialization. It authenticates the exact child Process by kernel PID and
/// uid before reading the Keychain. The ordinary control socket starts too
/// late (OnContextInitialized); stdin stays available for original-caller proof.
final class ChromiumSafeStorageBroker: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let lifecycle = NSLock()
    private var active = false
    private var stopped = false
    private let path: String
    private let authorize: @Sendable (pid_t) -> Bool
    private let provide: @Sendable () throws -> Data

    init(path: String, authorize: @escaping @Sendable (pid_t) -> Bool, provide: @escaping @Sendable () throws -> Data = { try ChromiumSafeStorage.password() }) throws {
        self.path = path
        self.authorize = authorize
        self.provide = provide
        var directory = stat()
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard lstat(parent, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              directory.st_uid == getuid(), directory.st_mode & 0o077 == 0 else { throw POSIXError(.EACCES) }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd); throw POSIXError(.ENAMETOOLONG)
        }
        _ = withUnsafeMutableBytes(of: &address.sun_path) { buffer in path.utf8CString.withUnsafeBytes { buffer.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let error = errno; Darwin.close(fd); throw POSIXError(.init(rawValue: error) ?? .EIO) }
        guard chmod(path, 0o600) == 0, listen(fd, 1) == 0 else {
            let error = errno; Darwin.close(fd); unlink(path); throw POSIXError(.init(rawValue: error) ?? .EIO)
        }
        fcntl(fd, F_SETFD, FD_CLOEXEC)
        fcntl(fd, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setCancelHandler { Darwin.close(fd); unlink(path) }
    }

    func launched(pid: pid_t) {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        // A child may exit between run() and this call; its exit handler has
        // already stopped the channel in that case.
        if stopped { return }
        precondition(!active)
        let fd = Int32(source.handle)
        let provide = self.provide
        let authorize = self.authorize
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let source = self.source
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else {
                if errno != EAGAIN && errno != EINTR { source.cancel() }
                return
            }
            defer { Darwin.close(peer); source.cancel() }
            var uid = uid_t(), gid = gid_t(), actual = pid_t()
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getpeereid(peer, &uid, &gid) == 0, uid == getuid(),
                  getsockopt(peer, SOL_LOCAL, LOCAL_PEERPID, &actual, &size) == 0,
                  size == MemoryLayout<pid_t>.size, actual == pid, authorize(actual) else {
                NSLog("Yab: Safe Storage launch peer identity refused")
                return
            }
            fcntl(peer, F_SETFD, FD_CLOEXEC)
            fcntl(peer, F_SETFL, fcntl(peer, F_GETFL) & ~O_NONBLOCK)
            var noSignal: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            do {
                let secret = try provide()
                guard !secret.isEmpty, secret.count <= ChromiumSafeStorage.limit else { throw ChromiumSafeStorage.Failure(status: errSecDecode) }
                var count = UInt32(secret.count).bigEndian
                var frame = withUnsafeBytes(of: &count) { Data($0) }
                frame.append(secret)
                try frame.withUnsafeBytes { buffer in
                    var sent = 0
                    while sent < buffer.count {
                        let wrote = Darwin.write(peer, buffer.baseAddress!.advanced(by: sent), buffer.count - sent)
                        if wrote < 0, errno == EINTR { continue }
                        guard wrote > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                        sent += wrote
                    }
                }
            } catch {
                // EOF makes the supplied-secret provider fail closed. It must
                // not try Keychain again or generate a replacement secret.
                let status = (error as? ChromiumSafeStorage.Failure)?.status ?? errSecIO
                NSLog("Yab: Safe Storage launch handoff failed (%d)", status)
            }
        }
        active = true
        source.activate()
    }

    func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        stopped = true
        if !active { active = true; source.activate() }
        source.cancel()
    }
    deinit { stop() }
}
