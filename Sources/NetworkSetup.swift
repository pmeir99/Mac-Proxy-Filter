import Foundation
import Security
import SystemConfiguration

enum NetworkSetup {
    static let url = "http://127.0.0.1:17861/proxy.pac"
    static let marker = "MacProxyFilterPreviousPAC"
    static let enabled = kSCPropNetProxiesProxyAutoConfigEnable as String
    static let address = kSCPropNetProxiesProxyAutoConfigURLString as String

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MacProxyFilter", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func apply(enable: Bool) throws -> String {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else { throw failure("macOS authorization was unavailable.") }
        defer { AuthorizationFree(authorization, []) }
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "Mac Proxy Filter" as CFString, nil, authorization),
              SCPreferencesLock(prefs, true) else { throw failure("Network settings are locked or approval was declined.") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            throw failure("Could not read network services.")
        }
        var changed = 0
        var configured = 0
        var skipped = [String]()
        for service in services {
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            var config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            let ours = config[address] as? String == url
            if enable {
                if ours && config[enabled] as? Int == 1 { configured += 1; continue }
                let competing = ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoDiscoveryEnable","FTPEnable","RTSPEnable"]
                if config[marker] != nil || competing.contains(where: { config[$0] as? Int == 1 }) ||
                    (!ours && config[enabled] as? Int == 1) {
                    skipped.append((SCNetworkServiceGetName(service) as String?) ?? "Unnamed service")
                    continue
                }
                var previous = [String: Any]()
                previous[enabled] = config[enabled]
                previous[address] = config[address]
                config[marker] = previous
                config[enabled] = 1
                config[address] = url
                configured += 1
            } else {
                guard ours, let previous = config[marker] as? [String: Any] else { continue }
                config[enabled] = previous[enabled]
                config[address] = previous[address]
                config.removeValue(forKey: marker)
            }
            guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else {
                throw failure("macOS rejected the network settings.")
            }
            changed += 1
        }
        if changed > 0 {
            guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else {
                throw failure("Network settings could not be applied. Retry setup or restore routing.")
            }
        }
        var message = enable ? "Routing configured on \(configured) network services." : "Restored \(changed) network services."
        if !skipped.isEmpty { message += " Existing proxy settings detected on " + skipped.joined(separator: ", ") + "." }
        return message
    }

    static func trust(_ certificate: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", certificate.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw failure("Certificate trust could not be approved. Network routing was left as configured.") }
    }
}
