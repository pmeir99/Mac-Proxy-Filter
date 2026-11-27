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

    static func owns(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return value == url || value.hasPrefix(url + "?revision=")
    }

    // A dedicated, unshared right prevents another app's recent admin approval
    // from silently authorizing this operation. macOS owns the credential dialog.
    private static func approveDisable(_ authorization: AuthorizationRef) throws {
        try "com.pmeir99.mac-proxy-filter.disable".withCString { name in
            var definition: CFDictionary?
            if AuthorizationRightGet(name, &definition) != errAuthorizationSuccess {
                let rule: [String: Any] = ["class": "user", "group": "admin",
                    "authenticate-user": true, "shared": false, "timeout": 0,
                    "allow-root": false]
                guard AuthorizationRightSet(authorization, name, rule as CFDictionary,
                    "Approve stopping Mac Proxy Filter" as CFString, nil, nil) == errAuthorizationSuccess else {
                    throw failure("macOS could not register the administrator approval requirement.")
                }
            }
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            let result = withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights], nil)
            }
            guard result == errAuthorizationSuccess else {
                throw failure("Administrator approval was cancelled or denied. Routing was left in place.")
            }
        }
    }

    static func awaitRestoredRouting() throws {
        // Wait for configd to publish the effective change before closing the listener.
        for _ in 0..<100 {
            if let proxies = SCDynamicStoreCopyProxies(nil) as? [String: Any],
               !(proxies[enabled] as? Int == 1 && owns(proxies[address])) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw failure("macOS still reports the filter proxy. The listener is staying open. Retry Restore routing.")
    }

    static func apply(enable: Bool) throws -> String {
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else { throw failure("macOS authorization was unavailable.") }
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        if !enable { try approveDisable(authorization) }
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "Mac Proxy Filter" as CFString, nil, authorization),
              SCPreferencesLock(prefs, true) else { throw failure("Network settings are locked or approval was declined.") }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            throw failure("Could not read network services.")
        }
        let refreshed = url + "?revision=" + UUID().uuidString
        var changed = 0
        var configured = 0
        var skipped = [String]()
        for service in services {
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { continue }
            var config = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
            let ours = owns(config[address])
            if enable {

                let competing = ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoDiscoveryEnable","FTPEnable","RTSPEnable"]
                if (!ours && config[marker] != nil) || competing.contains(where: { config[$0] as? Int == 1 }) ||
                    (!ours && config[enabled] as? Int == 1) {
                    skipped.append((SCNetworkServiceGetName(service) as String?) ?? "Unnamed service")
                    continue
                }
                var previous = [String: Any]()
                previous[enabled] = config[enabled]
                previous[address] = config[address]
                if config[marker] == nil { config[marker] = previous }
                config[enabled] = 1
                config[address] = refreshed
                configured += 1
            } else {
                guard ours else { continue }
                guard let previous = config[marker] as? [String: Any] else {
                    throw failure("Previous routing information is missing. Review this network service in System Settings.")
                }
                config[enabled] = previous[enabled]
                config[address] = previous[address]
                config.removeValue(forKey: marker)
            }
            guard SCNetworkProtocolSetConfiguration(proto, config as CFDictionary) else {
                throw failure("macOS rejected the network settings.")
            }
            changed += 1
        }
        if enable && configured == 0 {
            throw failure("No network service could be configured. Check existing proxy settings on " +
                          (skipped.isEmpty ? "this Mac" : skipped.joined(separator: ", ")) + ".")
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

    // Prove that the selected hostname completes TLS through our listener using
    // native system trust. Do not follow redirects or send browser credentials.
    struct CertificateRejected: LocalizedError {
        let host: String
        var errorDescription: String? { "macOS rejected the HTTPS certificate for " + host + "." }
    }

    static func checkHTTPS(host: String) throws {
        let task = Process()
        let output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["--disable", "--silent", "--head", "--connect-timeout", "5", "--max-time", "10",
                          "--proxy", "http://127.0.0.1:17862", "--noproxy", "", "--output", "/dev/null",
                          "--write-out", "%{http_connect} %{http_code}", "https://" + host + "/"]
        task.environment = ["PATH": "/usr/bin:/bin"]
        task.standardOutput = output
        try task.run()
        task.waitUntilExit()
        let response = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if task.terminationStatus == 60 {
            throw CertificateRejected(host: host)
        }
        let codes = response.split(separator: " ")
        guard task.terminationStatus == 0, codes.count == 2, codes[0] == "200",
              let status = Int(codes[1]), (200..<500).contains(status) else {
            throw failure("HTTPS check failed for " + host + " (curl " + String(task.terminationStatus) + ", HTTP " + response + "). Restore previous routing if already enabled.")
        }
    }

    static func trust(_ certificate: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["add-trusted-cert", "-r", "trustRoot", "-p", "ssl", "-k", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains/login.keychain-db").path, certificate.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw failure("Certificate trust could not be approved. Network routing was left as configured.") }
    }
}
