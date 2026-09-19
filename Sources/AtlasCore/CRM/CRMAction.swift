import Foundation

// The CRM's bridge vocabulary and its validation rules.
//
// These live in AtlasCore rather than beside the web view because they are
// domain logic, not UI: the allowlist defines what the CRM can be asked to do
// at all, and the validator is the last check before anything is written. Both
// need to be testable without a web view in the room.

// MARK: - The allowlist

/// Everything `crm.html` is permitted to ask for.
///
/// This enum *is* the security boundary. A message that does not decode into one
/// of these cases is dropped and logged — the page can request a defined CRM
/// operation and nothing else. There is no "eval", no SQL, no file path and no
/// shell verb anywhere in this vocabulary, so there is nothing for a crafted
/// message to reach for.
public enum CRMActionKind: String, Decodable, CaseIterable, Sendable {
    case load
    case search
    case saveCompany
    case deleteCompany
    case saveContact
    case deleteContact
    case saveOpportunity
    case deleteOpportunity
    case setStage
    case logActivity
    case deleteActivity
    case saveView
    case deleteView
    case saveIdea
    case deleteIdea
    case promoteIdea
}

/// A decoded request from the page, before validation.
///
/// Fields are all optional here on purpose: decoding proves the *shape*, and
/// `CRMActionValidator` proves the *contents*. Keeping those apart means an
/// action can be rejected with a reason instead of failing to decode into
/// silence.
public struct CRMAction: Decodable, Sendable {
    public let action: CRMActionKind
    public let id: String?
    public let companyId: String?
    public let contactId: String?
    public let opportunityId: String?
    public let name: String?
    public let title: String?
    public let website: String?
    public let phone: String?
    public let email: String?
    public let address: String?
    public let industry: String?
    public let status: String?
    public let stage: String?
    public let preferredContact: String?
    public let kind: String?
    public let summary: String?
    public let notes: String?
    public let projectPath: String?
    public let query: String?
    public let valueCents: Int?
    public let probability: Int?
    public let nextFollowUpAt: Double?
    public let cascade: Bool?
    public let scope: String?
    public let sortField: String?
    public let sortAscending: Bool?
    public let minValueCents: Int?
    public let staleDays: Int?
    // Ideas. `title`, `notes`, `status` and `id` are shared with the other
    // record types rather than duplicated.
    public let pitch: String?
    public let category: String?
    public let effort: String?
    public let potential: String?
    public let nextStep: String?
}

/// Why a request was refused.
public enum CRMValidationError: Error, Equatable, Sendable {
    case missing(String)
    case tooLong(String, max: Int)
    case unknownValue(String, String)
    case outOfRange(String)

    public var message: String {
        switch self {
        case .missing(let field): return "\(field) is required."
        case .tooLong(let field, let max): return "\(field) must be \(max) characters or fewer."
        case .unknownValue(let field, let value): return "\(value) is not a valid \(field)."
        case .outOfRange(let field): return "\(field) is out of range."
        }
    }
}

/// Re-checks everything the page sent, on this side of the boundary.
///
/// The page validates too, for the person typing. None of that is trusted: a
/// web view can be handed any message at all, so every rule that matters is
/// enforced again here before a record is written.
public enum CRMActionValidator {
    /// Long enough for real notes, short enough that a runaway page cannot
    /// write a gigabyte into the database.
    public static let maxShortField = 500
    public static let maxNotesField = 20_000

    public static func company(from action: CRMAction) -> Result<Company, CRMValidationError> {
        guard let rawName = action.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else { return .failure(.missing("Company name")) }
        if let error = length(rawName, "Company name", max: maxShortField) { return .failure(error) }

        var status = CompanyStatus.prospect
        if let raw = action.status, !raw.isEmpty {
            guard let parsed = CompanyStatus(rawValue: raw) else {
                return .failure(.unknownValue("status", raw))
            }
            status = parsed
        }

        let fields = [("website", action.website), ("phone", action.phone),
                      ("address", action.address), ("industry", action.industry)]
        for (label, value) in fields {
            if let value, let error = length(value, label, max: maxShortField) { return .failure(error) }
        }
        if let notes = action.notes, let error = length(notes, "notes", max: maxNotesField) {
            return .failure(error)
        }

        return .success(Company(
            id: action.id?.nilIfBlank ?? UUID().uuidString,
            name: rawName,
            website: action.website ?? "",
            phone: action.phone ?? "",
            address: action.address ?? "",
            industry: action.industry ?? "",
            status: status,
            notes: action.notes ?? ""
        ))
    }

