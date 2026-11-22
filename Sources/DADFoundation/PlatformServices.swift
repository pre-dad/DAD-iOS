/// `restricted` is a limit the person cannot lift in the app (Screen Time, a managed device); unlike
/// `denied`, sending them to Settings would not help.
public enum PermissionState: Sendable { case notRequested, allowed, denied, restricted, unavailable }

public protocol CameraPermission: Sendable {
    func status() async -> PermissionState
    func request() async -> PermissionState
}
