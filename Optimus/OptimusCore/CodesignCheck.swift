import Foundation
import Security

/// Verifies an XPC peer is code-signed with the expected identifier before the helper
/// accepts its connection. Works even under ad-hoc/Personal-Team signing (no paid Apple
/// Developer Program membership needed) since Xcode's automatic signing still embeds the
/// app's `CFBundleIdentifier` as the codesign identifier by default. This guards against
/// some unrelated process connecting to the helper's Mach service; it is not equivalent
/// to a full Team-ID chain-of-trust check (that would need a real, non-ad-hoc certificate).
enum CodesignCheck {
    static func isValidPeer(pid: pid_t, expectedIdentifier: String) -> Bool {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else {
            return false
        }

        // SecCode is a valid input wherever SecStaticCode is expected (Security.framework's
        // C API treats SecCode as a subtype of SecStaticCode); the Swift overlay doesn't
        // expose that relationship, so bridge explicitly.
        let staticCode = unsafeBitCast(code, to: SecStaticCode.self)
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        else {
            return false
        }

        return identifier == expectedIdentifier
    }
}
