import Foundation

/// The seam between a caller and a control transport.
///
/// Exists so `VMHostProxy` can be tested against a fake without opening a socket,
/// and so a future XPC or in-process transport can replace the unix socket
/// without touching the proxy or the registry.
public protocol ControlChannel: Sendable {
    func send(_ request: VMControlRequest) async throws -> VMControlResponse
}