    public static func contact(from action: CRMAction) -> Result<Contact, CRMValidationError> {
        guard let rawName = action.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else { return .failure(.missing("Contact name")) }
        if let error = length(rawName, "Contact name", max: maxShortField) { return .failure(error) }

        var method = ContactMethod.unknown
        if let raw = action.preferredContact, !raw.isEmpty {
            guard let parsed = ContactMethod(rawValue: raw) else {
                return .failure(.unknownValue("preferred contact method", raw))
            }
            method = parsed
        }

        for (label, value) in [("email", action.email), ("phone", action.phone), ("title", action.title)] {
            if let value, let error = length(value, label, max: maxShortField) { return .failure(error) }
        }
        if let notes = action.notes, let error = length(notes, "notes", max: maxNotesField) {
            return .failure(error)
        }

        return .success(Contact(
            id: action.id?.nilIfBlank ?? UUID().uuidString,
            companyId: action.companyId?.nilIfBlank,
            name: rawName,
            email: action.email ?? "",
            phone: action.phone ?? "",
            title: action.title ?? "",
            preferredContact: method,
            notes: action.notes ?? ""
        ))
    }

    public static func opportunity(from action: CRMAction) -> Result<Opportunity, CRMValidationError> {
        guard let rawTitle = action.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else { return .failure(.missing("Opportunity title")) }
        if let error = length(rawTitle, "Opportunity title", max: maxShortField) { return .failure(error) }

        var stage = OpportunityStage.lead
        if let raw = action.stage, !raw.isEmpty {
            guard let parsed = OpportunityStage(rawValue: raw) else {
                return .failure(.unknownValue("stage", raw))
            }
            stage = parsed
        }

        let probability = action.probability ?? 0
        guard (0...100).contains(probability) else { return .failure(.outOfRange("probability")) }

        let value = action.valueCents ?? 0
        // Negative money is a bug, not a discount; and a cap keeps a nonsense
        // value from poisoning every pipeline total on the overview.
        guard value >= 0, value <= 1_000_000_000_00 else { return .failure(.outOfRange("estimated value")) }

        if let path = action.projectPath, let error = length(path, "project path", max: maxShortField) {
            return .failure(error)
        }
        if let notes = action.notes, let error = length(notes, "notes", max: maxNotesField) {
            return .failure(error)
        }

        return .success(Opportunity(
            id: action.id?.nilIfBlank ?? UUID().uuidString,
            companyId: action.companyId?.nilIfBlank,
            title: rawTitle,
            estimatedValueCents: value,
            stage: stage,
            probability: probability,
            nextFollowUpAt: action.nextFollowUpAt.map { Date(timeIntervalSince1970: $0) },
            projectPath: action.projectPath ?? "",
            notes: action.notes ?? ""
        ))
    }

    public static func activity(from action: CRMAction) -> Result<Activity, CRMValidationError> {
        guard let raw = action.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .failure(.missing("Activity summary")) }
        if let error = length(raw, "summary", max: maxNotesField) { return .failure(error) }

        var kind = ActivityKind.note
        if let rawKind = action.kind, !rawKind.isEmpty {
            guard let parsed = ActivityKind(rawValue: rawKind) else {
                return .failure(.unknownValue("activity type", rawKind))
            }
            kind = parsed
        }

