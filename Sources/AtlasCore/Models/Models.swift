import Foundation

public enum NavigationSection: String, CaseIterable, Identifiable, Codable {
    case overview = "Overview"
    case assistant = "Assistant"
    case projects = "Projects"
    case notes = "Notes & Search"
    case business = "Business"
    case calendar = "Calendar & Tasks"
    case board = "Board"
    case journal = "Journal"
    case canvas = "Canvas"
    case finances = "Finances"
    case cinema = "Cinema"
    case automations = "Automations"
    case connections = "Connections"
    case activity = "Activity"
    case settings = "Settings"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .overview: return "circle.hexagongrid"
        case .assistant: return "sparkles"
        case .projects: return "folder"
        case .notes: return "doc.text"
        case .business: return "briefcase"
        case .calendar: return "calendar"
        case .board: return "rectangle.split.3x1"
        case .journal: return "book.closed"
        case .canvas: return "square.on.square.dashed"
        case .finances: return "creditcard"
        case .cinema: return "play.tv"
        case .automations: return "bolt"
        case .connections: return "link"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

public enum RiskTier: String, Codable, CaseIterable {
    case readOnly = "Read-Only"
    case reversible = "Reversible Local Action"
    case external = "External Action"
    case destructive = "Destructive or Financial Action"

    public var badgeColorHex: String {
        switch self {
        case .readOnly: return "#34C759"
        case .reversible: return "#0A84FF"
        case .external: return "#FF9F0A"
        case .destructive: return "#FF3B30"
        }
    }
}

public enum HermesAuthState: String, Codable {
    case unknown = "Unknown / Not Verified"
    case notInstalled = "Not Installed"
    case notConfigured = "Not Configured"
    case loginRequired = "Login Required"
    case authenticated = "Authenticated"
    case authenticationExpired = "Authentication Expired"
    case checkFailed = "Check Failed"
}

public enum ProjectType: String, Codable, CaseIterable {
    case swiftPackage = "Swift Package"
    case nodeProject = "Node.js Project"
    case pythonProject = "Python Project"
    case xcodeProject = "Xcode Project"
    case clientWebsite = "Client Website"
    case monorepo = "Monorepo"
    case monorepoApp = "Monorepo Application"
    case gitRepository = "Git Repository"
    case folder = "Folder (Non-Git)"
}

public struct AtlasCommandResult: Codable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: Double
    public let isCancelled: Bool
    public let launchError: String?

    public var isSuccess: Bool {
        return exitCode == 0 && !isCancelled && launchError == nil
    }

    public init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        duration: Double = 0.0,
        isCancelled: Bool = false,
        launchError: String? = nil
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
        self.isCancelled = isCancelled
        self.launchError = launchError
    }
}

public struct AtlasStructuredAction: Codable, Hashable {
    public let toolIdentifier: String
    public let targetPath: String
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectory: String?
    public let riskTier: RiskTier

    public init(
        toolIdentifier: String,
        targetPath: String,
        executablePath: String,
        arguments: [String],
        workingDirectory: String? = nil,
        riskTier: RiskTier
    ) {
        self.toolIdentifier = toolIdentifier
        self.targetPath = targetPath
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.riskTier = riskTier
    }
}

public struct AtlasProject: Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public var projectType: ProjectType
    public var isGitRepository: Bool
    public var gitRootPath: String?
    public var isRepositoryRoot: Bool
    public var isNestedApplication: Bool
    public var gitBranch: String
    public var gitStatus: String
    public var uncommittedChangesCount: Int
    public var stagedFiles: [String]
    public var modifiedFiles: [String]
    public var untrackedFiles: [String]
    public var deletedFiles: [String]
    public var conflictedFiles: [String]
    public var recentCommits: [String]
    public var availableScripts: [String]
    public var buildStatus: String
    public var deploymentStatus: String
    public var isCloudConnected: Bool
    public var lastModified: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        path: String,
        projectType: ProjectType = .gitRepository,
        isGitRepository: Bool = true,
        gitRootPath: String? = nil,
        isRepositoryRoot: Bool = true,
        isNestedApplication: Bool = false,
        gitBranch: String = "main",
        gitStatus: String = "Clean",
        uncommittedChangesCount: Int = 0,
        stagedFiles: [String] = [],
        modifiedFiles: [String] = [],
        untrackedFiles: [String] = [],
        deletedFiles: [String] = [],
        conflictedFiles: [String] = [],
        recentCommits: [String] = [],
        availableScripts: [String] = [],
        buildStatus: String = "Untested",
        deploymentStatus: String = "No deployment configuration detected",
        isCloudConnected: Bool = false,
        lastModified: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.projectType = projectType
        self.isGitRepository = isGitRepository
        self.gitRootPath = gitRootPath
        self.isRepositoryRoot = isRepositoryRoot
        self.isNestedApplication = isNestedApplication
        self.gitBranch = gitBranch
        self.gitStatus = gitStatus
        self.uncommittedChangesCount = uncommittedChangesCount
        self.stagedFiles = stagedFiles
        self.modifiedFiles = modifiedFiles
        self.untrackedFiles = untrackedFiles
        self.deletedFiles = deletedFiles
        self.conflictedFiles = conflictedFiles
        self.recentCommits = recentCommits
        self.availableScripts = availableScripts
        self.buildStatus = buildStatus
        self.deploymentStatus = deploymentStatus
        self.isCloudConnected = isCloudConnected
        self.lastModified = lastModified
    }
}

public struct AtlasVault: Identifiable, Codable, Hashable {
    public let id: String
    public let name: String
    public let path: String
    public var noteCount: Int
    public var isDefault: Bool
    public var lastIndexed: Date?

