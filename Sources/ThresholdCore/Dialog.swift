import Foundation

/// The user-facing UI (swiftDialog). The Runner drives it; the implementation lives elsewhere.
public protocol DialogPresenting: AnyObject {
    /// Shows the full-screen blur listing the items. Throwing means the UI could not be shown.
    func showBlur(items: [Item], global: GlobalConfig) throws
    func update(index: Int, state: ItemState, detail: String?)
    /// Shows a brief summary, then closes the blur.
    func finish(success: Bool, global: GlobalConfig)
    /// A small non-blurred window for an install left running past the cap.
    func showStillRunning(displayName: String)
    func closeStillRunning()
}
