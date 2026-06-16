import PJSIP

/// SIP push (RFC 8599) contact-URI parameters for an account.
///
/// PJSIP appends a free-form parameter string to the registration `Contact` so the SIP
/// server can wake the device via APNs. The standard APNs form is
/// `;pn-provider=apns;pn-param={teamID}.{bundleID}.voip;pn-prid={token}`, but the value is
/// deliberately a **raw string** here: deviated scenarios (e.g. a silent-push topic that
/// drops the `.voip` suffix and carries a regular APNs device token) just pass a different
/// string. Use ``apns(teamID:bundleID:token:pushType:scope:)`` for the common case.
public struct PushConfiguration: Sendable, Equatable {
    /// Which outgoing messages carry the parameters.
    public enum Scope: Sendable, Equatable {
        /// Attach to REGISTER only (`pjsua_acc_config.reg_contact_uri_params`). Most apps.
        case registerOnly
        /// Attach to all requests (`pjsua_acc_config.contact_uri_params`).
        case allRequests
    }

    /// The raw parameter string, including the leading `;` (e.g. `;pn-provider=apns;...`).
    public var params: String
    /// Where to attach ``params``.
    public var scope: Scope

    public init(params: String, scope: Scope = .registerOnly) {
        self.params = params
        self.scope = scope
    }

    /// Build the standard RFC 8599 APNs parameter string.
    ///
    /// - Parameters:
    ///   - teamID: Apple Developer team ID.
    ///   - bundleID: app bundle identifier.
    ///   - token: the push token (`pn-prid`).
    ///   - pushType: the `pn-param` suffix; `"voip"` for PushKit VoIP pushes. Pass a
    ///     different value (or build ``init(params:scope:)`` directly) for silent pushes.
    ///   - scope: where to attach the parameters; defaults to REGISTER-only.
    public static func apns(
        teamID: String,
        bundleID: String,
        token: String,
        pushType: String = "voip",
        scope: Scope = .registerOnly
    ) -> PushConfiguration {
        let param = pushType.isEmpty ? "\(teamID).\(bundleID)" : "\(teamID).\(bundleID).\(pushType)"
        let params = ";pn-provider=apns;pn-param=\(param);pn-prid=\(token)"
        return PushConfiguration(params: params, scope: scope)
    }
}
