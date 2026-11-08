import Foundation

/// Decides when a note hover preview may appear.
///
/// The page overlay owns the tracking area, the window and the card, but every
/// lifetime rule lives here as pure state so the timing races can be tested
/// without AppKit: a queued preview must not fire after the page scrolled away
/// from the pointer, a click that opens a note must keep the card away until
/// the pointer leaves the sticker, and moving inside one sticker is still one
/// dwell rather than a fresh delay on every mouse-moved event.
public struct NoteHoverLifecycle: Sendable {

    public enum Action: Equatable, Sendable {
        case none
        /// Start the dwell delay. `token` is handed back to `delayFinished` so
        /// a cancelled delay can never display a stale card.
        case schedule(markerID: ObjectIdentifier, token: Int)
        /// A queued delay was invalidated; there is no card to remove.
        case cancel
        case show(markerID: ObjectIdentifier)
        case hide
    }

    private enum Suppression: Sendable {
        case none
        case marker(ObjectIdentifier)
        /// A click arrived from a path that could not name its marker.
        case all
    }

    public private(set) var visibleMarkerID: ObjectIdentifier?
    public private(set) var pendingMarkerID: ObjectIdentifier?

    private var suppression: Suppression = .none
    private var token = 0

    public init() {}

    // MARK: - Input

    /// - Parameters:
    ///   - markerID: the sticker under the pointer, or nil once the pointer is
    ///     no longer over any sticker on this page.
    ///   - isPressed: a marker drag is in progress.
    public mutating func pointerMoved(to markerID: ObjectIdentifier?, isPressed: Bool) -> Action {
        guard !isPressed else { return hide() }
        guard let markerID else {
            // Leaving all stickers re-arms the one whose note was just opened.
            suppression = .none
            return hide()
        }
        switch suppression {
        case .all:
            return .none
        case .marker(let suppressed) where suppressed == markerID:
            return hide()
        case .marker, .none:
            break
        }
        if visibleMarkerID == markerID { return .none }
        // Moving inside one sticker is still a dwell: only a new target
        // restarts the clock.
        if pendingMarkerID == markerID { return .none }
        return schedule(markerID)
    }

    public mutating func pointerExited() -> Action {
        suppression = .none
        return hide()
    }

    /// Scrolling moves the page under a stationary pointer.
    /// - Parameter pointerAt: the sticker now under that pointer.
    public mutating func scrolled(pointerAt markerID: ObjectIdentifier?) -> Action {
        if let visibleMarkerID, markerID != visibleMarkerID {
            return hide()
        }
        let hadPending = pendingMarkerID != nil
        cancelPending()
        return hadPending ? .cancel : .none
    }

    /// - Parameter pointerStillOnMarker: re-read from the window when the delay
    ///   ends; scrolling during the dwell can have moved the page away.
    public mutating func delayFinished(
        markerID: ObjectIdentifier,
        token: Int,
        pointerStillOnMarker: Bool
    ) -> Action {
        guard token == self.token, pendingMarkerID == markerID else { return .none }
        cancelPending()
        guard pointerStillOnMarker else { return .cancel }
        visibleMarkerID = markerID
        return .show(markerID: markerID)
    }

    /// A note popover opened. `markerID` is nil for the PDFView fallback paths
    /// that cannot identify the sticker from the click.
    public mutating func noteActivated(markerID: ObjectIdentifier?) -> Action {
        let target = markerID ?? visibleMarkerID ?? pendingMarkerID
        if let target {
            suppression = .marker(target)
        } else if visibleMarkerID != nil || pendingMarkerID != nil {
            // Only the overlay that actually had a card needs a blanket
            // suppression; the other page overlays stay unaffected.
            suppression = .all
        }
        return hide()
    }

    /// The marker set changed: refresh a card whose note was edited, or drop
    /// one whose note was deleted.
    public mutating func markersChanged(containing ids: Set<ObjectIdentifier>) -> Action {
        if let pendingMarkerID, !ids.contains(pendingMarkerID) {
            cancelPending()
        }
        guard let visibleMarkerID else { return .none }
        guard ids.contains(visibleMarkerID) else { return hide() }
        return .show(markerID: visibleMarkerID)
    }

    /// Any hard dismissal: pointer down, drag, resize, window change.
    public mutating func hide() -> Action {
        cancelPending()
        visibleMarkerID = nil
        return .hide
    }

    // MARK: - State

    private mutating func schedule(_ markerID: ObjectIdentifier) -> Action {
        cancelPending()
        visibleMarkerID = nil
        pendingMarkerID = markerID
        return .schedule(markerID: markerID, token: token)
    }

    private mutating func cancelPending() {
        pendingMarkerID = nil
        token &+= 1
    }
}
