import Foundation
import Security

struct ApplicationIntegrityIssue: Equatable {
  let status: OSStatus

  var message: String {
    KeychainFailureMessage.message(for: status)
  }
}

enum ApplicationIntegrity {
  static func currentIssue(bundleURL: URL = Bundle.main.bundleURL) -> ApplicationIntegrityIssue? {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      return ApplicationIntegrityIssue(status: createStatus)
    }

    let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
    let validationStatus = SecStaticCodeCheckValidity(staticCode, flags, nil)
    guard validationStatus != errSecSuccess else { return nil }
    return ApplicationIntegrityIssue(status: validationStatus)
  }
}

enum KeychainFailureMessage {
  static let invalidBundleStatus: OSStatus = -67028
  static let missingEntitlementStatus: OSStatus = -34018
  static let invalidOwnerStatus: OSStatus = -25244

  static func message(for status: OSStatus) -> String {
    switch status {
    case invalidBundleStatus:
      return
        "This copy of Magic Switch was changed after signing. Quit it, transfer the ZIP or DMG "
        + "(never the .app), unpack it locally, move it to Applications, and try again. "
        + "(Error -67028.)"
    case missingEntitlementStatus:
      return "This copy of Magic Switch cannot access Keychain because its signing permissions are "
        + "invalid. Reinstall a signed ZIP or DMG and try again. (Error -34018.)"
    case invalidOwnerStatus:
      return "This pairing key belongs to an older Magic Switch identity and cannot be changed. "
        + "Install the latest version to reset pairing safely. (Error -25244.)"
    default:
      return "Magic Switch could not access Keychain (error \(status)). Quit the app, reopen it "
        + "from Applications, and try again."
    }
  }
}
