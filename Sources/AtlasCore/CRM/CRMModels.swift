import Foundation

/// The CRM's record types.
///
/// Everything is a plain value type with a string id, so the store, the bridge
/// and the page all talk about the same shapes. Money is held in whole cents as
/// an `Int` — a pipeline total built out of `Double` drifts, and the one number
/// a CRM is judged on should not.

// MARK: - Stage

/// Where an opportunity sits in the pipeline.
///
/// The raw values are what land in the database, so renaming a case is a
/// migration, not a refactor.
public enum OpportunityStage: String, Codable, CaseIterable, Sendable {
    case lead
    case contacted
    case qualified
    case proposal
    case won
    case lost

    public var title: String {
        switch self {
        case .lead: return "Lead"
        case .contacted: return "Contacted"
        case .qualified: return "Qualified"
        case .proposal: return "Proposal"
        case .won: return "Won"
        case .lost: return "Lost"
        }
    }

    /// Won and lost leave the pipeline: they stop counting toward open value
    /// and stop asking for a follow-up.
    public var isOpen: Bool {
        self != .won && self != .lost
    }

    /// The board's left-to-right order.
    public static var board: [OpportunityStage] {
        [.lead, .contacted, .qualified, .proposal, .won, .lost]
    }
}

/// How someone would rather be reached.
public enum ContactMethod: String, Codable, CaseIterable, Sendable {
    case unknown
    case email
    case phone
    case text
    case inPerson

    public var title: String {
        switch self {
        case .unknown: return "No preference"
        case .email: return "Email"
        case .phone: return "Phone"
        case .text: return "Text"
        case .inPerson: return "In person"
        }
    }
}

/// What a company is to us right now.
public enum CompanyStatus: String, Codable, CaseIterable, Sendable {
    case prospect
    case active
    case past
    case archived

    public var title: String {
        switch self {
        case .prospect: return "Prospect"
        case .active: return "Active"
        case .past: return "Past"
        case .archived: return "Archived"
        }
    }
}

/// What happened.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case note
    case call
    case email
    case meeting
    case statusChange

    public var title: String {
        switch self {
        case .note: return "Note"
        case .call: return "Call"
        case .email: return "Email"
        case .meeting: return "Meeting"
        case .statusChange: return "Status change"
        }
    }
}

// MARK: - Records

public struct Company: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var website: String
    public var phone: String
    public var address: String
    public var industry: String
    public var status: CompanyStatus
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                website: String = "",
                phone: String = "",
                address: String = "",
                industry: String = "",
                status: CompanyStatus = .prospect,
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.website = website
        self.phone = phone
        self.address = address
        self.industry = industry
        self.status = status
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Contact: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// nil means the person is not attached to a company yet.
    public var companyId: String?
    public var name: String
    public var email: String
    public var phone: String
    public var title: String
    public var preferredContact: ContactMethod
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                companyId: String? = nil,
                name: String,
                email: String = "",
                phone: String = "",
                title: String = "",
                preferredContact: ContactMethod = .unknown,
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.companyId = companyId
        self.name = name
        self.email = email
        self.phone = phone
        self.title = title
        self.preferredContact = preferredContact
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Opportunity: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var companyId: String?
    public var title: String
    /// Whole cents. See the note at the top of this file.
    public var estimatedValueCents: Int
    public var stage: OpportunityStage
    /// 0...100, clamped on the way in.
    public var probability: Int
    public var nextFollowUpAt: Date?
    /// An ATLAS project this work belongs to, when there is one. Just a path —
    /// the CRM never reads or writes inside it.
    public var projectPath: String
    public var notes: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                companyId: String? = nil,
                title: String,
                estimatedValueCents: Int = 0,
                stage: OpportunityStage = .lead,
                probability: Int = 0,
                nextFollowUpAt: Date? = nil,
                projectPath: String = "",
                notes: String = "",
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.companyId = companyId
        self.title = title
        self.estimatedValueCents = estimatedValueCents
        self.stage = stage
        self.probability = min(max(probability, 0), 100)
        self.nextFollowUpAt = nextFollowUpAt
        self.projectPath = projectPath
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// What this is worth once weighted by how likely it is.
    public var weightedValueCents: Int {
        estimatedValueCents * probability / 100
    }

    /// Overdue or due today, and still in play.
    public func needsFollowUp(asOf now: Date = Date()) -> Bool {
        guard stage.isOpen, let due = nextFollowUpAt else { return false }
        return due <= now
    }
}

