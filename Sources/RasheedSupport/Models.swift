import Foundation
import RasheedCore

public typealias Contact = RasheedCore.Contact
public typealias ContactAttribute = RasheedCore.ContactAttribute
public typealias AttributeValue = RasheedCore.AttributeValue
public typealias Language = RasheedCore.Language
public typealias WorkspaceBranding = RasheedCore.WorkspaceBranding
public typealias RasheedSnapshot = RasheedCore.Snapshot
public typealias RasheedClientError = RasheedCore.ClientError
public typealias InboxSnapshot = RasheedCore.InboxSnapshot
public typealias InboxTarget = RasheedCore.InboxTarget
public typealias InboxLocalFile = RasheedCore.InboxLocalFile
public typealias PushPlatform = RasheedCore.PushPlatform
public typealias PushStatus = RasheedCore.PushStatus
public typealias PushScope = RasheedCore.PushScope
public typealias PushSnapshot = RasheedCore.PushSnapshot

/// The APNs environment specified by the host app's signing entitlement.
public enum RasheedAPNsEnvironment: Sendable {
    case sandbox
    case production
}

public struct SignedIdentity: Codable, Sendable, Equatable {
    public let payload: String
    public let signature: String
    public let expiresAt: Int64

    public init(payload: String, signature: String, expiresAt: Int64) {
        self.payload = payload
        self.signature = signature
        self.expiresAt = expiresAt
    }

    var coreValue: RasheedCore.SignedIdentity {
        RasheedCore.SignedIdentity(payload: payload, signature: signature, expiresAt: expiresAt)
    }
}

extension RasheedCore.WorkspaceBranding {
    public var logoURL: URL? { logoUrl.flatMap { URL(string: $0) } }
}

extension RasheedCore.ClientError {
    var uncertain: Bool { self == .OutcomeUnknown || self == .Canceled }

    static func wrapping(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return .Canceled }
        return .Failed(reason: error.localizedDescription)
    }
}
