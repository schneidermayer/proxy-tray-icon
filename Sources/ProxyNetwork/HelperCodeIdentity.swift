import Foundation
import Security

/// Bind both ends of the privileged connection to this build's Developer ID
/// team. The bundle identifier alone is not an authentication boundary.
public enum HelperCodeIdentity {
    public static func requirement(for identifier: String) throws -> String {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let team = information[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty,
              team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
              identifier.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46 || $0 == 45 }) else {
            throw failure("ProxyTray and its network helper must be signed with a valid Developer ID Application certificate.")
        }
        let requirement = "anchor apple generic and identifier \"\(identifier)\" " +
            "and certificate 1[field.1.2.840.113635.100.6.2.6] exists " +
            "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists " +
            "and certificate leaf[subject.OU] = \"\(team)\" " +
            "and !entitlement[\"com.apple.security.get-task-allow\"] exists " +
            "and !entitlement[\"com.apple.security.cs.disable-library-validation\"] exists " +
            "and !entitlement[\"com.apple.security.cs.allow-dyld-environment-variables\"] exists " +
            "and !entitlement[\"com.apple.security.cs.disable-executable-page-protection\"] exists"
        var parsed: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess else {
            throw failure("Could not validate the network helper's signing requirement.")
        }
        return requirement
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "ProxyTray.NetworkHelper.Signing", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
