import AgentKit
import FoundationModels

/// Where the assistant's model runs for a turn. The server writes the
/// instructions and approves every action whichever source answers.
public enum AgentModelSource: String, Sendable, Hashable, CaseIterable, Codable {
    /// Our server models (OpenRouter). The tested defaults, on any device.
    case server
    /// Apple's on-device model. Free, private, and the only choice offline. 4K tokens of context.
    case appleOnDevice
    /// Apple's Private Cloud Compute model. Longer context and reasoning, no model cost to
    /// the developer. Needs Apple's managed entitlement, and each person has a daily limit.
    case applePrivateCloud

    public var displayName: String {
        switch self {
        case .server: "Good Machines"
        case .appleOnDevice: "Apple on-device"
        case .applePrivateCloud: "Apple Private Cloud"
        }
    }

    /// Whether this source can answer on this device right now, and if not, why.
    public var status: Status {
        switch self {
        case .server:
            return .available
        case .appleOnDevice:
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unavailable("This device doesn't support Apple Intelligence.")
            case .unavailable(.appleIntelligenceNotEnabled): return .unavailable("Turn on Apple Intelligence in Settings to use this.")
            case .unavailable(.modelNotReady): return .unavailable("Apple's model is still downloading.")
            case .unavailable: return .unavailable("Apple's on-device model isn't available.")
            }
        case .applePrivateCloud:
            let model = PrivateCloudComputeLanguageModel()
            switch model.availability {
            case .available:
                return model.quotaUsage.isLimitReached ? .unavailable("You've reached today's Private Cloud Compute limit.") : .available
            case .unavailable(.deviceNotEligible): return .unavailable("This device can't use Private Cloud Compute.")
            case .unavailable: return .unavailable("Private Cloud Compute isn't ready yet.")
            }
        }
    }

    public enum Status: Sendable, Hashable {
        case available
        case unavailable(String)

        public var isAvailable: Bool { self == .available }
    }

    /// The Foundation Models model for an Apple source.
    var languageModel: (any LanguageModel)? {
        switch self {
        case .server: nil
        case .appleOnDevice: SystemLanguageModel.default
        case .applePrivateCloud: PrivateCloudComputeLanguageModel()
        }
    }

    /// How much the server packs into the instructions for this source.
    var budget: LocalBudget { self == .applePrivateCloud ? .full : .compact }

    /// The model name recorded with a turn.
    var modelName: String {
        switch self {
        case .server: "server"
        case .appleOnDevice: "apple/on-device"
        case .applePrivateCloud: "apple/private-cloud-compute"
        }
    }
}
