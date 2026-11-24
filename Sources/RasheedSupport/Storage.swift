import CryptoKit
import Foundation
import RasheedCore
import Security

final class CustomerStorage: RasheedCore.DeviceStore {
    private let platformURL: URL
    private let workspaceId: String

    init(platformURL: URL, workspaceId: String) {
        self.platformURL = platformURL
        self.workspaceId = workspaceId
    }

    func get(scopeKey: String, key: RasheedCore.StoreKey) throws -> String? {
        try withStorageErrors {
            let scope = try scopeParts(scopeKey)
            switch key {
            case .configuration:
                return try readString(metadata(scope).appending(path: "configuration.json")) ?? legacyConfiguration()
            case .deviceToken(let account):
                let account = try accountHash(account, scope: scope)
                try remember(account, scope: scope)
                return try token(account)
            case .profile(let account, let version, let tokenHash):
                let account = try accountHash(account, scope: scope)
                return try readString(cache(scope).appending(path: "profile-" + Self.hash([account, version, tokenHash]) + ".json"))
            case .workspace(let account, let version):
                let account = try accountHash(account, scope: scope)
                return try readString(cache(scope).appending(path: "workspace-" + Self.hash([account, version]) + ".json"))
            case .inboxCache(let account, let version, let tokenHash):
                let account = try accountHash(account, scope: scope)
                return try readString(cache(scope).appending(path: "inbox-" + Self.hash([account, version, tokenHash]) + ".json"))
            case .inboxJournal(let account, let tokenHash):
                let account = try accountHash(account, scope: scope)
                return try readString(metadata(scope).appending(path: "inbox-journals")
                    .appending(path: Self.hash([account, tokenHash]) + ".json"))
            case .pushState:
                let url = try metadata(scope).appending(path: "push-state.json")
                let file: FileHandle
                do { file = try FileHandle(forReadingFrom: url) }
                catch {
                    if isMissing(error) { return nil }
                    throw error
                }
                defer { try? file.close() }
                let data = try file.read(upToCount: 24 * 1024 + 1) ?? Data()
                guard data.count <= 24 * 1024, let value = String(data: data, encoding: .utf8) else {
                    throw RasheedCore.ClientError.Storage(reason: "The saved push state is invalid.")
                }
                return value
            }
        }
    }

    func set(scopeKey: String, key: RasheedCore.StoreKey, value: String?) throws {
        try withStorageErrors {
            let scope = try scopeParts(scopeKey)
            switch key {
            case .configuration:
                try write(value.map { Data($0.utf8) }, to: metadata(scope).appending(path: "configuration.json"))
            case .deviceToken(let account):
                let account = try accountHash(account, scope: scope)
                // The index must survive a failed write or a client recreated before connect.
                try remember(account, scope: scope)
                if let value { try saveToken(value, account: account) }
                else { try clearToken(account) }
            case .profile(let account, let version, let tokenHash):
                let account = try accountHash(account, scope: scope)
                try write(value.map { Data($0.utf8) },
                          to: cache(scope).appending(path: "profile-" + Self.hash([account, version, tokenHash]) + ".json"))
            case .workspace(let account, let version):
                let account = try accountHash(account, scope: scope)
                try write(value.map { Data($0.utf8) },
                          to: cache(scope).appending(path: "workspace-" + Self.hash([account, version]) + ".json"))
            case .inboxCache(let account, let version, let tokenHash):
                let account = try accountHash(account, scope: scope)
                try write(value.map { Data($0.utf8) },
                          to: cache(scope).appending(path: "inbox-" + Self.hash([account, version, tokenHash]) + ".json"))
            case .inboxJournal(let account, let tokenHash):
                let account = try accountHash(account, scope: scope)
                try write(value.map { Data($0.utf8) },
                          to: metadata(scope).appending(path: "inbox-journals")
                            .appending(path: Self.hash([account, tokenHash]) + ".json"))
            case .pushState:
                if let value, value.utf8.count > 24 * 1024 {
                    throw RasheedCore.ClientError.Storage(reason: "The saved push state exceeds 24 KiB.")
                }
                try write(value.map { Data($0.utf8) }, to: metadata(scope).appending(path: "push-state.json"))
            }
        }
    }

    func clear(scopeKey: String) throws {
        try withStorageErrors {
            let scope = try scopeParts(scopeKey)
            var accounts = try knownAccounts(scope)
            if let legacy = try legacyAccount(), !accounts.contains(legacy) {
                accounts.append(legacy)
                try write(JSONEncoder().encode(accounts), to: metadata(scope).appending(path: "accounts.json"))
            }
            var failure: Error?
            for account in accounts {
                do { try clearToken(account) }
                catch { if failure == nil { failure = error } }
            }
            for url in [try cache(scope), try metadata(scope).appending(path: "configuration.json"),
                        try metadata(scope).appending(path: "inbox-journals"),
                        try metadata(scope).appending(path: "push-state.json")] {
                do { try remove(url) }
                catch { if failure == nil { failure = error } }
            }
            if let failure { throw failure }
            try remove(metadata(scope).appending(path: "accounts.json"))
        }
    }