    public init(
        id: String,
        name: String,
        path: String,
        noteCount: Int = 0,
        isDefault: Bool = false,
        lastIndexed: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.noteCount = noteCount
        self.isDefault = isDefault
        self.lastIndexed = lastIndexed
    }
}

public struct AtlasNote: Identifiable, Codable, Hashable {
    public let id: String
    public let title: String
    public let path: String
    public let vaultName: String
    public let relativePath: String
    public let tags: [String]
    public let snippet: String
    public let backlinksCount: Int
    public let modifiedDate: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        path: String,
        vaultName: String,
        relativePath: String,
        tags: [String] = [],
        snippet: String,
        backlinksCount: Int = 0,
        modifiedDate: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.vaultName = vaultName
        self.relativePath = relativePath
        self.tags = tags
        self.snippet = snippet
        self.backlinksCount = backlinksCount
        self.modifiedDate = modifiedDate
    }
}

public struct AtlasActivity: Identifiable, Codable {
    public let id: String
    public let timestamp: Date
    public let initiator: String
    public let missionId: String?
    public let toolName: String
    public let target: String
    public let actionDescription: String
    public let riskTier: RiskTier
    public let result: String
    public let durationSeconds: Double
    public let approvalStatus: String
    public let touchedFiles: [String]

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        initiator: String = "Hermes Assistant",
        missionId: String? = nil,
        toolName: String,
        target: String,
        actionDescription: String,
        riskTier: RiskTier = .readOnly,
        result: String = "Success",
        durationSeconds: Double = 0.5,
        approvalStatus: String = "Auto-Approved",
        touchedFiles: [String] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.initiator = initiator
        self.missionId = missionId
        self.toolName = toolName
        self.target = target
        self.actionDescription = actionDescription
        self.riskTier = riskTier
        self.result = result
        self.durationSeconds = durationSeconds
        self.approvalStatus = approvalStatus
        self.touchedFiles = touchedFiles
    }
}

public struct AtlasApprovalRequest: Identifiable, Codable {
    public let id: String
    public let timestamp: Date
    public let title: String
    public let details: String
    public let riskTier: RiskTier
    public let requestedBy: String
    public let actionPayload: String
    public let structuredAction: AtlasStructuredAction?
    public var status: ApprovalStatus
    public var executionCount: Int
    public var executedAt: Date?
    public var executionOutput: String?

    public enum ApprovalStatus: String, Codable {
        case pending = "Pending"
        case approved = "Approved"
        case rejected = "Rejected"
        case executed = "Executed"
        case failed = "Failed"
    }

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        title: String,
        details: String,
        riskTier: RiskTier,
        requestedBy: String = "Hermes Assistant",
        actionPayload: String,
        structuredAction: AtlasStructuredAction? = nil,
        status: ApprovalStatus = .pending,
        executionCount: Int = 0,
        executedAt: Date? = nil,
        executionOutput: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.details = details
        self.riskTier = riskTier
        self.requestedBy = requestedBy
        self.actionPayload = actionPayload
        self.structuredAction = structuredAction
        self.status = status
        self.executionCount = executionCount
        self.executedAt = executedAt
        self.executionOutput = executionOutput
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable {
    public let id: String
    public let role: ChatRole
    public var text: String
    public let timestamp: Date
    public var toolCalls: [String]
    public var touchedFiles: [String]
    public var executionLocation: ExecutionLocation
    public var isPendingApproval: Bool
    /// Separate chain-of-thought some models return alongside the answer.
    /// Shown in its own panel in the transcript, never mixed into `text`.
    public var reasoning: String

    public enum ChatRole: String, Codable {
        case user = "User"
        case assistant = "Sovereign"
        case system = "System"
        case tool = "Tool"
    }

    public enum ExecutionLocation: String, Codable {
        case local = "Local Mac"
        case cloud = "Railway Cloud"
    }

    public init(
        id: String = UUID().uuidString,
        role: ChatRole,
        text: String,
        timestamp: Date = Date(),
        toolCalls: [String] = [],
        touchedFiles: [String] = [],
        executionLocation: ExecutionLocation = .local,
        isPendingApproval: Bool = false,
        reasoning: String = ""
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.toolCalls = toolCalls
        self.touchedFiles = touchedFiles
        self.executionLocation = executionLocation
        self.isPendingApproval = isPendingApproval
        self.reasoning = reasoning
    }

    /// The same message under a different id. `id` is a `let` because a message
    /// keeping one identity for its whole life is what lets the transcript view
    /// patch a node in place; this is the one seam that reassigns it, for when a
    /// completed reply has to take over the streaming message's slot.
    public func withID(_ newID: String) -> ChatMessage {
        ChatMessage(
            id: newID,
            role: role,
            text: text,
            timestamp: timestamp,
            toolCalls: toolCalls,
            touchedFiles: touchedFiles,
            executionLocation: executionLocation,
            isPendingApproval: isPendingApproval,
            reasoning: reasoning
        )
    }
}

public enum ServiceHealthState: String, Codable {
    case notInstalled = "Not Installed"
    case installed = "Installed"
    case configured = "Configured"
    case processRunning = "Process Running"
    case cloudReachable = "Cloud Reachable"
    case authenticatedAndOperational = "Authenticated & Operational"
    case error = "Error / Unreachable"
}

public struct ServiceConnectionStatus: Identifiable, Codable {
    public let id: String
    public let name: String
    public var state: ServiceHealthState
    public var isOnline: Bool
    public var detail: String
    public var lastChecked: Date

    public init(
        id: String,
        name: String,
        state: ServiceHealthState,
        isOnline: Bool,
        detail: String,
        lastChecked: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.isOnline = isOnline
        self.detail = detail
        self.lastChecked = lastChecked
    }
}
