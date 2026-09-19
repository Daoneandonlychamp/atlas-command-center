import Foundation
import WebKit
import AtlasCore

// MARK: - Bridge

/// Sits between `crm.html` and `CRMStore`.
///
/// The page owns what is on screen; this owns everything that touches the
/// database. Every write reports back — saved, or why not — because a form that
/// silently failed is worse than one that visibly did.
@MainActor
final class CRMBridge {
    private weak var webView: WKWebView?
    private var pageIsReady = false
    private var pending: [(function: String, json: String)] = []

    private let store: CRMStore
    /// The search the page last asked for, so a write can refresh the same view.
    private var lastQuery: String = ""

    init(store: CRMStore = .shared) {
        self.store = store
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        pageIsReady = false
    }

    func pageDidLoad() {
        pageIsReady = true
        let queued = pending
        pending = []
        for call in queued { push(call.function, call.json) }
        reload()
    }

    // MARK: - Actions

    func handle(_ action: CRMAction) {
        if let failure = store.openFailure {
            push("error", encode(["message": failure, "fatal": true]))
            return
        }

        switch action.action {
        case .load:
            reload()

        case .search:
            lastQuery = action.query ?? ""
            reload()

        case .saveCompany:
            switch CRMActionValidator.company(from: action) {
            case .success(let record):
                let existing = action.id?.isEmpty == false
                store.upsert(record)
                if !existing {
                    store.log(Activity(companyId: record.id, kind: .note,
                                       summary: "Company added"))
                }
                done(existing ? "Company saved" : "Company created")
            case .failure(let error):
                refuse(error)
            }

        case .deleteCompany:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Company id")) }
            switch store.deleteCompany(id, cascade: action.cascade ?? false) {
            case .deleted:
                done("Company deleted")
            case .restricted(let impact):
                // Not an error: the page turns this into a confirmation that
                // names exactly what is about to go.
                push("confirmDelete", encode([
                    "id": id,
                    "contacts": impact.contacts,
                    "opportunities": impact.opportunities,
                    "activities": impact.activities
                ] as [String: Any]))
            case .notFound:
                refuse(.unknownValue("company id", id))
            }

        case .saveContact:
            switch CRMActionValidator.contact(from: action) {
            case .success(let record):
                let existing = action.id?.isEmpty == false
                store.upsert(record)
                done(existing ? "Contact saved" : "Contact created")
            case .failure(let error):
                refuse(error)
            }

        case .deleteContact:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Contact id")) }
            report(store.deleteContact(id), success: "Contact deleted", id: id, label: "contact id")

        case .saveOpportunity:
            switch CRMActionValidator.opportunity(from: action) {
            case .success(let record):
                let existing = action.id?.isEmpty == false
                store.upsert(record)
                done(existing ? "Opportunity saved" : "Opportunity created")
            case .failure(let error):
                refuse(error)
            }

        case .deleteOpportunity:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Opportunity id")) }
            report(store.deleteOpportunity(id), success: "Opportunity deleted", id: id,
                   label: "opportunity id")

        case .setStage:
            switch CRMActionValidator.stage(from: action) {
            case .success(let move):
                if store.setStage(move.id, to: move.stage) == nil {
                    refuse(.unknownValue("opportunity id", move.id))
                } else {
                    done("Moved to \(move.stage.title)")
                }
            case .failure(let error):
                refuse(error)
            }

        case .logActivity:
            switch CRMActionValidator.activity(from: action) {
            case .success(let record):
                store.log(record)
                done("Activity logged")
            case .failure(let error):
                refuse(error)
            }

        case .saveView:
            switch CRMActionValidator.savedView(from: action) {
            case .success(let view):
                store.upsert(view)
                done(action.id?.isEmpty == false ? "View saved" : "View created")
            case .failure(let error):
                refuse(error)
            }

        case .deleteView:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("View id")) }
            report(store.deleteSavedView(id), success: "View deleted", id: id, label: "view id")

        case .deleteActivity:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Activity id")) }
            report(store.deleteActivity(id), success: "Activity deleted", id: id, label: "activity id")

        case .saveIdea:
            switch CRMActionValidator.idea(from: action) {
            case .success(let record):
                let existing = action.id?.isEmpty == false
                // An edit must not silently drop the link to a promoted deal:
                // the validator builds a fresh record from the form, which has
                // no field for it.
                var toSave = record
                if existing, let previous = store.idea(record.id) {
                    toSave.promotedOpportunityId = previous.promotedOpportunityId
                    toSave.createdAt = previous.createdAt
                }
                store.upsert(toSave)
                done(existing ? "Idea saved" : "Idea captured")
            case .failure(let error):
                refuse(error)
            }

        case .deleteIdea:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Idea id")) }
            report(store.deleteIdea(id), success: "Idea deleted", id: id, label: "idea id")

