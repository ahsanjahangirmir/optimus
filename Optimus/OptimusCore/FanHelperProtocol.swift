import Foundation

/// Mach service name the LaunchDaemon plist registers and the app connects to.
public let kFanHelperMachServiceName = "com.ajm.Optimus.FanHelper"

/// Expected code-signing identifier of the main app, checked by the helper before it
/// accepts an XPC connection (see `CodesignCheck`).
public let kOptimusBundleIdentifier = "com.ajm.Optimus"

/// XPC protocol between the unprivileged `Optimus` app and the root-privileged
/// `OptimusFanHelper` daemon. Deliberately minimal — root is scoped to exactly this one
/// operation (writing fan speed targets to the SMC); everything else the app does
/// (including SMC reads) runs unprivileged in the main app process.
@objc public protocol FanHelperProtocol {
    func version(withReply reply: @escaping (String) -> Void)
    func setFanTarget(id: Int, rpm: Double, withReply reply: @escaping (Bool, String?) -> Void)
    func setFanAuto(id: Int, withReply reply: @escaping (Bool, String?) -> Void)
}
