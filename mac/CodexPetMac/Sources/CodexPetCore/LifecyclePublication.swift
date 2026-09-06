import Foundation

/// The effects a publication may have after both its ordering and liveness
/// have been checked. Rejected input never replaces the accepted snapshot.
public enum LifecyclePublicationAction: Equatable, Sendable {
    case accept
    case recover
    case unchanged
    case rejectOrder(StatePublicationOrderDecision, acceptedFreshness: StatePublicationFreshness)
    case rejectFreshness(StatePublicationFreshness)
}

public struct LifecyclePublicationUpdate: Equatable, Sendable {
    public let action: LifecyclePublicationAction
    public let acceptedSnapshot: CurrentState?
    public let temporaryPreview: TemporaryStatePreviewPolicy
    public let relinquishedPreview: PetState?
}

/// Resolves publication acceptance and preview ownership without reading files,
/// clocks, or playback state. The caller applies UI/player effects afterward.
public enum LifecyclePublicationPolicy {
    public static func evaluate(
        lastAccepted: CurrentState?,
        incoming: CurrentState,
        now: TimeInterval,
        publisherIsLive: Bool,
        currentState: PetState,
        temporaryPreview: TemporaryStatePreviewPolicy,
        freshnessPolicy: StateFreshnessPolicy = .production
    ) -> LifecyclePublicationUpdate {
        let ordering = StatePublicationOrderPolicy.decide(
            lastAccepted: lastAccepted,
            incoming: incoming
        )
        let isDuplicate = ordering == .rejectEqualRevisionDuplicate
            || ordering == .rejectLegacyTimestampDuplicate

        if !ordering.shouldAccept && !isDuplicate {
            // A rejected rollback cannot renew the accepted publication's
            // liveness. Health reads must eventually expire that snapshot even
            // when disk keeps returning fresh but inadmissible publications.
            let acceptedFreshness = lastAccepted.map {
                freshnessPolicy.freshness(of: $0, now: now)
            } ?? .stale
            return LifecyclePublicationUpdate(
                action: .rejectOrder(ordering, acceptedFreshness: acceptedFreshness),
                acceptedSnapshot: lastAccepted,
                temporaryPreview: temporaryPreview,
                relinquishedPreview: nil
            )
        }

        let freshness = freshnessPolicy.freshness(of: incoming, now: now)
        guard freshness == .fresh else {
            return LifecyclePublicationUpdate(
                action: .rejectFreshness(freshness),
                acceptedSnapshot: lastAccepted,
                temporaryPreview: temporaryPreview,
                relinquishedPreview: nil
            )
        }

        // A health read of the same immutable snapshot is normally a
        // no-op. If the path disappeared or was malformed in between,
        // however, the identical snapshot is authoritative recovery and
        // must restore live presentation without consuming a new cursor.
        if isDuplicate && publisherIsLive && currentState == incoming.state {
            return LifecyclePublicationUpdate(
                action: .unchanged,
                acceptedSnapshot: lastAccepted,
                temporaryPreview: temporaryPreview,
                relinquishedPreview: nil
            )
        }

        var updatedPreview = temporaryPreview
        let previousPreview = updatedPreview.previewState
        let outcome = updatedPreview.receiveLifecycleState(incoming.state)
        let relinquishedPreview: PetState?
        switch outcome {
        case .presentingPreview:
            relinquishedPreview = nil
        case .presentingLifecycle:
            relinquishedPreview = previousPreview
        }
        return LifecyclePublicationUpdate(
            action: isDuplicate ? .recover : .accept,
            acceptedSnapshot: isDuplicate ? lastAccepted : incoming,
            temporaryPreview: updatedPreview,
            relinquishedPreview: relinquishedPreview
        )
    }
}