        return .success(Activity(
            id: action.id?.nilIfBlank ?? UUID().uuidString,
            companyId: action.companyId?.nilIfBlank,
            contactId: action.contactId?.nilIfBlank,
            opportunityId: action.opportunityId?.nilIfBlank,
            kind: kind,
            summary: raw
        ))
    }

    /// A validated request to move one card on the board.
    /// An idea, checked the same way every other record is: known enum values
    /// only, and lengths capped before anything reaches the database.
    public static func idea(from action: CRMAction) -> Result<Idea, CRMValidationError> {
        guard let rawTitle = action.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTitle.isEmpty else { return .failure(.missing("Idea title")) }
        if let error = length(rawTitle, "Idea title", max: maxShortField) { return .failure(error) }

        var status = IdeaStatus.spark
        if let raw = action.status, !raw.isEmpty {
            guard let parsed = IdeaStatus(rawValue: raw) else {
                return .failure(.unknownValue("status", raw))
            }
            status = parsed
        }

        var category = IdeaCategory.sideHustle
        if let raw = action.category, !raw.isEmpty {
            guard let parsed = IdeaCategory(rawValue: raw) else {
                return .failure(.unknownValue("category", raw))
            }
            category = parsed
        }

        var effort = IdeaSizing.unknown
        if let raw = action.effort, !raw.isEmpty {
            guard let parsed = IdeaSizing(rawValue: raw) else {
                return .failure(.unknownValue("effort", raw))
            }
            effort = parsed
        }

        var potential = IdeaSizing.unknown
        if let raw = action.potential, !raw.isEmpty {
            guard let parsed = IdeaSizing(rawValue: raw) else {
                return .failure(.unknownValue("potential", raw))
            }
            potential = parsed
        }

        for (label, value) in [("pitch", action.pitch), ("next step", action.nextStep)] {
            if let value, let error = length(value, label, max: maxShortField) { return .failure(error) }
        }
        if let notes = action.notes, let error = length(notes, "notes", max: maxNotesField) {
            return .failure(error)
        }

        return .success(Idea(
            id: action.id?.nilIfBlank ?? UUID().uuidString,
            title: rawTitle,
            pitch: action.pitch ?? "",
            status: status,
            category: category,
            effort: effort,
            potential: potential,
            nextStep: action.nextStep ?? "",
            notes: action.notes ?? ""
        ))
    }

    public struct StageMove: Equatable, Sendable {
        public let id: String
        public let stage: OpportunityStage
    }

    /// A saved view, checked the same way a record is: known enum values only,
    /// bounded text, and no filter that could ask for something absurd.
    public static func savedView(from action: CRMAction) -> Result<SavedView, CRMValidationError> {
        guard let rawName = action.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else { return .failure(.missing("View name")) }
        if let error = length(rawName, "View name", max: maxShortField) { return .failure(error) }

        var scope = ViewScope.opportunities
        if let raw = action.scope, !raw.isEmpty {
            guard let parsed = ViewScope(rawValue: raw) else {
                return .failure(.unknownValue("scope", raw))
            }
            scope = parsed
        }

        var stage: OpportunityStage?
        if let raw = action.stage, !raw.isEmpty {
            guard let parsed = OpportunityStage(rawValue: raw) else {
                return .failure(.unknownValue("stage", raw))
            }
            stage = parsed
        }

        var sortField = SortField.updated
        if let raw = action.sortField, !raw.isEmpty {
            guard let parsed = SortField(rawValue: raw) else {
                return .failure(.unknownValue("sort field", raw))
            }
            sortField = parsed
        }

        if let floor = action.minValueCents, floor < 0 || floor > 1_000_000_000_00 {
            return .failure(.outOfRange("minimum value"))
        }
        if let stale = action.staleDays, stale < 0 || stale > 3650 {
            return .failure(.outOfRange("stale days"))
        }
        if let query = action.query, let error = length(query, "search", max: maxShortField) {
            return .failure(error)
        }

        return .success(SavedView(
            id: action.id?.nilIfBlank ?? UUID().uuidString,
            name: rawName,
            scope: scope,
            query: action.query ?? "",
            stage: stage,
            minValueMinorUnits: action.minValueCents,
            staleDays: action.staleDays,
            sortField: sortField,
            sortAscending: action.sortAscending ?? false
        ))
    }

    public static func stage(from action: CRMAction) -> Result<StageMove, CRMValidationError> {
        guard let id = action.id?.nilIfBlank else { return .failure(.missing("Opportunity id")) }
        guard let raw = action.stage else { return .failure(.missing("stage")) }
        guard let parsed = OpportunityStage(rawValue: raw) else {
            return .failure(.unknownValue("stage", raw))
        }
        return .success(StageMove(id: id, stage: parsed))
    }

    private static func length(_ value: String, _ field: String, max: Int) -> CRMValidationError? {
        value.count > max ? .tooLong(field, max: max) : nil
    }
}

private extension String {
    /// Treats "" and whitespace as absent, so a cleared field in the page means
    /// "no relationship" rather than a foreign key of empty string.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
