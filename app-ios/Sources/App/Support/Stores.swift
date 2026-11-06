import DshCore
import Foundation
import Security

/// Keychain wrapper for host credentials (the dsh cookie is a bearer
/// credential too; MVP stores the SSH password only, one item per host).
enum Keychain {
    private static let service = "io.github.ccch1mneyyy.dshApp.ssh"

    static func password(for hostId: String) -> String? {
        var query = baseQuery(for: hostId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setPassword(_ password: String?, for hostId: String) {
        guard let password, !password.isEmpty else {
            deletePassword(for: hostId)
            return
        }
        let data = Data(password.utf8)
        var update = baseQuery(for: hostId)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(update as CFDictionary, attributes as CFDictionary) == errSecSuccess {
            return
        }
        update[kSecValueData as String] = data
        update[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(update as CFDictionary, nil)
    }

    static func deletePassword(for hostId: String) {
        SecItemDelete(baseQuery(for: hostId) as CFDictionary)
    }

    private static func baseQuery(for hostId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostId,
        ]
    }
}

/// Persisted host list and their TOFU pins (the password lives in the
/// Keychain, never here).
@MainActor
final class HostStore: ObservableObject {
    @Published private(set) var hosts: [SshHostConfig] = []
    private var fingerprints: [String: String] = [:]

    private let defaults: UserDefaults
    private static let hostsKey = "dsh.hosts"
    private static let fingerprintsKey = "dsh.hostFingerprints"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.hostsKey),
            let saved = try? JSONDecoder().decode([SshHostConfig].self, from: data)
        {
            hosts = saved
        }
        fingerprints = (defaults.dictionary(forKey: Self.fingerprintsKey) as? [String: String]) ?? [:]
    }

    func fingerprint(for hostId: String) -> String? {
        fingerprints[hostId]
    }

    func save(_ host: SshHostConfig, password: String?) {
        if !hosts.contains(where: { $0.id == host.id }) {
            hosts.append(host)
        } else {
            hosts = hosts.map { $0.id == host.id ? host : $0 }
        }
        if let password {
            Keychain.setPassword(password, for: host.id)
        }
        persist()
    }

    func pin(fingerprint: String, for hostId: String) {
        fingerprints[hostId] = fingerprint
        persist()
    }

    func remove(hostId: String) {
        hosts.removeAll { $0.id == hostId }
        fingerprints.removeValue(forKey: hostId)
        Keychain.deletePassword(for: hostId)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(hosts) {
            defaults.set(data, forKey: Self.hostsKey)
        }
        defaults.set(fingerprints, forKey: Self.fingerprintsKey)
    }
}