public struct Activity: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var companyId: String?
    public var contactId: String?
    public var opportunityId: String?
    public var kind: ActivityKind
    public var summary: String
    public var occurredAt: Date

    public init(id: String = UUID().uuidString,
                companyId: String? = nil,
                contactId: String? = nil,
                opportunityId: String? = nil,
                kind: ActivityKind = .note,
                summary: String,
                occurredAt: Date = Date()) {
        self.id = id
        self.companyId = companyId
        self.contactId = contactId
        self.opportunityId = opportunityId
        self.kind = kind
        self.summary = summary
        self.occurredAt = occurredAt
    }
}

// MARK: - Deletion

/// What a delete would take with it.
///
/// A company is never quietly removed along with everything attached to it: the
/// store refuses and reports the count, and the caller has to ask again with
/// `cascade: true` once the person has seen what they are about to lose.
/// Where an idea has got to.
///
/// Deliberately coarse. Finer stages would invite maintenance of the list
/// rather than work on the idea, and the point of this record is that it costs
/// almost nothing to write down.
///
/// The raw values land in the database, so renaming a case is a migration.
public enum IdeaStatus: String, Codable, CaseIterable, Sendable {
    case spark        // written down, nothing done
    case exploring    // reading, poking at it
    case validating   // talking to people, testing demand
    case running      // it exists and is live
    case parked       // deliberately set down, not deleted

    public var isOpen: Bool {
        switch self {
        case .spark, .exploring, .validating, .running: return true
        case .parked: return false
        }
    }

    public var title: String {
        switch self {
        case .spark: return "Spark"
        case .exploring: return "Exploring"
        case .validating: return "Validating"
        case .running: return "Running"
        case .parked: return "Parked"
        }
    }
}

public enum IdeaCategory: String, Codable, CaseIterable, Sendable {
    case sideHustle
    case product
    case service
    case content
    case other

    public var title: String {
        switch self {
        case .sideHustle: return "Side hustle"
        case .product: return "Product"
        case .service: return "Service"
        case .content: return "Content"
        case .other: return "Other"
        }
    }
}

/// A rough two-axis sizing. Not a score, and never multiplied into one: the
/// moment an idea has a number attached, it starts competing on false
/// precision instead of on judgement.
public enum IdeaSizing: String, Codable, CaseIterable, Sendable {
    case unknown
    case low
    case medium
    case high

