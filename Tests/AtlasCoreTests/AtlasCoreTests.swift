import XCTest
@testable import AtlasCore

final class AtlasCoreTests: XCTestCase {

    /// Workspace settings are global, so each test that changes them puts the
    /// user's own back afterwards rather than leaving a temp directory wired
    /// into the app that ran the suite.
    private var savedProjectPaths: [String] = []
    private var savedCompanionScopes: [String] = []
    private var savedHermesBinary: String = ""
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        EmergencyStopManager.shared.resetEmergencyStop()
        SovereignPresenceStateManager.shared.resetForTesting()
        savedProjectPaths = WorkspaceSettings.projectSearchPaths
        savedCompanionScopes = WorkspaceSettings.companionScopes
        savedHermesBinary = WorkspaceSettings.hermesBinaryPath
    }

    override func tearDown() {
        WorkspaceSettings.projectSearchPaths = savedProjectPaths
        WorkspaceSettings.companionScopes = savedCompanionScopes
        WorkspaceSettings.hermesBinaryPath = savedHermesBinary
        for root in tempRoots { try? FileManager.default.removeItem(at: root) }
        tempRoots = []
        EmergencyStopManager.shared.resetEmergencyStop()
        SovereignPresenceStateManager.shared.resetForTesting()
        super.tearDown()
    }

    /// A throwaway directory that is cleaned up in tearDown.
    private func makeTempRoot(_ name: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("atlas-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    @discardableResult
    private func run(_ args: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// A directory that is a real git repository, so git-root resolution has
    /// something true to resolve.
    private func makeGitRepo(named name: String, in root: URL) throws -> URL {
        let repo = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "# \(name)".write(to: repo.appendingPathComponent("README.md"),
                              atomically: true, encoding: .utf8)
        try run(["git", "init", "--quiet"], in: repo)
        return repo
    }

    // 1. Hermes Auth Failure State Reporting
    func testHermesAuthFailureStateReporting() throws {
        let connector = HermesConnector.shared

        // checkServices reports "binary missing" before it looks at auth state,
        // so the auth branch is only reachable when something is there to run.
        // Previously this passed only on a machine with hermes installed.
        let root = try makeTempRoot("hermes")
        let binary = root.appendingPathComponent("hermes")
        FileManager.default.createFile(atPath: binary.path, contents: Data(),
                                       attributes: [.posixPermissions: 0o755])
        WorkspaceSettings.hermesBinaryPath = binary.path
        defer { WorkspaceSettings.hermesBinaryPath = savedHermesBinary }

        connector.updateAuthState(.loginRequired)

        let statuses = connector.checkServices()
        guard let hermesStatus = statuses.first(where: { $0.id == "hermes" }) else {
            XCTFail("Hermes status must be present")
            return
        }

        XCTAssertFalse(hermesStatus.isOnline, "Unauthenticated Hermes must be marked offline")
        XCTAssertTrue(hermesStatus.detail.contains("Login Required"), "Unauthenticated state must give actionable login message")
    }

    // 2. Adversarial Command Injection Payload Escapes
    func testAdversarialCommandEscapesRemainInert() {
        let adversarialArgs = [
            "\"quoted\"; echo 'INJECTED'",
            "`id`",
            "$(whoami)",
            "test | cat /etc/passwd",
            "foo > /tmp/hacked.txt",
            "line1\nline2"
        ]

        let action = AtlasStructuredAction(
            toolIdentifier: "unit_test_safe",
            targetPath: "/Users/tester/Documents",
            executablePath: "/bin/echo",
            arguments: adversarialArgs,
            riskTier: .readOnly
        )

        let req = AtlasApprovalRequest(
            title: "Adversarial Test",
            details: "Payload contains shell metacharacters",
            riskTier: .readOnly,
            actionPayload: "adversarial",
            structuredAction: action
        )

        let ledger = ActivityLedger.shared
        ledger.requestApproval(req)

        let execResult = ledger.executeApproval(id: req.id)
        XCTAssertTrue(execResult, "Direct Process URL execution should succeed without shell interpretation")

        let approvals = ledger.fetchAllApprovals()
        guard let updatedReq = approvals.first(where: { $0.id == req.id }),
              let output = updatedReq.executionOutput else {
            XCTFail("Updated approval record must exist")
            return
        }

        XCTAssertTrue(output.contains("\"quoted\"; echo 'INJECTED'"), "Quotes and semicolons must remain literal arguments")
        XCTAssertTrue(output.contains("`id`"), "Backticks must remain literal arguments")
        XCTAssertTrue(output.contains("$(whoami)"), "Subshell syntax must remain literal arguments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/hacked.txt"), "Shell redirect must NOT create files")
    }

    // 3. Emergency Stop Process Termination
    func testEmergencyStopTerminatesActiveProcess() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]

        ProcessRegistry.shared.register(process)

        do {
            try process.run()
            XCTAssertTrue(process.isRunning, "Sleep process should be running before emergency stop")

            EmergencyStopManager.shared.triggerEmergencyStop()

            Thread.sleep(forTimeInterval: 0.15)

            XCTAssertFalse(process.isRunning, "Running process must be terminated when Emergency Stop is triggered")
        } catch {
            XCTFail("Failed to run test sleep process: \(error)")
        }
    }

    // 4. Path Traversal & Symlink Escapes
    func testPathTraversalAndSymlinkEscapesBlocked() {
        let validator = PathValidator.shared
        let allowedScopes = ["/Users/tester/Documents", "/Users/tester/code"]

        XCTAssertFalse(validator.isPathPermitted("/Users/tester/Documents/../Desktop/secret.txt", allowedScopes: allowedScopes), "Path traversal using .. must be blocked")
        XCTAssertFalse(validator.isPathPermitted("/Users/tester/Documents-evil/data.txt", allowedScopes: allowedScopes), "Similar prefix path without path separator must be blocked")
        XCTAssertTrue(validator.isPathPermitted("/Users/tester/Documents/Developer/ATLAS", allowedScopes: allowedScopes), "Valid child path inside permitted scope must be allowed")
        XCTAssertTrue(validator.validateObsidianURI("obsidian://open?vault=Mythos%20Vault&file=Notes"), "Valid obsidian URI should pass")
        XCTAssertFalse(validator.validateObsidianURI("obsidian://open?file=../secret"), "Obsidian URI with path traversal must be rejected")
        XCTAssertFalse(validator.validateObsidianURI("http://evil.com"), "Non-obsidian scheme must be rejected")
    }

    // 5. Approval Exact Once Execution
    func testApprovalExecutesExactlyOnce() {
        let ledger = ActivityLedger.shared
        let action = AtlasStructuredAction(
            toolIdentifier: "test_echo",
            targetPath: "/Users/tester/Documents",
            executablePath: "/bin/echo",
            arguments: ["ATLAS_APPROVAL_OK"],
            riskTier: .readOnly
        )

        let req = AtlasApprovalRequest(
            title: "Exact Once Action",
            details: "Echo test",
            riskTier: .readOnly,
            actionPayload: "echo",
            structuredAction: action
        )

        ledger.requestApproval(req)

        let firstExec = ledger.executeApproval(id: req.id)
        XCTAssertTrue(firstExec, "First execution should succeed")

        let secondExec = ledger.executeApproval(id: req.id)
        XCTAssertFalse(secondExec, "Second execution attempt must return false")

        guard let updated = ledger.fetchAllApprovals().first(where: { $0.id == req.id }) else {
            XCTFail("Record must persist")
            return
        }

        XCTAssertEqual(updated.executionCount, 1, "Execution count must equal 1")
        XCTAssertEqual(updated.status, .executed, "Status must be .executed")
    }

    // 6. Rejected Actions Never Execute
    func testRejectedActionsNeverExecute() {
        let ledger = ActivityLedger.shared
        let action = AtlasStructuredAction(
            toolIdentifier: "test_reject",
            targetPath: "/Users/tester/Documents",
            executablePath: "/usr/bin/touch",
            arguments: ["/tmp/atlas_should_not_execute.txt"],
            riskTier: .destructive
        )

        let req = AtlasApprovalRequest(
            title: "Reject Test Action",
            details: "Touch file",
            riskTier: .destructive,
            actionPayload: "touch",
            structuredAction: action
        )

        ledger.requestApproval(req)
        ledger.rejectApproval(id: req.id)

        let execResult = ledger.executeApproval(id: req.id)
        XCTAssertFalse(execResult, "Rejected action must NOT execute")

        guard let updated = ledger.fetchAllApprovals().first(where: { $0.id == req.id }) else {
            XCTFail("Record must persist")
            return
        }

        XCTAssertEqual(updated.status, .rejected, "Status must be .rejected")
        XCTAssertEqual(updated.executionCount, 0, "Execution count for rejected action must be 0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/atlas_should_not_execute.txt"), "Rejected binary must not execute")
    }

    // 7. Bounded Context Excludes Secrets
    func testBoundedContextBuilderExcludesSecretsAndEnforcesLimits() {
        let builder = BoundedContextBuilder.shared

        XCTAssertFalse(builder.isSafeFile(path: "/Users/tester/app/.env"), ".env files must be excluded")
        XCTAssertFalse(builder.isSafeFile(path: "/Users/tester/app/auth.json"), "auth.json files must be excluded")
        XCTAssertFalse(builder.isSafeFile(path: "/Users/tester/app/.git/config"), ".git directory files must be excluded")
        XCTAssertFalse(builder.isSafeFile(path: "/Users/tester/app/state.db"), ".db database files must be excluded")

        XCTAssertTrue(builder.isSafeFile(path: "/Users/tester/app/README.md"), "README.md should be safe")
        XCTAssertTrue(builder.isSafeFile(path: "/Users/tester/app/Package.swift"), "Package.swift should be safe")
    }

    // 8. Controlled Fixture Test for Globally Newest Notes Across Vaults
    func testControlledFixtureGloballyNewestNotesAcrossVaults() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vault1Dir = tempDir.appendingPathComponent("Vault1")
        let vault2Dir = tempDir.appendingPathComponent("Vault2")
        let hiddenDir = vault1Dir.appendingPathComponent(".obsidian")

        try fm.createDirectory(at: vault1Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: vault2Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: hiddenDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        let now = Date()
        let oldDate = now.addingTimeInterval(-86400 * 10)
        let midDate = now.addingTimeInterval(-86400 * 2)
        let newestDate = now.addingTimeInterval(-3600)
        let ultraNewestDateInHidden = now

        let file1 = vault1Dir.appendingPathComponent("Old.md")
        try "Old content".write(to: file1, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: file1.path)

        let file2 = vault2Dir.appendingPathComponent("Mid.md")
        try "Mid content".write(to: file2, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: midDate], ofItemAtPath: file2.path)

        let file3 = vault1Dir.appendingPathComponent("Newest.md")
        try "Newest content".write(to: file3, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: newestDate], ofItemAtPath: file3.path)

        let file4 = hiddenDir.appendingPathComponent("Hidden.md")
        try "Hidden content".write(to: file4, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: ultraNewestDateInHidden], ofItemAtPath: file4.path)

        let testVaults = [
            AtlasVault(id: "v1", name: "Vault1", path: vault1Dir.path),
            AtlasVault(id: "v2", name: "Vault2", path: vault2Dir.path)
        ]

        let scanner = ObsidianScanner.shared
        let newest2 = scanner.fetchGloballyNewestNotes(vaults: testVaults, limit: 2)

        XCTAssertEqual(newest2.count, 2, "Limit parameter must be strictly respected")
        XCTAssertEqual(newest2[0].title, "Newest", "Top note must be genuinely newest across all vaults")
        XCTAssertEqual(newest2[1].title, "Mid", "Second note must be second newest")
        XCTAssertFalse(newest2.contains(where: { $0.title == "Hidden" }), "Hidden directory notes (.obsidian) must be excluded")
    }

    // 9. Hermes Auth State Transitions
    func testHermesAuthStateTransitions() {
        let connector = HermesConnector.shared

        connector.updateAuthState(.unknown)
        XCTAssertEqual(connector.authState, .unknown)

        connector.updateAuthState(.loginRequired)
        XCTAssertEqual(connector.authState, .loginRequired)

        connector.updateAuthState(.authenticationExpired)
        XCTAssertEqual(connector.authState, .authenticationExpired)

        connector.updateAuthState(.authenticated)
        XCTAssertEqual(connector.authState, .authenticated)
    }

    // 10. Project Discovery Follows The Configured Search Paths
    func testProjectDiscoveryFollowsConfiguredSearchPaths() throws {
        let root = try makeTempRoot("projects")
        try makeGitRepo(named: "alpha", in: root)
        try makeGitRepo(named: "Beta Project", in: root)
        // Noise the scan is expected to skip.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)

        let scanner = ProjectScanner.shared

        WorkspaceSettings.projectSearchPaths = []
        XCTAssertTrue(scanner.discoverProjects().isEmpty,
                      "With no search path configured the scan must find nothing rather than guess one")

        WorkspaceSettings.projectSearchPaths = [root.path]
        let names = scanner.discoverProjects().map { $0.name }

        XCTAssertTrue(names.contains("alpha"), "a repository in the search path must be discovered")
        XCTAssertTrue(names.contains("Beta Project"), "a repository whose name contains a space must be discovered")
        XCTAssertFalse(names.contains("node_modules"), "node_modules must be skipped")
    }

    // 11. Git Root Resolution & Honest Non-Git State
    //
    // Builds both cases in a temporary directory. The previous version asserted
    // against folders on one developer's machine, so it failed whenever those
    // moved — a stale expectation reported as a code failure.
    func testGitRootResolutionAndHonestNonGitState() throws {
        let scanner = ProjectScanner.shared
        let root = try makeTempRoot("gitroot")

        // A folder that is genuinely not a repository, with a Procfile in it.
        let plain = root.appendingPathComponent("plain-folder")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try "web: node server.js".write(to: plain.appendingPathComponent("Procfile"),
                                        atomically: true, encoding: .utf8)

        let inspected = try XCTUnwrap(scanner.inspectProject(path: plain.path))
        XCTAssertFalse(inspected.isGitRepository,
                       "a folder without a .git must not be reported as a repository")
        XCTAssertEqual(inspected.gitStatus, "Git not initialized",
                       "a non-git folder must say so rather than report a clean tree")
        XCTAssertEqual(inspected.deploymentStatus, "Railway configuration detected",
                       "a Procfile must be detected")

        // A real repository resolves to its own root.
        let repo = try makeGitRepo(named: "repo", in: root)
        let repoProject = try XCTUnwrap(scanner.inspectProject(path: repo.path))
        XCTAssertTrue(repoProject.isGitRepository, "an initialised repository must be detected")
        XCTAssertEqual(
            repoProject.gitRootPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            repo.resolvingSymlinksInPath().path,
            "git root must resolve to the repository itself")

        // A subdirectory resolves to the repository above it, not to itself.
        let nested = repo.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let nestedProject = try XCTUnwrap(scanner.inspectProject(path: nested.path))
        XCTAssertEqual(
            nestedProject.gitRootPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
            repo.resolvingSymlinksInPath().path,
            "a path inside a repository must resolve to the repository root")
    }

    // 12. Scope Enforcement, Real Nonzero Exit Code & Command Cancellation
    func testCommandExecutionScopeNonzeroAndCancellation() throws {
        let companion = LocalCompanion.shared
        let root = try makeTempRoot("companion")
        let repo = try makeGitRepo(named: "work", in: root)

        // Outside every configured scope, nothing runs at all.
        WorkspaceSettings.companionScopes = []
        let refused = companion.executeCommand(command: "git status", projectPath: repo.path)
        XCTAssertEqual(refused.exitCode, 401,
                       "with no scope configured the Companion must refuse rather than run")

        WorkspaceSettings.companionScopes = [root.path]

        // Non-zero exit code
        let failResult = companion.executeCommand(command: "git status --invalid-flag",
                                                  projectPath: repo.path)
        XCTAssertFalse(failResult.isSuccess, "Invalid git flag must result in failure")
        XCTAssertNotEqual(failResult.exitCode, 0, "Process exit code must be non-zero on error")

        // Command cancellation. The command has to still be running when cancel
        // arrives — anything that finishes first passes the assertion without
        // testing anything. `tail -f` on a file that never grows blocks until
        // it is killed, which is exactly the condition under test.
        //
        // Note the command is split on spaces before it is run, so no argument
        // here may contain one.
        let exp = expectation(description: "Cancelled command execution")

        DispatchQueue.global(qos: .userInitiated).async {
            let cancelResult = companion.executeCommand(
                command: "tail -f \(repo.appendingPathComponent("README.md").path)",
                projectPath: repo.path,
                onHandleAssigned: { handle in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                        handle.cancel()
                    }
                }
            )

            XCTAssertTrue(cancelResult.isCancelled, "Cancelled command result must have isCancelled == true")
            XCTAssertEqual(cancelResult.exitCode, -1, "Cancelled command exitCode must be -1")
            exp.fulfill()
        }

        waitForExpectations(timeout: 10.0)
    }

    // 13. Git Porcelain Parsing Categories
    func testGitPorcelainCategoryParsing() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AtlasGitTest_" + UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["init"]
        p.currentDirectoryURL = tempDir
        try p.run()
        p.waitUntilExit()

        let untrackedFile = tempDir.appendingPathComponent("untracked.txt")
        try "untracked".write(to: untrackedFile, atomically: true, encoding: .utf8)

        let scanner = ProjectScanner.shared
        guard let proj = scanner.inspectProject(path: tempDir.path) else {
            XCTFail("Project inspection must succeed")
            return
        }

        XCTAssertTrue(proj.isGitRepository)
        XCTAssertTrue(proj.untrackedFiles.contains("untracked.txt"), "Porcelain parsing must place ?? into untrackedFiles")
        XCTAssertEqual(proj.stagedFiles.count, 0)
    }

    // 14. Deployment Target Label Honesty
    func testDeploymentTargetLabelHonesty() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("AtlasDeployTest_" + UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fm.removeItem(at: tempDir)
        }

        let scanner = ProjectScanner.shared

        // No config
        let projNoConfig = scanner.inspectProject(path: tempDir.path)
        XCTAssertEqual(projNoConfig?.deploymentStatus, "No deployment configuration detected")

        // Add vercel.json
        let vercelJson = tempDir.appendingPathComponent("vercel.json")
        try "{}".write(to: vercelJson, atomically: true, encoding: .utf8)

        let projVercel = scanner.inspectProject(path: tempDir.path)
        XCTAssertEqual(projVercel?.deploymentStatus, "Vercel configuration detected")
    }

    // 15. Mission Token Preserved Across Processing and Speaking
    func testMissionTokenPreservedAcrossProcessingAndSpeaking() {
        let manager = SovereignPresenceStateManager.shared
        let mission = manager.beginMission(description: "Unit Test Mission")

        XCTAssertEqual(manager.currentState, .processing)
        XCTAssertTrue(manager.isMissionActive(mission))

        let transitioned = manager.transition(to: .speaking, for: mission)
        XCTAssertTrue(transitioned, "Transition to speaking must succeed for active mission token")
        XCTAssertEqual(manager.currentState, .speaking)
        XCTAssertTrue(manager.isMissionActive(mission), "Mission token must remain active after speaking transition")
    }

    // 16. Valid Completion After Speaking Accepted
    func testValidCompletionAfterSpeakingAccepted() {
        let manager = SovereignPresenceStateManager.shared
        let mission = manager.beginMission()
        manager.transition(to: .speaking, for: mission)

        manager.completeMission(mission, endingState: .idle)
        XCTAssertEqual(manager.currentState, .idle)
        XCTAssertFalse(manager.isMissionActive(mission))
    }

    // 17. Approval State Preserves Active Mission
    func testApprovalStatePreservesMission() {
        let manager = SovereignPresenceStateManager.shared
        let mission = manager.beginMission()

        let transitioned = manager.transition(to: .awaitingApproval, for: mission)
        XCTAssertTrue(transitioned)
        XCTAssertEqual(manager.currentState, .awaitingApproval)
        XCTAssertTrue(manager.isMissionActive(mission), "Awaiting approval must preserve active mission token")
    }

    // 18. Cancellation Invalidates Mission Immediately
    func testCancellationInvalidatesMissionImmediately() {
        let manager = SovereignPresenceStateManager.shared
        let mission = manager.beginMission()

        manager.interruptMission(mission)
        XCTAssertEqual(manager.currentState, .interrupted)
        XCTAssertFalse(manager.isMissionActive(mission), "Interruption must invalidate mission token immediately")
    }

    // 19. Delayed Interruption Settling Cannot Overwrite Newer Mission
    func testDelayedInterruptionSettlingCannotOverwriteNewerMission() {
        let manager = SovereignPresenceStateManager.shared
        let m1 = manager.beginMission(description: "Mission 1")
        manager.interruptMission(m1)

        let m2 = manager.beginMission(description: "Mission 2")
        XCTAssertEqual(manager.currentState, .processing)

        let exp = expectation(description: "Wait for M1 settling timer")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
            XCTAssertEqual(manager.currentState, .processing, "M1 settling timer must NOT overwrite M2 state")
            XCTAssertTrue(manager.isMissionActive(m2))
            exp.fulfill()
        }

        waitForExpectations(timeout: 2.0)
    }

    // 20. Stale Callbacks Cannot Alter Newer Mission
    func testStaleCallbacksCannotAlterNewerMission() {
        let manager = SovereignPresenceStateManager.shared
        let m1 = manager.beginMission(description: "Mission 1")
        let m2 = manager.beginMission(description: "Mission 2")

        let result = manager.transition(to: .speaking, for: m1)
        XCTAssertFalse(result, "Transition attempt for stale token m1 must be rejected")
        XCTAssertEqual(manager.currentState, .processing, "State must remain processing for m2")
        XCTAssertTrue(manager.isMissionActive(m2))
    }

    // 21. Normal Cancel Terminates Only Active Hermes Request
    func testNormalCancelTerminatesOnlyActiveHermesRequest() throws {
        let pA = Process()
        pA.executableURL = URL(fileURLWithPath: "/bin/sleep")
        pA.arguments = ["30"]
        try pA.run()

        ProcessRegistry.shared.register(pA)
        defer {
            if pA.isRunning { pA.terminate() }
            ProcessRegistry.shared.unregister(pA)
        }

        let handle = HermesConnector.shared.sendMessage(
            prompt: "Scoped Cancel Test",
            onToken: { _ in },
            onCompletion: { _ in }
        )
        handle.cancel()

        XCTAssertTrue(handle.isCancelled, "Handle must report isCancelled = true")
        XCTAssertTrue(pA.isRunning, "Normal Cancel must stop ONLY the active Hermes request, leaving process A running")
    }

    // 22. Emergency Stop Terminates All Registered Processes
    func testEmergencyStopTerminatesAllRegisteredProcesses() throws {
        let pB = Process()
        pB.executableURL = URL(fileURLWithPath: "/bin/sleep")
        pB.arguments = ["30"]
        try pB.run()

        ProcessRegistry.shared.register(pB)

        EmergencyStopManager.shared.triggerEmergencyStop()

        XCTAssertFalse(pB.isRunning, "Emergency Stop MUST terminate all registered processes")
        EmergencyStopManager.shared.resetEmergencyStop()
    }

    // 23. Deterministic Render Parameter Mapping
    func testDeterministicRenderParameterMapping() {
        let normIdle = calculateNormalizedRenderParameters(state: .idle)
        XCTAssertEqual(normIdle.primaryColorTag, "gold")

        let normSpeaking = calculateNormalizedRenderParameters(
            state: .speaking,
            audio: AudioEnergyFrame(rmsLoudness: 0.8, bassEnergy: 0.5, midEnergy: 0.6, trebleEnergy: 0.4)
        )
        XCTAssertGreaterThan(normSpeaking.coreRadius, normIdle.coreRadius, "Audio RMS volume must dynamically expand core radius")

        let normError = calculateNormalizedRenderParameters(state: .error)
        XCTAssertEqual(normError.primaryColorTag, "red")
    }

    // 24. Test Isolation Reset
    func testTestIsolationReset() {
        let manager = SovereignPresenceStateManager.shared
        manager.beginMission(description: "Test")
        manager.resetForTesting()

        XCTAssertNil(manager.activeMission)
        XCTAssertEqual(manager.currentState, .idle)
    }
}

