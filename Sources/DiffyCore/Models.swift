import Foundation

public struct RepositoryConfig: Identifiable, Codable, Hashable, Sendable {
    public static let defaultRecentCommitLimit = 5
    public static let recentCommitLimitRange = 1...20

    public var id: UUID
    public var displayName: String
    public var path: String
    public var editor: EditorPreference
    public var groupID: UUID
    public var isHidden: Bool
    /// Set on auto-discovered linked-worktree rows; nil for user-added repos.
    public var parentRepositoryID: UUID?
    /// True for rows that Diffy manages itself (auto-discovered worktrees).
    public var isAutoManaged: Bool
    public var recentCommitLimit: Int

    public init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        editor: EditorPreference = .systemDefault,
        groupID: UUID,
        isHidden: Bool = false,
        parentRepositoryID: UUID? = nil,
        isAutoManaged: Bool = false,
        recentCommitLimit: Int = RepositoryConfig.defaultRecentCommitLimit
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.editor = editor
        self.groupID = groupID
        self.isHidden = isHidden
        self.parentRepositoryID = parentRepositoryID
        self.isAutoManaged = isAutoManaged
        self.recentCommitLimit = Self.clampedRecentCommitLimit(recentCommitLimit)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case path
        case editor
        case groupID
        case isHidden
        case parentRepositoryID
        case isAutoManaged
        case recentCommitLimit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        path = try container.decode(String.self, forKey: .path)
        editor = try container.decodeIfPresent(EditorPreference.self, forKey: .editor) ?? .systemDefault
        groupID = try container.decode(UUID.self, forKey: .groupID)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        parentRepositoryID = try container.decodeIfPresent(UUID.self, forKey: .parentRepositoryID)
        isAutoManaged = try container.decodeIfPresent(Bool.self, forKey: .isAutoManaged) ?? false
        recentCommitLimit = Self.clampedRecentCommitLimit(
            try container.decodeIfPresent(Int.self, forKey: .recentCommitLimit) ?? Self.defaultRecentCommitLimit
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(path, forKey: .path)
        try container.encode(editor, forKey: .editor)
        try container.encode(groupID, forKey: .groupID)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encodeIfPresent(parentRepositoryID, forKey: .parentRepositoryID)
        try container.encode(isAutoManaged, forKey: .isAutoManaged)
        try container.encode(recentCommitLimit, forKey: .recentCommitLimit)
    }

    public static func clampedRecentCommitLimit(_ value: Int) -> Int {
        min(max(value, recentCommitLimitRange.lowerBound), recentCommitLimitRange.upperBound)
    }
}

public enum EditorPreference: Codable, Hashable, Sendable {
    case systemDefault
    case appBundleIdentifier(String)
    case command(String)
}

public struct DiffColors: Codable, Hashable, Sendable {
    public static let `default` = DiffColors(
        additionHex: "#34C759",
        removalHex: "#FF3B30",
        badgeBackgroundHex: nil
    )

    public var additionHex: String
    public var removalHex: String
    public var badgeBackgroundHex: String?

    public init(additionHex: String, removalHex: String, badgeBackgroundHex: String? = nil) {
        self.additionHex = additionHex
        self.removalHex = removalHex
        self.badgeBackgroundHex = badgeBackgroundHex
    }
}

public enum BadgeLabelPosition: String, Codable, Hashable, Sendable, CaseIterable {
    case leading
    case trailing
    case above
    case below
}

public struct BadgeLabel: Codable, Hashable, Sendable {
    public var text: String
    public var position: BadgeLabelPosition

    public init(text: String, position: BadgeLabelPosition) {
        self.text = text
        self.position = position
    }
}

public struct RepositoryGroup: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var diffColors: DiffColors
    public var badgeLabel: BadgeLabel?
    public var isHidden: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        diffColors: DiffColors = .default,
        badgeLabel: BadgeLabel? = nil,
        isHidden: Bool = false
    ) {
        self.id = id
        self.name = name
        self.diffColors = diffColors
        self.badgeLabel = badgeLabel
        self.isHidden = isHidden
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case diffColors
        case badgeLabel
        case isHidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        diffColors = try container.decodeIfPresent(DiffColors.self, forKey: .diffColors) ?? .default
        badgeLabel = try container.decodeIfPresent(BadgeLabel.self, forKey: .badgeLabel)
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(diffColors, forKey: .diffColors)
        try container.encodeIfPresent(badgeLabel, forKey: .badgeLabel)
        try container.encode(isHidden, forKey: .isHidden)
    }
}

/// Branch state of a working tree. Populated from `git worktree list --porcelain`.
public enum BranchInfo: Equatable, Sendable {
    case branch(String)
    case detached(shortSHA: String)
    case bare
    case unknown
}

public enum CommitPublicationStatus: Equatable, Sendable {
    case onUpstream(String)
    case localOnly(String)
    case noUpstream
}