    public var title: String {
        switch self {
        case .unknown: return "—"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

/// A business idea or side hustle, before there is anyone on the other side.
///
/// This is not a Company, Contact or Opportunity: all three assume a
/// counterparty, and an idea at this stage has none. Keeping it separate is
/// also what stops daydreams being counted in the open-pipeline figure.
///
/// `promotedOpportunityId` is set when an idea graduates into the pipeline, so
/// a live deal can still point back at where it came from.
public struct Idea: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    /// One line. What it is, in the words you would use out loud.
    public var pitch: String
    public var status: IdeaStatus
    public var category: IdeaCategory
    public var effort: IdeaSizing
    public var potential: IdeaSizing
    /// The single next thing that would move this forward.
    public var nextStep: String
    public var notes: String
    public var promotedOpportunityId: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                title: String,
                pitch: String = "",
                status: IdeaStatus = .spark,
                category: IdeaCategory = .sideHustle,
                effort: IdeaSizing = .unknown,
                potential: IdeaSizing = .unknown,
                nextStep: String = "",
                notes: String = "",
                promotedOpportunityId: String? = nil,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.pitch = pitch
        self.status = status
        self.category = category
        self.effort = effort
        self.potential = potential
        self.nextStep = nextStep
        self.notes = notes
        self.promotedOpportunityId = promotedOpportunityId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// An idea that has already become a deal should not be promoted twice.
    public var isPromoted: Bool {
        promotedOpportunityId?.isEmpty == false
    }
}

public struct DeletionImpact: Equatable, Sendable {
    public let contacts: Int
    public let opportunities: Int
    public let activities: Int

    public var isEmpty: Bool { contacts == 0 && opportunities == 0 && activities == 0 }

    public init(contacts: Int, opportunities: Int, activities: Int) {
        self.contacts = contacts
        self.opportunities = opportunities
        self.activities = activities
    }
}

public enum DeleteOutcome: Equatable, Sendable {
    case deleted
    /// Dependents exist and `cascade` was not requested.
    case restricted(DeletionImpact)
    case notFound
}

// MARK: - Saved views

/// Which records a view is about.
public enum ViewScope: String, Codable, CaseIterable, Sendable {
    case opportunities, companies, contacts

    public var title: String {
        switch self {
        case .opportunities: return "Opportunities"
        case .companies: return "Companies"
        case .contacts: return "Contacts"
        }
    }
}

/// A column the table can be ordered by.
///
/// Sorting happens over loaded records rather than in SQL: the sets here are
/// small, and it keeps a view definition from having to be trusted enough to
/// reach the database.
public enum SortField: String, Codable, CaseIterable, Sendable {
    case name, value, stage, probability, followUp, updated

    public var title: String {
        switch self {
        case .name: return "Name"
        case .value: return "Value"
        case .stage: return "Stage"
        case .probability: return "Probability"
        case .followUp: return "Follow-up"
        case .updated: return "Updated"
        }
    }

    /// Columns that only mean something for a deal.
    public var isOpportunityOnly: Bool {
        switch self {
        case .value, .stage, .probability, .followUp: return true
        case .name, .updated: return false
        }
    }
}

/// A named filter you can come back to — "Proposals over $10k", "Untouched for
/// 30 days". The search box answers a question once; this remembers it.
public struct SavedView: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var scope: ViewScope
    public var query: String
    /// Only meaningful for opportunities. nil means every stage.
    public var stage: OpportunityStage?
    /// Minimum deal value, in cents. nil means no floor.
    public var minValueMinorUnits: Int?
    /// Only deals untouched for at least this many days. nil means any.
    public var staleDays: Int?
    public var sortField: SortField
    public var sortAscending: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString,
                name: String,
                scope: ViewScope = .opportunities,
                query: String = "",
                stage: OpportunityStage? = nil,
                minValueMinorUnits: Int? = nil,
                staleDays: Int? = nil,
                sortField: SortField = .updated,
                sortAscending: Bool = false,
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.scope = scope
        self.query = query
        self.stage = stage
        self.minValueMinorUnits = minValueMinorUnits
        self.staleDays = staleDays
        self.sortField = sortField
        self.sortAscending = sortAscending
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// True when this view narrows anything at all.
    public var isFiltered: Bool {
        !query.isEmpty || stage != nil || minValueMinorUnits != nil || staleDays != nil
    }
}

/// Applies a saved view to loaded records.
///
/// Pure, so the rules a view encodes are testable without a database and the
/// page and the store cannot disagree about what a view means.
public enum ViewFilter {
    public static func apply(_ view: SavedView, to deals: [Opportunity],
                             asOf now: Date = Date(),
                             calendar: Calendar = .current) -> [Opportunity] {
        var out = deals
        if let stage = view.stage { out = out.filter { $0.stage == stage } }
        if let floor = view.minValueMinorUnits { out = out.filter { $0.estimatedValueCents >= floor } }
        if let stale = view.staleDays {
            out = out.filter { deal in
                let days = calendar.dateComponents([.day], from: deal.updatedAt, to: now).day ?? 0
                return days >= stale
            }
        }
        return sort(out, by: view.sortField, ascending: view.sortAscending)
    }

    public static func sort(_ deals: [Opportunity], by field: SortField,
                            ascending: Bool) -> [Opportunity] {
        let sorted: [Opportunity]
        switch field {
        case .name:
            sorted = deals.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .value:
            sorted = deals.sorted { $0.estimatedValueCents < $1.estimatedValueCents }
        case .stage:
            let order = OpportunityStage.board
            sorted = deals.sorted {
                (order.firstIndex(of: $0.stage) ?? 0) < (order.firstIndex(of: $1.stage) ?? 0)
            }
        case .probability:
            sorted = deals.sorted { $0.probability < $1.probability }
        case .followUp:
            // No date sorts last either way: an empty cell is not "soonest".
            sorted = deals.sorted {
                ($0.nextFollowUpAt ?? .distantFuture) < ($1.nextFollowUpAt ?? .distantFuture)
            }
        case .updated:
            sorted = deals.sorted { $0.updatedAt < $1.updatedAt }
        }
        return ascending ? sorted : sorted.reversed()
    }
}

// MARK: - Overview

/// The numbers the overview panel shows. Derived, never stored.
public struct PipelineSummary: Codable, Equatable, Sendable {
    public var openCount: Int
    public var openValueCents: Int
    public var weightedValueCents: Int
    public var wonCount: Int
    public var wonValueCents: Int
    public var needingFollowUp: Int
    public var companyCount: Int
    public var contactCount: Int

    public init(openCount: Int = 0, openValueCents: Int = 0, weightedValueCents: Int = 0,
                wonCount: Int = 0, wonValueCents: Int = 0, needingFollowUp: Int = 0,
                companyCount: Int = 0, contactCount: Int = 0) {
        self.openCount = openCount
        self.openValueCents = openValueCents
        self.weightedValueCents = weightedValueCents
        self.wonCount = wonCount
        self.wonValueCents = wonValueCents
        self.needingFollowUp = needingFollowUp
        self.companyCount = companyCount
        self.contactCount = contactCount
    }
}
