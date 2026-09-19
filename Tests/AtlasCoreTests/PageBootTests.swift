import XCTest
import WebKit
@testable import AtlasCore

/// Loads each bundled page in a real web view and checks it actually came up.
///
/// This exists because a whole day's bugs lived in the seam between Swift and
/// the pages while every other test stayed green: a double-wrapped script call
/// left the calendar blank, and a failed sibling script load left the canvas
/// inert. Both rendered fine — static HTML always does — but nothing was wired
/// up. Only booting the page catches that.
@MainActor
final class PageBootTests: XCTestCase {

    /// Loads a page and returns what the expression evaluates to.
    private func boot(_ page: URL, injecting scripts: [String] = [],
                      width: CGFloat = 900,
                      evaluating expression: String) async throws -> String {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        // Same message handler name the app registers, so pages that post on
        // startup do not throw against a missing handler.
        config.userContentController.add(SilentHandler(), name: "atlas")
        // The app injects the shared sheet into every page, and it carries
        // `html, body { height: 100% }`, which page layouts depend on. Without it
        // here a test can pass on a layout that collapses in the real app — which
        // is exactly how an unscrollable transcript got through.
        if let shared = AtlasResources.sharedStyles {
            config.userContentController.addUserScript(
                WKUserScript(source: Self.styleInjection(shared),
                             injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        for script in scripts + [fixture] {
            config.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let webView = WKWebView(frame: .init(x: 0, y: 0, width: width, height: 700), configuration: config)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadFileURL(page, allowingReadAccessTo: page)
        try await delegate.wait()

        let result = try await webView.evaluateJavaScript(expression)
        return String(describing: result ?? "nil")
    }


    /// Wraps CSS in a script that inserts it as the first style in <head>,
    /// the same order `addAtlasSharedStyles` uses in the app.
    private static func styleInjection(_ css: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [css])
        let array = String(data: data, encoding: .utf8)!
        let literal = String(array.dropFirst().dropLast())
        return """
        (function(){
          var s = document.createElement('style');
          s.textContent = \(literal);
          var root = document.head || document.documentElement;
          root.insertBefore(s, root.firstChild);
        })();
        """
    }

    /// A small canvas: one text node, one file node.
    private var fixture: String { """
    window.loadFixture = function(){
      window.atlasCanvas.loaded(JSON.stringify({
        path: '/tmp/x.canvas', name: 'x',
        nodes: [{id:'n1', type:'text', text:'hello', x:0, y:0, width:200, height:100},
                {id:'n2', type:'file', file:'Images/a.png', x:300, y:0, width:200, height:100}],
        edges: []
      }));
    };
    """ }

    private var markdown: String {
        get throws { try XCTUnwrap(AtlasResources.markdownScript, "markdown.js must ship") }
    }

    func testTranscriptPageExposesItsApi() async throws {
        let page = try XCTUnwrap(AtlasResources.chatPage)
        let kind = try await boot(page, injecting: [markdown],
                                  evaluating: "typeof window.atlasChat")
        XCTAssertEqual(kind, "object", "chat.html did not finish wiring itself up")
    }

    func testTranscriptRendersMarkdownRatherThanRawText() async throws {
        let page = try XCTUnwrap(AtlasResources.chatPage)
        let html = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          window.atlasChat.setAll(JSON.stringify([
            {id:'x', role:'Sovereign', subtitle:'', text:'## Heading', streaming:false, files:[], reasoning:''}
          ]));
          return document.querySelector('#log').innerHTML;
        })()
        """)
        XCTAssertTrue(html.contains("<h2>Heading</h2>"),
                      "markdown must render; got: \(html.prefix(200))")
    }

    /// Dragging a node moves it and marks the file changed — and only then.
    // MARK: - CRM

    /// The CRM page must come up, expose its API and ask for data — the same
    /// seam that has silently broken on every other page at least once.
    func testCRMPageBootsAndAsksForData() async throws {
        let page = try XCTUnwrap(AtlasResources.crmPage)
        let ready = try await boot(page, evaluating: """
        typeof window.atlasCRM === 'object'
          && typeof window.atlasCRM.render === 'function'
          && typeof window.atlasCRM.error === 'function'
          && typeof window.atlasCRM.confirmDelete === 'function'
        """)
        XCTAssertEqual(ready, "1", "crm.html did not expose window.atlasCRM")
    }

    /// With nothing in the database the overview offers a way to start rather
    /// than showing a blank pane.
    func testCRMEmptyStateOffersAFirstAction() async throws {
        let page = try XCTUnwrap(AtlasResources.crmPage)
        let text = try await boot(page, evaluating: """
        (() => {
          window.atlasCRM.render(JSON.stringify({
            query: '', schemaVersion: 2,
            summary: { openCount: 0, openValueCents: 0, weightedValueCents: 0, wonCount: 0,
                       wonValueCents: 0, needingFollowUp: 0, companyCount: 0, contactCount: 0 },
            stages: [], companyStatuses: [], contactMethods: [], activityKinds: [],
            companies: [], contacts: [], opportunities: [], followUps: [], activities: []
          }));
          return document.querySelector('.atlas-empty__title').textContent + '|' +
                 document.querySelectorAll('.atlas-empty__actions button').length;
        })()
        """)
        XCTAssertEqual(text, "Nothing tracked yet|2")
    }

    /// A company named with a script tag renders as text. This is the check that
    /// matters most on a page that displays whatever the user typed.
    func testCRMEscapesRecordText() async throws {
        let page = try XCTUnwrap(AtlasResources.crmPage)
        let result = try await boot(page, evaluating: """
        (() => {
          window.__xss = false;
          window.atlasCRM.render(JSON.stringify({
            query: '', schemaVersion: 2,
            summary: { openCount: 1, openValueCents: 100, weightedValueCents: 50, wonCount: 0,
                       wonValueCents: 0, needingFollowUp: 0, companyCount: 1, contactCount: 0 },
            stages: [{ id: 'lead', title: 'Lead' }],
            companyStatuses: [{ id: 'prospect', title: 'Prospect' }],
            contactMethods: [], activityKinds: [{ id: 'note', title: 'Note' }],
            companies: [{ id: 'c1', name: '<img src=x onerror="window.__xss=true">',
                          website: '', phone: '', address: '', industry: '',
                          status: 'prospect', notes: '', createdAt: 0, updatedAt: 0 }],
            contacts: [], opportunities: [], followUps: [],
            activities: [{ id: 'a1', companyId: 'c1', contactId: '', opportunityId: '',
                           kind: 'note', summary: '<b>bold?</b>', occurredAt: 0 }]
          }));
          document.querySelector('#tabs button[data-tab=\"companies\"]').click();
          const row = document.querySelector('.row .nm');
          return [window.__xss, document.querySelectorAll('img').length,
                  row ? row.textContent : 'no row',
                  document.querySelectorAll('.feed b').length].join('|');
        })()
        """)
        XCTAssertEqual(result,
            "false|0|<img src=x onerror=\"window.__xss=true\">|0",
            "record text must render as text, never as markup")
    }

    func testCanvasNodeCanBeDragged() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const surface = document.getElementById('surface');
          const el = document.querySelector('.node[data-id="n1"]');
          const box = el.getBoundingClientRect();
          el.dispatchEvent(new PointerEvent('pointerdown',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          surface.dispatchEvent(new PointerEvent('pointermove',
            {bubbles:true, clientX:box.x+120, clientY:box.y+90, button:0}));
          surface.dispatchEvent(new PointerEvent('pointerup',
            {bubbles:true, clientX:box.x+120, clientY:box.y+90, button:0}));
          const after = document.querySelector('.node[data-id="n1"]');
          return after.style.left + ',' + after.style.top + ',' +
                 document.getElementById('dirty').style.visibility;
        })()
        """)
        let parts = out.split(separator: ",").map(String.init)
        XCTAssertNotEqual(parts.first, "0px", "the node should have moved")
        XCTAssertEqual(parts.last, "visible", "a real move marks the file changed")
    }

