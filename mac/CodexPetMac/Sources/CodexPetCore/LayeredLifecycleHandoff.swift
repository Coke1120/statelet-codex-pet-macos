import Foundation

public struct LayeredLifecycleHandoff: Equatable, Sendable {
    public enum LowerLayer: Equatable, Sendable {
        case outgoing(PetState)
        case destination(PetState)
    }

    public enum Action: Equatable, Sendable {
        case none
        case revealTransition
        case startDestinationPreroll(PetState)
        case revealDestination(PetState)
        case finish(PetState)
        case fallBack(PetState)
    }

    public enum VisibleLayer: Equatable, Sendable {
        case outgoing(PetState)
        case destination(PetState)
        case transitionForeground
    }

    public let id: UInt64
    public let source: PetState
    public let destination: PetState
    public private(set) var lowerLayer: LowerLayer
    public private(set) var transitionVisible = false
    public private(set) var transitionReady = false
    /// The destination has a display-ready frame, but remains hidden until
    /// the foreground transition completes.
    public private(set) var destinationReady = false
    public private(set) var destinationPrerollStarted = false
    public private(set) var transitionEnded = false

    public init(id: UInt64, source: PetState, destination: PetState) {
        self.id = id
        self.source = source
        self.destination = destination
        lowerLayer = .outgoing(source)
    }

    public mutating func transitionBecameReady(id callbackID: UInt64) -> Action {
        guard callbackID == id, !transitionReady else { return .none }
        transitionReady = true
        transitionVisible = true
        return .revealTransition
    }

    public mutating func destinationPrerollCueReached(id callbackID: UInt64) -> Action {
        guard callbackID == id, !destinationPrerollStarted else { return .none }
        destinationPrerollStarted = true
        return .startDestinationPreroll(destination)
    }

    public mutating func destinationBecameReady(id callbackID: UInt64) -> Action {
        guard callbackID == id,
              destinationPrerollStarted,
              !destinationReady else { return .none }
        destinationReady = true
        if transitionEnded {
            lowerLayer = .destination(destination)
            transitionVisible = false
            return .finish(destination)
        }
        return .none
    }

    public mutating func transitionFinished(id callbackID: UInt64) -> Action {
        guard callbackID == id else { return .none }
        transitionEnded = true
        guard destinationReady else { return .none }
        lowerLayer = .destination(destination)
        transitionVisible = false
        return .finish(destination)
    }

    public mutating func transitionFailed(id callbackID: UInt64) -> Action {
        guard callbackID == id else { return .none }
        transitionVisible = false
        guard destinationReady else { return .fallBack(destination) }
        lowerLayer = .destination(destination)
        return .finish(destination)
    }

    public mutating func destinationFailed(id callbackID: UInt64) -> Action {
        guard callbackID == id else { return .none }
        destinationReady = false
        destinationPrerollStarted = false
        lowerLayer = .outgoing(source)
        return .none
    }

    public var visibleLayers: [VisibleLayer] {
        let lower: VisibleLayer = switch lowerLayer {
        case let .outgoing(state): .outgoing(state)
        case let .destination(state): .destination(state)
        }
        return transitionVisible ? [lower, .transitionForeground] : [lower]
    }

    public var preservesVisibleContent: Bool {
        !visibleLayers.isEmpty
    }
}

public enum LayeredLifecycleHandoffPolicy {
    /// Begin destination pre-roll while at least this much of the transparent
    /// foreground remains visible for distinct-state handoffs. The destination
    /// layer stays hidden until the foreground completes.
    /// Same-state clip-end handoffs bypass this delay and start immediately
    /// once the transition foreground is ready. Short distinct-state clips use
    /// half their duration, which keeps the cue deterministic and strictly
    /// before the end.
    public static let maximumOverlap: TimeInterval = 0.35

    public static func destinationPrerollTime(duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, duration - min(maximumOverlap, duration / 2))
    }
}