    private static func hash(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.map { "\($0.utf8.count):\($0)" }.joined().utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func scopeParts(_ scopeKey: String) throws -> [String] {
        let scope = try JSONDecoder().decode([String].self, from: Data(scopeKey.utf8))
        guard scope.count == 2, scope[1] == workspaceId else {
            throw RasheedCore.ClientError.Storage(reason: "Invalid support storage scope.")
        }
        return scope
    }

    private func accountHash(_ account: String, scope: [String]) throws -> String {
        let parts = try JSONDecoder().decode([String].self, from: Data(account.utf8))
        guard parts.count == 4, parts[0] == scope[0], parts[3] == scope[1] else {
            throw RasheedCore.ClientError.Storage(reason: "Invalid support credential scope.")
        }
        return Self.hash([platformURL.absoluteString, parts[1], parts[2], workspaceId])
    }

    private func directory(_ location: FileManager.SearchPathDirectory, scope: [String]) throws -> URL {
        guard let root = FileManager.default.urls(for: location, in: .userDomainMask).first else {
            throw RasheedCore.ClientError.Storage(reason: "Could not locate support storage.")
        }
        return root.appending(path: "ai.rasheed.support.customer", directoryHint: .isDirectory)
            .appending(path: "rust-core-1", directoryHint: .isDirectory)
            .appending(path: Self.hash(scope), directoryHint: .isDirectory)
    }

    private func metadata(_ scope: [String]) throws -> URL { try directory(.applicationSupportDirectory, scope: scope) }
    private func cache(_ scope: [String]) throws -> URL { try directory(.cachesDirectory, scope: scope) }

    private func knownAccounts(_ scope: [String]) throws -> [String] {
        guard let data = try read(metadata(scope).appending(path: "accounts.json")) else { return [] }
        let accounts = try JSONDecoder().decode([String].self, from: data)
        guard accounts.allSatisfy({ $0.utf8.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw RasheedCore.ClientError.Storage(reason: "The support credential index is invalid.")
        }
        return accounts
    }

    private func remember(_ account: String, scope: [String]) throws {
        var accounts = try knownAccounts(scope)
        guard !accounts.contains(account) else { return }
        accounts.append(account)
        try write(JSONEncoder().encode(accounts), to: metadata(scope).appending(path: "accounts.json"))
    }

    private func legacyConfiguration() throws -> String? {
        let key = "rasheed.customer.configuration." + Self.hash([platformURL.absoluteString, workspaceId])
        guard let stored = UserDefaults.standard.object(forKey: key) else { return nil }
        guard let data = stored as? Data, let configuration = String(data: data, encoding: .utf8) else {
            throw RasheedCore.ClientError.Storage(reason: "The saved support configuration is invalid.")
        }
        return configuration
    }

    private func legacyAccount() throws -> String? {
        guard let value = try legacyConfiguration() else { return nil }
        struct AccountConfiguration: Decodable {
            let uri: String
            let databaseName: String
        }
        let configuration = try JSONDecoder().decode(AccountConfiguration.self, from: Data(value.utf8))
        return Self.hash([platformURL.absoluteString, configuration.uri, configuration.databaseName, workspaceId])
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ai.rasheed.support.customer",
         kSecAttrAccount as String: account]
    }

    private func token(_ account: String) throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            throw RasheedCore.ClientError.Storage(reason: "Could not read the support identity from Keychain (\(status)).")
        }
        return token
    }

    private func saveToken(_ token: String, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw RasheedCore.ClientError.Storage(reason: "Could not save the support identity in Keychain (\(status)).")
        }
        var request = query(account).merging(values) { _, new in new }
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(request as CFDictionary, nil)
        guard inserted == errSecSuccess else {
            throw RasheedCore.ClientError.Storage(reason: "Could not save the support identity in Keychain (\(inserted)).")
        }
    }

    private func clearToken(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RasheedCore.ClientError.Storage(reason: "Could not remove the support identity from Keychain (\(status)).")
        }
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch {
            if isMissing(error) { return nil }
            throw error
        }
    }

    private func readString(_ url: URL) throws -> String? {
        guard let data = try read(url) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw RasheedCore.ClientError.Storage(reason: "The saved support value is not UTF-8.")
        }
        return value
    }

    private func write(_ data: Data?, to url: URL) throws {
        guard let data else { try remove(url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func remove(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch {
            if !isMissing(error) { throw error }
        }
    }

    private func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
    }

    private func withStorageErrors<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            if let error = error as? RasheedCore.ClientError, case .Storage = error { throw error }
            throw RasheedCore.ClientError.Storage(reason: error.localizedDescription)
        }
    }
}
