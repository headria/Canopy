import CryptoKit
import Foundation
import Security

/// Scope remembered permission requests to the code identity macOS recognizes.
/// Certificate requirements survive rebuilds; ad hoc requirements contain a cdhash.
enum AppSigningIdentity {
    static var permissionScope: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        var data: CFData?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyData(requirement, [], &data) == errSecSuccess, let data else { return nil }
        return SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
    }
}
