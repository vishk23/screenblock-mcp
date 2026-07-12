import Foundation

/// Single source of truth for the user-facing product name.
/// Change this ONE value to rebrand everything on iOS. (Bundle IDs are internal
/// plumbing and stay as-is.)
enum Brand {
    static let name = "ScreenCP"
    static let shieldTitle = "Blocked by \(name)"
}