        case .promoteIdea:
            guard let id = action.id, !id.isEmpty else { return refuse(.missing("Idea id")) }
            guard let promotion = store.promote(ideaId: id,
                                                companyName: action.name,
                                                estimatedValueCents: action.valueCents ?? 0) else {
                // Either it is gone or it is already a deal; neither is worth an
                // error dialog, so say what happened and move on.
                refuse(.unknownValue("idea id", id))
                return
            }
            done("\(promotion.idea.title) is now in the pipeline")
        }
    }

    private func report(_ outcome: DeleteOutcome, success: String, id: String, label: String) {
        switch outcome {
        case .deleted: done(success)
        case .notFound: refuse(.unknownValue(label, id))
        case .restricted(let impact):
            push("confirmDelete", encode([
                "id": id,
                "contacts": impact.contacts,
                "opportunities": impact.opportunities,
                "activities": impact.activities
            ] as [String: Any]))
        }
    }

    private func done(_ message: String) {
        push("saved", encode(["message": message]))
        reload()
    }

    private func refuse(_ error: CRMValidationError) {
        NSLog("[ATLAS CRM] refused a request: %@", error.message)
        push("error", encode(["message": error.message]))
    }

    // MARK: - Snapshot

    /// Sends the whole current view in one message.
    ///
    /// The CRM is small enough that a full snapshot is simpler and less
    /// error-prone than incremental patches, and it means the page can never
    /// drift out of step with the database.
    func reload() {
        if let failure = store.openFailure {
            push("error", encode(["message": failure, "fatal": true]))
            return
        }
        let summary = store.summary()
        let payload: [String: Any] = [
            "query": lastQuery,
            "schemaVersion": store.schemaVersion(),
            "summary": [
                "openCount": summary.openCount,
                "openValueCents": summary.openValueCents,
                "weightedValueCents": summary.weightedValueCents,
                "wonCount": summary.wonCount,
                "wonValueCents": summary.wonValueCents,
                "needingFollowUp": summary.needingFollowUp,
                "companyCount": summary.companyCount,
                "contactCount": summary.contactCount
            ],
            "stages": OpportunityStage.board.map { ["id": $0.rawValue, "title": $0.title] },
            "companyStatuses": CompanyStatus.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "contactMethods": ContactMethod.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "activityKinds": ActivityKind.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "companies": store.companies(matching: lastQuery).map(Self.dictionary),
            "contacts": store.contacts(matching: lastQuery).map(Self.dictionary),
            "opportunities": store.opportunities(matching: lastQuery).map(Self.dictionary),
            "followUps": store.needingFollowUp().map(Self.dictionary),
            "activities": store.activities(limit: 60).map(Self.dictionary),
            "sortFields": SortField.allCases.map { ["id": $0.rawValue, "title": $0.title,
                                                    "dealsOnly": $0.isOpportunityOnly] },
            "views": store.savedViews().map(Self.dictionary),
            "ideas": store.ideas(matching: lastQuery).map(Self.dictionary),
            "ideaStatuses": IdeaStatus.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "ideaCategories": IdeaCategory.allCases.map { ["id": $0.rawValue, "title": $0.title] },
            "ideaSizings": IdeaSizing.allCases.map { ["id": $0.rawValue, "title": $0.title] }
        ]
        push("render", encode(payload))
    }

    private static func dictionary(_ record: Idea) -> [String: Any] {
        ["id": record.id, "title": record.title, "pitch": record.pitch,
         "status": record.status.rawValue, "category": record.category.rawValue,
         "effort": record.effort.rawValue, "potential": record.potential.rawValue,
         "nextStep": record.nextStep, "notes": record.notes,
         "promotedOpportunityId": record.promotedOpportunityId ?? "",
         "isPromoted": record.isPromoted,
         "createdAt": record.createdAt.timeIntervalSince1970,
         "updatedAt": record.updatedAt.timeIntervalSince1970]
    }

    private static func dictionary(_ record: Company) -> [String: Any] {
        ["id": record.id, "name": record.name, "website": record.website, "phone": record.phone,
         "address": record.address, "industry": record.industry, "status": record.status.rawValue,
         "notes": record.notes,
         "createdAt": record.createdAt.timeIntervalSince1970,
         "updatedAt": record.updatedAt.timeIntervalSince1970]
    }

    private static func dictionary(_ record: Contact) -> [String: Any] {
        ["id": record.id, "companyId": record.companyId ?? "", "name": record.name,
         "email": record.email, "phone": record.phone, "title": record.title,
         "preferredContact": record.preferredContact.rawValue, "notes": record.notes,
         "createdAt": record.createdAt.timeIntervalSince1970,
         "updatedAt": record.updatedAt.timeIntervalSince1970]
    }

    private static func dictionary(_ record: Opportunity) -> [String: Any] {
        var out: [String: Any] = [
            "id": record.id, "companyId": record.companyId ?? "", "title": record.title,
            "valueCents": record.estimatedValueCents, "stage": record.stage.rawValue,
            "probability": record.probability, "projectPath": record.projectPath,
            "notes": record.notes,
            "createdAt": record.createdAt.timeIntervalSince1970,
            "updatedAt": record.updatedAt.timeIntervalSince1970
        ]
        if let due = record.nextFollowUpAt { out["nextFollowUpAt"] = due.timeIntervalSince1970 }
        return out
    }

    private static func dictionary(_ view: SavedView) -> [String: Any] {
        var out: [String: Any] = [
            "id": view.id, "name": view.name, "scope": view.scope.rawValue,
            "query": view.query, "sortField": view.sortField.rawValue,
            "sortAscending": view.sortAscending
        ]
        if let stage = view.stage { out["stage"] = stage.rawValue }
        if let floor = view.minValueMinorUnits { out["minValueCents"] = floor }
        if let stale = view.staleDays { out["staleDays"] = stale }
        return out
    }

    private static func dictionary(_ record: Activity) -> [String: Any] {
        ["id": record.id, "companyId": record.companyId ?? "", "contactId": record.contactId ?? "",
         "opportunityId": record.opportunityId ?? "", "kind": record.kind.rawValue,
         "summary": record.summary, "occurredAt": record.occurredAt.timeIntervalSince1970]
    }

    // MARK: - Sending

    private func encode(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The JSON travels as a bound argument, never interpolated into the script
    /// text, so nothing inside a record can break out of the call.
    private func push(_ function: String, _ json: String) {
        guard let webView, pageIsReady else {
            pending.append((function, json))
            return
        }
        webView.callAsyncJavaScript("window.atlasCRM.\(function)(json)",
                                    arguments: ["json": json], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                NSLog("[ATLAS CRM] %@ failed: %@", function, error.localizedDescription)
            }
        }
    }
}
