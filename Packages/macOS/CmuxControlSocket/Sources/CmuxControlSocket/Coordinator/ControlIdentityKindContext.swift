public import Foundation

/// The seam through which ``ControlCommandCoordinator`` asks the app what kind
/// of object a raw UUID names.
///
/// A `kind:N` ref states its own kind, but the protocol also accepts raw UUID
/// strings, which carry none. Without an answer here the coordinator can only
/// consult the handle registry's mint history, and that is not a sound oracle:
/// dock-hosted objects may not be minted yet, and
/// ``ControlHandleRegistry/removeRef(kind:uuid:)`` erases what it knew. Live
/// topology is authoritative, so a surface UUID handed to `group_id` is
/// rejected rather than routed
/// (https://github.com/manaflow-ai/cmux/issues/9424).
///
/// Deliberately one kind per call rather than a classify-everything sweep: the
/// coordinator asks about the kind a parameter expects and stops at the first
/// match, so the common case (a valid `workspace_id`) costs a single lookup on
/// the main actor instead of walking every window, workspace, group, pane and
/// surface. Answers are memoized per request by the coordinator.
@MainActor
public protocol ControlIdentityKindContext: AnyObject {
    /// Whether an identifier names an object of one specific kind in live app
    /// topology.
    ///
    /// - Parameters:
    ///   - uuid: The identifier to test.
    ///   - kind: The single kind to test for.
    /// - Returns: `true` / `false` from live topology, or `nil` when this
    ///   conformer cannot classify at all, in which case the coordinator falls
    ///   back to the handle registry.
    func controlIdentity(_ uuid: UUID, isOfKind kind: ControlHandleKind) -> Bool?
}

extension ControlIdentityKindContext {
    /// Conformers that cannot classify opt out; the coordinator then falls back
    /// to the handle registry's mint history.
    public func controlIdentity(_ uuid: UUID, isOfKind kind: ControlHandleKind) -> Bool? {
        nil
    }
}