    /// Selecting without moving must NOT mark the file changed — that bug had
    /// the title bar crying wolf and inviting a save over an untouched canvas.
    func testClickingWithoutMovingLeavesTheFileClean() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let dirty = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const el = document.querySelector('.node[data-id="n1"]');
          const box = el.getBoundingClientRect();
          el.dispatchEvent(new PointerEvent('pointerdown',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          document.getElementById('surface').dispatchEvent(new PointerEvent('pointerup',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          return document.getElementById('dirty').style.visibility;
        })()
        """)
        XCTAssertEqual(dirty, "hidden")
    }

    func testTextNodeBecomesEditableOnDoubleClick() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let editable = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const el = document.querySelector('.node[data-id="n1"]');
          el.dispatchEvent(new MouseEvent('dblclick', {bubbles:true}));
          return String(!!el.querySelector('textarea'));
        })()
        """)
        XCTAssertEqual(editable, "true")
    }

    /// A file node has nothing to type into, so double-clicking asks the app to
    /// open the file. Before this, most of a real canvas felt frozen.
    func testFileNodeAsksToOpenTheFile() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let sent = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          // Capture what the page posts back to the app.
          const posted = [];
          window.webkit.messageHandlers.atlas.postMessage = m => posted.push(m);
          const el = document.querySelector('.node[data-id="n2"]');
          el.dispatchEvent(new MouseEvent('dblclick', {bubbles:true}));
          return posted.join(' ');
        })()
        """)
        XCTAssertTrue(sent.contains("openFile"), "expected an openFile request, got: \(sent)")
        XCTAssertTrue(sent.contains("Images/a.png"))
    }

    /// Double-clicking empty canvas makes a note there and opens it for typing.
    /// Its absence was the single biggest reason the canvas felt unusable.
    func testDoubleClickOnEmptySpaceMakesANoteReadyToType() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const before = document.querySelectorAll('.node').length;
          document.getElementById('surface').dispatchEvent(
            new MouseEvent('dblclick', {bubbles:true, clientX:600, clientY:400}));
          const after = document.querySelectorAll('.node').length;
          return (after - before) + ',' + !!document.querySelector('.node textarea');
        })()
        """)
        XCTAssertEqual(out, "1,true", "one new note, already editable; got \(out)")
    }

    /// Selecting a node shows a toolbar. Without it, colour, duplicate and
    /// delete were only reachable by right-clicking, which nothing advertises.
    func testSelectingANodeShowsAToolbar() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const el = document.querySelector('.node[data-id="n1"]');
          const box = el.getBoundingClientRect();
          el.dispatchEvent(new PointerEvent('pointerdown',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          document.getElementById('surface').dispatchEvent(new PointerEvent('pointerup',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          const bar = document.getElementById('selBar');
          return bar.classList.contains('on') + ',' +
                 [...bar.querySelectorAll('button')].map(b => b.textContent).filter(Boolean).join('|') +
                 ',swatches=' + bar.querySelectorAll('.swatch').length;
        })()
        """)
        XCTAssertTrue(out.hasPrefix("true"), "the toolbar should appear; got \(out)")
        XCTAssertTrue(out.contains("Edit"), "a text node offers editing; got \(out)")
        XCTAssertTrue(out.contains("Delete"))
        XCTAssertTrue(out.contains("swatches=7"), "six colours plus clearing")
    }

    func testToolbarOffersOpenForAFileNode() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const el = document.querySelector('.node[data-id="n2"]');
          const box = el.getBoundingClientRect();
          el.dispatchEvent(new PointerEvent('pointerdown',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          document.getElementById('surface').dispatchEvent(new PointerEvent('pointerup',
            {bubbles:true, clientX:box.x+20, clientY:box.y+20, button:0}));
          return [...document.querySelectorAll('#selBar button')].map(b => b.textContent).join('|');
        })()
        """)
        XCTAssertTrue(out.contains("Open"), "a file node offers opening, not editing; got \(out)")
    }

    /// Nothing selected means no toolbar hanging about.
    func testToolbarHidesWhenNothingIsSelected() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let shown = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          return String(document.getElementById('selBar').classList.contains('on'));
        })()
        """)
        XCTAssertEqual(shown, "false")
    }

    func testRightClickOffersAMenu() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let items = try await boot(page, injecting: [markdown], evaluating: """
        (function(){
          loadFixture();
          const el = document.querySelector('.node[data-id="n2"]');
          el.dispatchEvent(new MouseEvent('contextmenu', {bubbles:true, clientX:50, clientY:50}));
          const menu = document.querySelector('.menu');
          if (!menu) return 'no menu';
          return [...menu.querySelectorAll('button')].map(b => b.textContent).join('|') +
                 ' swatches=' + menu.querySelectorAll('.swatch').length;
        })()
        """)
        XCTAssertTrue(items.contains("Open file"), "file nodes offer opening; got: \(items)")
        XCTAssertTrue(items.contains("Delete"))
        XCTAssertTrue(items.contains("swatches=7"), "six Obsidian colours plus clearing")
    }

    func testCanvasPageExposesItsApi() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let kind = try await boot(page, injecting: [markdown],
                                  evaluating: "typeof window.atlasCanvas")
        XCTAssertEqual(kind, "object", "canvas.html did not finish wiring itself up")
    }

    /// The failure that actually happened: without the renderer the page must
    /// still come up, degraded, rather than dying on its first line.
    func testCanvasSurvivesAMissingRenderer() async throws {
        let page = try XCTUnwrap(AtlasResources.canvasPage)
        let kind = try await boot(page, evaluating: "typeof window.atlasCanvas")
        XCTAssertEqual(kind, "object", "canvas.html must not depend on the renderer to boot")
    }

    func testCalendarAndBoardPagesExposeTheirApis() async throws {
        let calendar = try XCTUnwrap(AtlasResources.calendarPage)
        let calendarKind = try await boot(calendar, evaluating: "typeof window.atlasCalendar")
        XCTAssertEqual(calendarKind, "object", "calendar.html did not wire itself up")

        // The board loads Sortable from beside it, so it needs folder access.
        let board = try XCTUnwrap(AtlasResources.kanbanPage)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(SilentHandler(), name: "atlas")
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: config)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadFileURL(board, allowingReadAccessTo: board.deletingLastPathComponent())
        try await delegate.wait()

        let boardKind = try await webView.evaluateJavaScript("typeof window.atlasBoard")
        XCTAssertEqual(String(describing: boardKind ?? "nil"), "object",
                       "kanban.html did not wire itself up")
        let sortable = try await webView.evaluateJavaScript("typeof Sortable")
        XCTAssertEqual(String(describing: sortable ?? "nil"), "function",
                       "the vendored Sortable did not load")
    }

    func testHUDPageBootsAndReceivesSovereignStateTelemetry() async throws {
        let page = try XCTUnwrap(AtlasResources.hudPage)
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(SilentHandler(), name: "atlas")
        let webView = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: config)
        let delegate = LoadWaiter()
        webView.navigationDelegate = delegate
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        try await delegate.wait()

        let payload = HUDPayload(
            generatedEpoch: 1700000000,
            voiceAvailable: true,
            voiceState: "ready",
            voiceDetail: "Sovereign Voice Ready",
            sovereignState: "processing",
            fieldWorld: 0,
            voiceEnergy: 0.8,
            audioEnergy: HUDPayload.AudioEnergy(rms: 0.8, bass: 0.7, mid: 0.6, treble: 0.5),
            vitals: SystemTelemetry.shared.sample(),
            cron: HUDPayload.Cron(jobs: [], healthy: 0, failing: 0, activeIncidents: 0, loggedIncidents: 0),
            sessions: HUDPayload.Sessions(totalCost: 0, todayCost: 0, transcripts: 0, inputTokens: 0, cacheWriteTokens: 0, cacheReadTokens: 0, outputTokens: 0, dailyCosts: [], dailyLabels: [], byModel: [], unpricedModels: [:], isScanning: false),
            brief: HUDPayload.Brief(greeting: "Good Morning", dateLine: "MON 7 SEP", events: [], overdueTasks: 0, calendarAuthorized: true, remindersAuthorized: true),
            workspace: HUDPayload.Workspace(loaded: true, projects: [], projectCount: 0, noteCount: 0, notes: [], pendingApprovals: 0, services: []),
            usage: HUDPayload.Usage(configured: false, stale: true, ageSeconds: 0, fiveHourPercent: nil, fiveHourResetsInSeconds: nil, sevenDayPercent: nil, sevenDayResetsInSeconds: nil, contextPercent: nil, sessionCostUSD: nil, modelName: nil)
        )

        let escaped = payload.jsonString()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "")

        _ = try await webView.evaluateJavaScript("window.atlasRender(JSON.parse('\(escaped)'))")

        let pillText = try await webView.evaluateJavaScript("document.getElementById('modePill').textContent")
        XCTAssertEqual(String(describing: pillText ?? ""), "SOVEREIGN · PROCESSING")

        let stateGlobal = try await webView.evaluateJavaScript("window.__atlasSovereignState")
        XCTAssertEqual(String(describing: stateGlobal ?? ""), "processing")
    }

    // MARK: - Cinema

    /// Cinema must expose the hook Swift hands its stored library to, and its
    /// writes must go through `cinemaStore` rather than straight to
    /// localStorage — that split is the whole reason the library became
    /// recoverable.
    func testCinemaExposesItsStorageHook() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let ready = try await boot(page, evaluating: """
        typeof window.atlasCinemaState === 'function'
          && typeof cinemaStore === 'object'
          && typeof cinemaStore.getItem === 'function'
          && typeof cinemaStore.setItem === 'function'
        """)
        XCTAssertEqual(ready, "1", "cinema.html did not expose its store")
    }

    /// On a first run the database is empty, and the page answers by handing up
    /// whatever localStorage still holds. Losing this step is what would turn a
    /// migration into the data loss it exists to prevent.
    func testCinemaOffersItsLocalStorageForAdoption() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let sent = try await boot(page, evaluating: """
        (() => {
          localStorage.setItem('atlas_cinema_library_v1', '{"favorites":[{"id":1402}]}');
          const posted = [];
          window.webkit.messageHandlers.atlasBridge = { postMessage: m => posted.push(m) };
          window.atlasCinemaState(JSON.stringify({ ok: true, adopt: true, values: {} }));
          const adopt = posted.find(m => m.action === 'adoptState');
          return adopt ? adopt.values['atlas_cinema_library_v1'] : 'nothing offered';
        })()
        """)
        XCTAssertEqual(sent, #"{"favorites":[{"id":1402}]}"#)
    }

    /// Once the database holds a copy it is the authority, and the page adopts
    /// it rather than pushing its own cache back up.
    func testCinemaTakesTheStoredLibraryAsAuthoritative() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let out = try await boot(page, evaluating: """
        (() => {
          localStorage.setItem('atlas_cinema_source', 'stale');
          const posted = [];
          window.webkit.messageHandlers.atlasBridge = { postMessage: m => posted.push(m) };
          window.atlasCinemaState(JSON.stringify({
            ok: true, adopt: false, values: { atlas_cinema_source: 'videasy' }
          }));
          return localStorage.getItem('atlas_cinema_source') + '|' +
                 posted.filter(m => m.action === 'adoptState').length;
        })()
        """)
        XCTAssertEqual(out, "videasy|0")
    }

    /// A write reaches the bridge, not just the cache.
    func testCinemaWritesReachTheBridge() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let sent = try await boot(page, evaluating: """
        (() => {
          const posted = [];
          window.webkit.messageHandlers.atlasBridge = { postMessage: m => posted.push(m) };
          cinemaStore.setItem('atlas_cinema_source', 'archive');
          const save = posted.find(m => m.action === 'saveState');
          return save ? save.key + '=' + save.value : 'nothing sent';
        })()
        """)
        XCTAssertEqual(sent, "atlas_cinema_source=archive")
    }

    /// The carousel dots were 26x3 — a 78px² target, which is why they were
    /// almost impossible to hit. The visible bar is still 3px; the button around
    /// it is not.
    func testCinemaCarouselDotsAreBigEnoughToClick() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        // Computed style rather than a bounding box: at boot the hero has no
        // slides yet and lays out at zero, which measures the fixture rather
        // than the rule under test.
        let size = try await boot(page, evaluating: """
        (() => {
          const host = document.getElementById('heroDots');
          host.innerHTML = '<button data-slide="0"></button>';
          const style = getComputedStyle(host.querySelector('button'));
          // Not "x" as the separator: "26px" already contains one.
          return style.width + '|' + style.height;
        })()
        """)
        let parts = size.split(separator: "|")
            .compactMap { Double($0.replacingOccurrences(of: "px", with: "")) }
        let height = try XCTUnwrap(parts.last, "unexpected measurement: \(size)")
        XCTAssertGreaterThanOrEqual(height, 20,
            "a pointer target under ~24px tall is the bug this fixed; got \(size)")
    }

    /// Reload and Not working are the controls you need at the moment a source
    /// fails, and they were the faintest text on the page.
    func testCinemaRecoveryButtonsAreLegible() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let alpha = try await boot(page, evaluating: """
        (() => {
          const el = document.getElementById('srcBad');
          const colour = getComputedStyle(el).color;
          const match = colour.match(/rgba?\\(([^)]+)\\)/);
          const parts = match[1].split(',').map(s => parseFloat(s));
          return String(parts.length > 3 ? parts[3] : 1);
        })()
        """)
        let opacity = try XCTUnwrap(Double(alpha))
        XCTAssertGreaterThan(opacity, 0.4,
            "0.28 white on this ground is roughly 3:1 and unreadable; got \(alpha)")
    }

    /// The floating Cloud Sync button was `position: fixed; z-index: 8000` and
    /// covered the sheet's own overview text.
    func testCinemaHasNoFloatingButtonOverContent() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let found = try await boot(page, evaluating: """
        String(!!document.getElementById('floatingCloudSyncFab'))
        """)
        XCTAssertEqual(found, "false", "the overlapping cloud sync button is back")
    }

    /// The side rail's own regression guard.
    ///
    /// `.sources__pick` carries `flex: 1 1 420px` for the wide layout, where it
    /// is a width. The moment the rail turns that row into a column the same
    /// declaration becomes a 420px *height*, which opened a hole between the
    /// Source label and the pills big enough to push everything else off screen.
    /// The override only works because it sits after the base rule in the
    /// stylesheet — move it back up and this fails.
    func testCinemaSideRailDoesNotOpenAGap() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let out = try await boot(page, width: 1500, evaluating: """
        (() => {
          document.getElementById('sources').innerHTML =
            ['My Server','Archive','Living room','Study','Loft',
             'Backup','Garage','Attic','Basement']
            .map(n => '<button class="chip">' + n + '</button>').join('');
          const pick = document.querySelector('.sources__pick');
          const tops = [...document.querySelectorAll('.tab')]
            .map(t => Math.round(t.getBoundingClientRect().top));
          return Math.round(pick.getBoundingClientRect().height) + '|' +
                 new Set(tops).size;
        })()
        """)
        let parts = out.split(separator: "|")
        let pickHeight = try XCTUnwrap(parts.first.flatMap { Int($0) })
        let tabRows = try XCTUnwrap(parts.last.flatMap { Int($0) })

        XCTAssertLessThan(pickHeight, 200,
            "the source picker collapsed to a \\(pickHeight)px block — flex-basis is a height in a column")
        XCTAssertEqual(tabRows, 1, "all five tabs must stay on one line in the rail")
    }

    /// The Episodes header in the side rail.
    ///
    /// "Sync Season to Drive" was a long label in a pill inside a ~360px column,
    /// so the text wrapped inside the button and turned it into a four-line
    /// blob with the season picker jammed beside it. Checked across widths
    /// rather than at one, because the previous tab fix passed at 1500px and
    /// still wrapped on a narrower window.
    func testCinemaEpisodeControlsSurviveTheNarrowRail() async throws {
        for width in [1100.0, 1400.0, 1900.0] as [CGFloat] {
            let page = try XCTUnwrap(AtlasResources.cinemaPage)
            let out = try await boot(page, width: width, evaluating: """
            (() => {
              document.getElementById('tvControls').hidden = false;
              document.getElementById('seasonSelect').innerHTML =
                '<option>Season 1 · 8 ep</option>';
              const h = s => Math.round(
                document.querySelector(s).getBoundingClientRect().height);
              const tops = [...document.querySelectorAll('.tab')]
                .map(t => Math.round(t.getBoundingClientRect().top));
              return h('#seasonSelect') + '|' + new Set(tops).size;
            })()
            """)
            let parts = out.split(separator: "|")
            let seasonHeight = try XCTUnwrap(parts.first.flatMap { Int($0) })
            let tabRows = try XCTUnwrap(parts.last.flatMap { Int($0) })

            XCTAssertLessThan(seasonHeight, 50,
                "at \(Int(width))px the season picker is \(seasonHeight)px — its label wrapped inside the control")
            XCTAssertEqual(tabRows, 1, "tabs wrapped at \(Int(width))px")
        }
    }

    /// Renaming a source changes the pill and nothing else.
    ///
    /// The rename is display-only by design: the id is what resolves a title,
    /// so it has to survive being relabelled or the pill stops pointing at the
    /// server it names.
    func testCinemaSourceRenameIsDisplayOnly() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let out = try await boot(page, evaluating: """
        (() => {
          renderSources();
          const source = SOURCES.find(s => s.id === 'archive');
          renameSource('archive', 'Public domain');
          const pill = document.querySelector('[data-source="archive"]');
          // The rename is a label. The id is what resolves a title, and it stays.
          const idIsUntouched = source.id === 'archive';
          // Empty clears the override rather than storing a blank name.
          renameSource('archive', '   ');
          const restored = document.querySelector('[data-source="archive"]').textContent;
          return [pill.textContent, idIsUntouched, restored].join('|');
        })()
        """)
        XCTAssertEqual(out, "Public domain|true|Archive")
    }

    /// The rename is persisted, not just painted.
    func testCinemaSourceRenameReachesTheBridge() async throws {
        let page = try XCTUnwrap(AtlasResources.cinemaPage)
        let sent = try await boot(page, evaluating: """
        (() => {
          const posted = [];
          window.webkit.messageHandlers.atlasBridge = { postMessage: m => posted.push(m) };
          renameSource('jellyfin', 'Fast one');
          const save = posted.find(m => m.action === 'saveState' &&
                                        m.key === 'atlas_cinema_source_names');
          return save ? JSON.parse(save.value).jellyfin : 'not persisted';
        })()
        """)
        XCTAssertEqual(sent, "Fast one")
    }

    /// A snapped poster keeps the row's gutter.
    ///
    /// `scroll-snap-align: start` aligns to the scrollport edge, not the
    /// padding edge, so without `scroll-padding` a card lands flush at x=0 and
    /// its left side is clipped — one row indented, the next cut off.
    func testCinemaPosterRowsKeepTheirGutterWhenSnapped() async throws {
        for (width, gutter) in [(820.0, 26), (1400.0, 46)] as [(CGFloat, Int)] {
            let page = try XCTUnwrap(AtlasResources.cinemaPage)
            let out = try await boot(page, width: width, evaluating: """
            (() => {
              const track = document.createElement('div');
              track.className = 'rail__track';
              for (let i = 0; i < 10; i++) {
                const c = document.createElement('div');
                c.className = 'card';
                c.style.height = '250px';
                track.appendChild(c);
              }
              document.body.appendChild(track);
              const cs = getComputedStyle(track);
              return cs.paddingLeft + '|' + cs.scrollPaddingLeft;
            })()
            """)
            let parts = out.split(separator: "|").map(String.init)
            XCTAssertEqual(parts.first, "\(gutter)px", "padding changed at \(Int(width))px")
            XCTAssertEqual(parts.last, "\(gutter)px",
                "scroll-padding must match padding at \(Int(width))px, or snapped cards clip")
        }
    }

    // MARK: - Assistant

    /// The Assistant page must expose its API and ask for data.
    func testAssistantPageBootsAndAsksForData() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let ready = try await boot(page, injecting: [markdown], evaluating: """
        typeof window.atlasAssistant === 'object'
          && typeof window.atlasAssistant.setAll === 'function'
          && typeof window.atlasAssistant.conversations === 'function'
          && typeof window.atlasAssistant.settings === 'function'
          && typeof window.atlasAssistant.status === 'function'
          && typeof window.atlasAssistant.compact === 'function'
        """)
        XCTAssertEqual(ready, "1", "assistant.html did not expose window.atlasAssistant")
    }

    /// The transcript renderer is chat.html's, reached through delegation rather
    /// than copied. If that link breaks the page renders nothing and every other
    /// check here would still pass.
    func testAssistantStillRendersTranscriptsThroughTheSharedRenderer() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let html = try await boot(page, injecting: [markdown], evaluating: """
        (() => {
          window.atlasAssistant.setAll(JSON.stringify([
            {id:'x', role:'Sovereign', subtitle:'', text:'## Heading',
             streaming:false, files:[], reasoning:''}
          ]));
          return document.querySelector('#log').innerHTML;
        })()
        """)
        XCTAssertTrue(html.contains("<h2>Heading</h2>"),
                      "markdown must render; got: \(html.prefix(160))")
    }

    /// Model output is untrusted in the strictest sense here — it is chosen by a
    /// system that will say anything, including a string crafted to break out.
    func testAssistantEscapesModelOutput() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let result = try await boot(page, injecting: [markdown], evaluating: """
        (() => {
          window.__xss = false;
          window.atlasAssistant.setAll(JSON.stringify([
            {id:'m1', role:'Sovereign', subtitle:'',
             text:'<img src=x onerror="window.__xss=true">',
             streaming:false, files:[], reasoning:''}
          ]));
          return String(window.__xss) + '|' + document.querySelectorAll('#log img').length;
        })()
        """)
        XCTAssertEqual(result, "false|0", "model output must never execute")
    }

    /// Conversation titles are user text and reach the rail; same rule.
    func testAssistantEscapesConversationTitles() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let result = try await boot(page, injecting: [markdown], evaluating: """
        (() => {
          window.__xss = false;
          window.atlasAssistant.conversations(JSON.stringify({
            query:'', currentTitle:'',
            rows:[{id:'c1', title:'<img src=x onerror="window.__xss=true">',
                   model:'m', updated:'now', current:false}]
          }));
          return String(window.__xss) + '|' +
                 document.querySelectorAll('#convos img').length + '|' +
                 document.querySelector('#convos .ct').textContent;
        })()
        """)
        XCTAssertEqual(result,
            "false|0|<img src=x onerror=\"window.__xss=true\">",
            "titles must render as text")
    }

    /// While a reply streams, Send is replaced by Stop. Losing this leaves no
    /// way to interrupt a model that has started rambling.
    func testAssistantSwapsSendForStopWhileStreaming() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (() => {
          const shown = () => (document.getElementById('send').hidden ? '-' : 'send') +
                              (document.getElementById('stopBtn').hidden ? '' : '+stop');
          window.atlasAssistant.streaming(JSON.stringify({streaming:true}));
          const during = shown();
          window.atlasAssistant.streaming(JSON.stringify({streaming:false}));
          return during + '|' + shown();
        })()
        """)
        XCTAssertEqual(out, "-+stop|send")
    }

    /// Missing key, condensed history and a truncated reply each have to reach
    /// the user; they are the difference between "broken" and "explained".
    func testAssistantSurfacesTheThingsThatNeedExplaining() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (() => {
          window.atlasAssistant.status(JSON.stringify({
            mode:'direct', streaming:false, hasKey:false,
            didSummarize:true, truncated:true, contextFill:0.9
          }));
          const kinds = [...document.querySelectorAll('#notices .notice')]
            .map(n => n.className.replace('notice ','')).join(',');
          return kinds + '|' + document.getElementById('ctxFill').className;
        })()
        """)
        XCTAssertEqual(out, "warn,info,warn|hot",
                       "no key, condensed history and truncation must all show")
    }

    /// The menu-bar window loads this same page and strips the chrome.
    func testAssistantCompactModeHidesTheChrome() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let out = try await boot(page, injecting: [markdown], evaluating: """
        (() => {
          const hidden = () => ['topbar','rail','composer']
            .map(id => getComputedStyle(document.getElementById(id)).display)
            .join(',');
          const before = hidden();
          window.atlasAssistant.compact();
          return before + '|' + hidden();
        })()
        """)
        let parts = out.split(separator: "|").map(String.init)
        XCTAssertNotEqual(parts.first, "none,none,none", "chrome should show by default")
        XCTAssertEqual(parts.last, "none,none,none", "compact must hide all three")
    }

    /// Header controls have to be both big enough to hit and visible enough to
    /// aim at. They were 28x28 with a 13px glyph at 50% opacity — the box was
    /// borderline and the glyph was the real problem.
    func testAssistantHeaderControlsAreHittable() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let out = try await boot(page, injecting: [markdown], width: 1200, evaluating: """
        (() => {
          const ids = ['openSettings','newChat','toggleRail','modelBadge'];
          const sizes = ids.map(id => {
            const b = document.getElementById(id).getBoundingClientRect();
            return Math.min(Math.round(b.width), Math.round(b.height));
          });
          const cs = getComputedStyle(document.getElementById('openSettings'));
          // Split rather than regex: backslash classes are not valid Swift escapes.
          const parts = cs.color.replace(/[^0-9.,]/g,'').split(',');
          const alpha = parts.length > 3 ? parts[3] : '1';
          return Math.min.apply(null, sizes) + '|' + alpha;
        })()
        """)
        let parts = out.split(separator: "|").map(String.init)
        let smallest = try XCTUnwrap(parts.first.flatMap { Int($0) })
        let alpha = try XCTUnwrap(parts.last.flatMap { Double($0) })

        XCTAssertGreaterThanOrEqual(smallest, 30,
            "a header control is \(smallest)px on its short side")
        XCTAssertGreaterThan(alpha, 0.55,
            "resting contrast is \(alpha) — you aim at what you can see")
    }

    /// The transcript has to scroll.
    ///
    /// It did not: `#main` and `#center` both clip, and `#log` had no overflow
    /// and `min-height:100%`, so a long conversation simply ran off the bottom
    /// with no way to reach it. A flex child also needs `min-height:0` or it
    /// refuses to shrink below its content and the overflow never engages.
    func testAssistantTranscriptScrolls() async throws {
        let page = try XCTUnwrap(AtlasResources.assistantPage)
        let out = try await boot(page, injecting: [markdown], width: 1100, evaluating: """
        (() => {
          const many = [];
          for (let i = 0; i < 40; i++) {
            many.push({id:'m'+i, role: i % 2 ? 'Sovereign' : 'User', subtitle:'',
                       text:'Line '+i+' of a long conversation.',
                       streaming:false, files:[], reasoning:''});
          }
          window.atlasAssistant.setAll(JSON.stringify(many));
          const log = document.getElementById('log');
          const overflows = log.scrollHeight > log.clientHeight + 20;
          log.scrollTop = 9999;
          return overflows + '|' + (log.scrollTop > 0) + '|' +
                 getComputedStyle(log).overflowY;
        })()
        """)
        let parts = out.split(separator: "|").map(String.init)
        XCTAssertEqual(parts.first, "true", "40 messages must overflow the pane")
        XCTAssertEqual(parts.dropFirst().first, "true", "the transcript must actually scroll")
        XCTAssertEqual(parts.last, "auto", "#log is the scroll container")
    }

    // MARK: - Finances

    /// The Money out page must come up and expose its API — the same seam that
    /// has silently broken on every other page at least once.
    func testFinancesPageBootsAndAsksForData() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let ready = try await boot(page, evaluating: """
        typeof window.atlasFinances === 'object'
          && typeof window.atlasFinances.render === 'function'
          && typeof window.atlasFinances.saved === 'function'
          && typeof window.atlasFinances.error === 'function'
        """)
        XCTAssertEqual(ready, "1", "finances.html did not expose window.atlasFinances")
    }

    /// With nothing in the database the page says so rather than showing a blank
    /// pane under a row of zeroes.
    func testFinancesEmptyStateExplainsItself() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let text = try await boot(page, evaluating: """
        (() => {
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(subscriptions: "[]"))));
          const pane = document.getElementById('pane-out');
          return pane.querySelectorAll('.atlas-empty').length + '|' +
                 pane.querySelector('.atlas-empty__title').textContent;
        })()
        """)
        XCTAssertEqual(text, "2|No subscriptions yet")
    }

    /// Totals arrive as integer minor units and are formatted on the page. This
    /// is the check that a page-side total never goes through floating point.
    func testFinancesFormatsMinorUnitsWithoutFloatingPoint() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let shown = try await boot(page, evaluating: """
        (() => {
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(
            subscriptions: "[]", monthlyCommitted: 2128, yearlyCommitted: 125000))));
          const tiles = document.querySelectorAll('#tiles .tile dd');
          return tiles[0].textContent + '|' + tiles[1].textContent;
        })()
        """)
        XCTAssertEqual(shown, "$21.28|$1,250.00")
    }

    /// A subscription named with a script tag renders as text. This is the check
    /// that matters most on a page whose rows are all user-entered.
    func testFinancesEscapesRecordText() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let result = try await boot(page, evaluating: """
        (() => {
          window.__xss = false;
          const row = {
            id: 's1', name: '<img src=x onerror="window.__xss=true">',
            amount: 2000, amountText: '$20.00', currency: 'usd',
            cadence: 'monthly', cadenceLabel: 'Monthly', nextDueOn: '2026-10-01',
            daysUntil: 22, category: 'software', categoryLabel: 'Software',
            source: 'manual', notes: '', isActive: true, monthlyEquivalent: 2000,
            yearly: 24000, dueSoon: false, editable: true
          };
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(
            subscriptions: "[row]"))));
          return String(window.__xss) + '|' +
                 document.querySelectorAll('#subs img').length + '|' +
                 document.querySelector('#subs .name').textContent;
        })()
        """)
        XCTAssertEqual(result,
            "false|0|<img src=x onerror=\"window.__xss=true\">",
            "record text must render as text, never as markup")
    }

    /// All three tabs exist and only one is showing at a time.
    func testFinancesTabsSwitch() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let out = try await boot(page, evaluating: """
        (() => {
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(subscriptions: "[]"))));
          const shown = () => ['plan','in','out']
            .filter(n => !document.getElementById('pane-' + n).hidden).join(',');
          const first = shown();
          document.querySelector('#tabs button[data-tab="out"]').click();
          return first + '|' + shown();
        })()
        """)
        XCTAssertEqual(out, "plan|out", "Plan shows first, and switching leaves one pane up")
    }

    /// Adding a subscription belongs to Money out; planning setup belongs to
    /// Plan. Offering either on the wrong tab is how the old page confused them.
    func testFinancesToolbarFollowsTheTab() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let out = try await boot(page, evaluating: """
        (() => {
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(subscriptions: "[]"))));
          const state = () => ['planSetup','addSub'].map(
            id => document.getElementById(id).hidden ? '-' : '+').join('');
          const onPlan = state();
          document.querySelector('#tabs button[data-tab="out"]').click();
          return onPlan + '|' + state();
        })()
        """)
        XCTAssertEqual(out, "+-|-+")
    }

    /// A card with no limit recorded has no utilization. Showing 0% would read
    /// as one that is paid off, so the bridge sends "—" and the page shows it.
    func testFinancesShowsUnknownUtilizationRatherThanZero() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let shown = try await boot(page, evaluating: """
        (() => {
          const account = {
            id: 'a1', name: 'Card', balanceText: '$820.00', balanceInput: '820.00',
            limit: 0, limitText: '$0.00', limitInput: '', aprInput: '24.99',
            minimumInput: '', plannedInput: '', planned: 0, plannedText: '$0.00',
            paymentDueOn: '2026-10-05', paymentDueLabel: 'Oct 5',
            statementClosesOn: '2026-09-12', statementClosesLabel: 'Sep 12',
            openedOn: '2024-01-01', autopayEnabled: false, isActive: true, notes: '',
            utilization: '—', projectedUtilization: '—', toReach30: '—', toReach10: '—'
          };
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(
            subscriptions: "[]", accounts: "[account]"))));
          return document.querySelector('#planCredit .use').textContent;
        })()
        """)
        XCTAssertEqual(shown, "— used")
    }

    /// Test-mode figures are labelled rather than presented as revenue, and an
    /// incomplete fetch is called a floor. Both banners are the page's honesty
    /// rules, and losing them would misreport money.
    func testFinancesMoneyInLabelsTestModeAndIncompleteFetches() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let banners = try await boot(page, evaluating: """
        (() => {
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(
            subscriptions: "[]", moneyIn: Self.moneyInFixture(isLive: false, complete: false)))));
          return document.querySelectorAll('#inBanners .banner').length + '|' +
                 document.querySelector('#inBanners .banner').textContent;
        })()
        """)
        XCTAssertEqual(banners,
            "2|Test mode. These are not real earnings — nothing below is revenue.")
    }

    /// A live, complete snapshot carries no banner at all.
    func testFinancesMoneyInIsQuietWhenTheSnapshotIsClean() async throws {
        let page = try XCTUnwrap(AtlasResources.financesPage)
        let count = try await boot(page, evaluating: """
        (() => {
          window.atlasFinances.render(JSON.stringify(\(Self.financesFixture(
            subscriptions: "[]", moneyIn: Self.moneyInFixture()))));
          return String(document.querySelectorAll('#inBanners .banner').length);
        })()
        """)
        XCTAssertEqual(count, "0")
    }

    /// One payload shaped like the bridge's, so each test varies only what it is
    /// about rather than restating the whole snapshot.
    private static func financesFixture(subscriptions: String,
                                        monthlyCommitted: Int = 0,
                                        yearlyCommitted: Int = 0,
                                        accounts: String = "[]",
                                        moneyIn: String = "{ configured: false }") -> String {
        """
        { subscriptions: \(subscriptions), expenses: [], infraOffers: [], canSync: false,
          summary: { activeSubscriptions: 0, monthlyCommitted: \(monthlyCommitted),
                     yearlyCommitted: \(yearlyCommitted), dueSoonCount: 0, dueSoonTotal: 0,
                     overdueCount: 0, priceChangeCount: 0,
                     futureMonthly: \(monthlyCommitted), pendingPriceChangeCount: 0 },
          month: { label: 'September 2026', subscriptions: 0, expenses: 0, out: 0 },
          options: { cadences: [{value:'monthly',label:'Monthly'}],
                     categories: [{value:'software',label:'Software'}],
                     strategies: [{value:'avalanche',label:'Avalanche'}] },
          plan: {
            profile: { openingCash: 0, openingCashText: '$0.00', recurringIncome: 0,
                       recurringIncomeText: '$0.00', nextIncomeOn: '2026-09-15',
                       monthlyDebtBudget: 0, monthlyDebtBudgetText: '$0.00',
                       buffer: 0, bufferText: '$0.00', isConfigured: false },
            credit: { totalBalanceText: '$0.00', totalLimitText: '$0.00',
                      utilization: '—', projectedUtilization: '—',
                      plannedPaymentText: '$0.00', toReach30: '—', toReach10: '—',
                      accounts: \(accounts) },
            forecast: { income: 0, incomeText: '$0.00', out: 0, outText: '$0.00',
                        ending: 0, endingText: '$0.00', lowest: 0, lowestText: '$0.00',
                        lowestOn: 'Sep 9', safeToSpend: 0, safeToSpendText: '$0.00',
                        hasShortfall: false },
            actions: [],
            debt: { strategy: 'avalanche', budgetText: '$0.00', minimumsText: '$0.00',
                    budgetCoversMinimums: true, shortfallText: '$0.00', payoffMonths: null,
                    interestText: '—', interestSavedText: '—', allocations: [],
                    hasDebt: false }
          },
          moneyIn: \(moneyIn),
          today: '2026-09-09' }
        """
    }

    private static func moneyInFixture(isLive: Bool = true, complete: Bool = true) -> String {
        """
        { configured: true, isLive: \(isLive), isStale: false, complete: \(complete),
          generatedAt: '9 Sep 2026 at 12:00', droppedTextFields: 14,
          totals: { netText: '$0.00', grossText: '$0.00', refundedText: '$0.00',
                    openDisputeText: '$0.00', chargesSeen: 0, paidCount: 0, payoutCount: 0,
                    disputedCount: 0, openDisputeCount: 0, unpaidInvoiceCount: 0,
                    failedPaymentCount: 0, activeSubscriptions: 0 },
          unavailable: [] }
        """
    }
}

/// Swallows whatever a page posts on startup.
private final class SilentHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {}
}

private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }
}
