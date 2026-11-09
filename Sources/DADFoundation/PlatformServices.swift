public enum PermissionState: Sendable { case notRequested, allowed, denied, unavailable }

public protocol CameraPermission: Sendable {
    func status() async -> PermissionState
    func request() async -> PermissionState
}