public struct RecentCommitSummary: Identifiable, Equatable, Sendable {
    public var id: String { sha }
    public var sha: String
    public var shortSHA: String
    public var subject: String
    public var committedAt: Date
    public var publicationStatus: CommitPublicationStatus

    public init(
        sha: String,
        shortSHA: String,
        subject: String,
        committedAt: Date,
        publicationStatus: CommitPublicationStatus = .noUpstream
    ) {
        self.sha = sha
        self.shortSHA = shortSHA
        self.subject = subject
        self.committedAt = committedAt
        self.publicationStatus = publicationStatus
    }
}

public struct GitNameStatusEntry: Equatable, Sendable {
    public var path: String
    public var previousPath: String?
    public var status: GitChangeStatus

    public init(path: String, previousPath: String? = nil, status: GitChangeStatus) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
    }
}

public struct HistoricalChangedFile: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var displayStatus: String { status.displayStatus }
    public var path: String
    public var previousPath: String?
    public var status: GitChangeStatus
    public var addedLines: Int
    public var removedLines: Int
    public var isBinary: Bool

    public init(
        path: String,
        previousPath: String? = nil,
        status: GitChangeStatus,
        addedLines: Int,
        removedLines: Int,
        isBinary: Bool
    ) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.isBinary = isBinary
    }
}

public struct RepoDiffSummary: Equatable, Sendable {
    public var repository: RepositoryConfig
    public var addedLines: Int
    public var removedLines: Int
    public var stagedFiles: [ChangedFileSummary]
    public var unstagedFiles: [ChangedFileSummary]
    public var refreshedAt: Date
    public var errorMessage: String?
    public var branch: BranchInfo?

    public init(
        repository: RepositoryConfig,
        addedLines: Int = 0,
        removedLines: Int = 0,
        stagedFiles: [ChangedFileSummary] = [],
        unstagedFiles: [ChangedFileSummary] = [],
        refreshedAt: Date = Date(),
        errorMessage: String? = nil,
        branch: BranchInfo? = nil
    ) {
        self.repository = repository
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.stagedFiles = stagedFiles
        self.unstagedFiles = unstagedFiles
        self.refreshedAt = refreshedAt
        self.errorMessage = errorMessage
        self.branch = branch
    }

    public static func empty(for repository: RepositoryConfig) -> RepoDiffSummary {
        RepoDiffSummary(repository: repository)
    }

    /// Equality intentionally ignores `refreshedAt` so that two summaries with identical
    /// content compare equal — lets `DiffyStore` skip redundant `@Published` writes when
    /// nothing material changed between refreshes.
    public static func == (lhs: RepoDiffSummary, rhs: RepoDiffSummary) -> Bool {
        lhs.repository == rhs.repository
            && lhs.addedLines == rhs.addedLines
            && lhs.removedLines == rhs.removedLines
            && lhs.stagedFiles == rhs.stagedFiles
            && lhs.unstagedFiles == rhs.unstagedFiles
            && lhs.errorMessage == rhs.errorMessage
            && lhs.branch == rhs.branch
    }
}

public struct ChangedFileSummary: Identifiable, Equatable, Hashable, Sendable {
    public var id: String { "\(section.rawValue):\(path)" }
    public var isOpenableFromWorkingTree: Bool { displayStatus != GitChangeStatus.deleted.displayStatus }
    public var path: String
    public var displayStatus: String
    public var addedLines: Int
    public var removedLines: Int
    public var section: DiffSection
    public var isBinary: Bool
    public var isTooLarge: Bool

    public init(
        path: String,
        displayStatus: String,
        addedLines: Int,
        removedLines: Int,
        section: DiffSection,
        isBinary: Bool = false,
        isTooLarge: Bool = false
    ) {
        self.path = path
        self.displayStatus = displayStatus
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.section = section
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
    }
}

public enum DiffSection: String, Codable, Hashable, Sendable {
    case staged
    case unstaged
}

public struct FileLineStat: Equatable, Sendable {
    public var addedLines: Int
    public var removedLines: Int
    public var isBinary: Bool
    public var isTooLarge: Bool

    public init(addedLines: Int, removedLines: Int, isBinary: Bool, isTooLarge: Bool = false) {
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.isBinary = isBinary
        self.isTooLarge = isTooLarge
    }
}

public struct GitPathStatus: Equatable, Sendable {
    public var stagedStatus: GitChangeStatus?
    public var unstagedStatus: GitChangeStatus?

    public init(stagedStatus: GitChangeStatus?, unstagedStatus: GitChangeStatus?) {
        self.stagedStatus = stagedStatus
        self.unstagedStatus = unstagedStatus
    }
}

public enum GitChangeStatus: Equatable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted

    public var displayStatus: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "U"
        // Diffy-specific glyph: git porcelain uses "U"/"UU" for conflicts, but "U" is taken by .untracked.
        case .conflicted: "!"
        }
    }
}
