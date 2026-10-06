import Foundation
import Testing

@testable import RadianCore

private func url(_ string: String) -> URL { URL(string: string)! }

/// One profile, two spaces. The first holds a folder with one tab, a pinned tab and two unpinned tabs.
private struct Fixture {
    var state: BrowserState
    let home: UUID
    let other: UUID
    let folder = SidebarItem.folder(name: "Folder", children: [.tab(url: url("https://nested.example.com/"), title: "Nested")])
    let pinned = SidebarItem.tab(url: url("https://pinned.example.com/"), title: "Pinned")
    let first = SidebarItem.tab(url: url("https://first.example.com/"), title: "First")
    let second = SidebarItem.tab(url: url("https://second.example.com/"), title: "Second")

    var nested: SidebarItem { folder.children[0] }

    init() {
        let profile = Profile(name: "Personal")
        var homeSpace = Space(name: "Home", profileID: profile.id)
        var pinnedTab = pinned
        pinnedTab.homeURL = pinnedTab.url
        homeSpace.pinned = [folder, pinnedTab]
        homeSpace.tabs = [first, second]
        let otherSpace = Space(name: "Other", profileID: profile.id)
        home = homeSpace.id
        other = otherSpace.id
        state = BrowserState(profiles: [profile], spaces: [homeSpace, otherSpace], currentSpaceID: homeSpace.id)
    }
}

@Suite struct SidebarTreeTests {
    @Test func findsAndUpdatesNestedItems() {
        var fixture = Fixture()
        #expect(fixture.state.item(withID: fixture.nested.id)?.title == "Nested")
        let updated = fixture.state.updateItem(withID: fixture.nested.id) { $0.title = "Changed" }
        #expect(updated)
        #expect(fixture.state.item(withID: fixture.nested.id)?.title == "Changed")
        let updatedMissing = fixture.state.updateItem(withID: UUID()) { $0.title = "Nobody" }
        #expect(!updatedMissing)
    }

    @Test func reportsWhereItemsLive() {
        let fixture = Fixture()
        #expect(fixture.state.address(of: fixture.nested.id)?.section == .pinned)
        #expect(fixture.state.address(of: fixture.first.id)?.section == .tabs)
        #expect(fixture.state.address(of: fixture.first.id)?.spaceID == fixture.home)
        #expect(fixture.state.address(of: UUID()) == nil)
    }

    @Test func visibleTabsSkipCollapsedFolders() {
        var fixture = Fixture()
        #expect(fixture.state.visibleTabs(inSpace: fixture.home).map(\.title) == ["Pinned", "First", "Second"])
        fixture.state.updateItem(withID: fixture.folder.id) { $0.isExpanded = true }
        #expect(fixture.state.visibleTabs(inSpace: fixture.home).map(\.title) == ["Nested", "Pinned", "First", "Second"])
    }
}

@Suite struct MoveTests {
    @Test func pinningATabGivesItAHome() {
        var fixture = Fixture()
        let moved = fixture.state.move(
            fixture.first.id,
            to: MoveDestination(spaceID: fixture.home, section: .pinned, placement: .end)
        )
        #expect(moved)
        let space = fixture.state.spaces[0]
        #expect(space.tabs.map(\.title) == ["Second"])
        #expect(space.pinned.map(\.title) == ["Folder", "Pinned", "First"])
        #expect(space.pinned[2].homeURL == fixture.first.url)
    }

    @Test func unpinningATabForgetsItsHome() {
        var fixture = Fixture()
        fixture.state.move(fixture.pinned.id, to: MoveDestination(spaceID: fixture.home, section: .tabs, placement: .start))
        let space = fixture.state.spaces[0]
        #expect(space.tabs.map(\.title) == ["Pinned", "First", "Second"])
        #expect(space.tabs[0].homeURL == nil)
    }

    @Test func reordersBeforeASibling() {
        var fixture = Fixture()
        fixture.state.move(
            fixture.second.id,
            to: MoveDestination(spaceID: fixture.home, section: .tabs, placement: .before(fixture.first.id))
        )
        #expect(fixture.state.spaces[0].tabs.map(\.title) == ["Second", "First"])
    }

    @Test func movesIntoAndOutOfFolders() {
        var fixture = Fixture()
        fixture.state.move(
            fixture.first.id,
            to: MoveDestination(spaceID: fixture.home, section: .pinned, placement: .inFolder(fixture.folder.id))
        )
        let folder = fixture.state.spaces[0].pinned[0]
        #expect(folder.children.map(\.title) == ["Nested", "First"])
        #expect(folder.isExpanded)

        // Dropping before a nested item places the tab inside that item's folder.
        fixture.state.move(
            fixture.second.id,
            to: MoveDestination(spaceID: fixture.home, section: .pinned, placement: .before(fixture.nested.id))
        )
        #expect(fixture.state.spaces[0].pinned[0].children.map(\.title) == ["Second", "Nested", "First"])
        #expect(fixture.state.spaces[0].tabs.isEmpty)
    }

    @Test func movesToFavoritesAndAcrossSpaces() {
        var fixture = Fixture()
        fixture.state.move(fixture.first.id, to: MoveDestination(spaceID: fixture.home, section: .favorites, placement: .end))
        #expect(fixture.state.profiles[0].favorites.map(\.title) == ["First"])
        #expect(fixture.state.address(of: fixture.first.id)?.spaceID == nil)

        fixture.state.move(fixture.second.id, to: MoveDestination(spaceID: fixture.other, section: .tabs, placement: .start))
        #expect(fixture.state.spaces[1].tabs.map(\.title) == ["Second"])
    }

    @Test func refusesMovesThatWouldLoseOrOrphanItems() {
        var fixture = Fixture()
        let before = fixture.state
        let home = fixture.home
        let folder = fixture.folder.id
        let tab = fixture.first.id

        let refused: [(UUID, MoveDestination)] = [
            // A folder cannot be unpinned, made a favorite, or dropped inside itself.
            (folder, MoveDestination(spaceID: home, section: .tabs, placement: .end)),
            (folder, MoveDestination(spaceID: home, section: .favorites, placement: .end)),
            (folder, MoveDestination(spaceID: home, section: .pinned, placement: .inFolder(folder))),
            (folder, MoveDestination(spaceID: home, section: .pinned, placement: .before(fixture.nested.id))),
            // Destinations that do not exist, or are not folders.
            (tab, MoveDestination(spaceID: UUID(), section: .tabs, placement: .end)),
            (tab, MoveDestination(spaceID: home, section: .tabs, placement: .before(UUID()))),
            (tab, MoveDestination(spaceID: home, section: .pinned, placement: .inFolder(fixture.pinned.id))),
            // An item cannot be placed before itself.
            (tab, MoveDestination(spaceID: home, section: .tabs, placement: .before(tab))),
        ]
        for (id, destination) in refused {
            let moved = fixture.state.move(id, to: destination)
            #expect(!moved, "should refuse \(destination)")
            #expect(fixture.state == before)
        }
    }

    @Test func movingTheSelectedTabToAnotherSpaceClearsTheSelection() {
        var fixture = Fixture()
        fixture.state.spaces[0].selectedTabID = fixture.first.id
        fixture.state.move(fixture.first.id, to: MoveDestination(spaceID: fixture.other, section: .tabs, placement: .end))
        #expect(fixture.state.spaces[0].selectedTabID == nil)
    }
}

@Suite struct ArchiveTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func staleFixture() -> Fixture {
        var fixture = Fixture()
        let old = now.addingTimeInterval(-13 * 3600)
        fixture.state.updateItem(withID: fixture.first.id) { $0.lastActiveAt = old }
        fixture.state.updateItem(withID: fixture.pinned.id) { $0.lastActiveAt = old }
        fixture.state.updateItem(withID: fixture.second.id) { $0.lastActiveAt = self.now }
        return fixture
    }

    @Test func archivesOnlyStaleUnpinnedTabs() {
        var fixture = staleFixture()
        let archived = fixture.state.archiveStaleTabs(now: now)
        #expect(archived == [fixture.first.id])
        #expect(fixture.state.spaces[0].tabs.map(\.title) == ["Second"])
        #expect(fixture.state.spaces[0].pinned.count == 2)
        #expect(fixture.state.archive.map(\.title) == ["First"])
        #expect(fixture.state.archive[0].spaceID == fixture.home)
    }

    @Test func neverArchivesTheTabOnScreen() {
        var fixture = staleFixture()
        fixture.state.spaces[0].selectedTabID = fixture.first.id
        let whileSelected = fixture.state.archiveStaleTabs(now: now)
        #expect(whileSelected.isEmpty)

        fixture.state.spaces[0].selectedTabID = nil
        let whileProtected = fixture.state.archiveStaleTabs(now: now, protecting: [fixture.first.id])
        #expect(whileProtected.isEmpty)
    }

    @Test func archivingCanBeTurnedOff() {
        var fixture = staleFixture()
        fixture.state.settings.archiveAfterHours = nil
        let archived = fixture.state.archiveStaleTabs(now: now)
        #expect(archived.isEmpty)
        #expect(fixture.state.spaces[0].tabs.count == 2)
    }

    @Test func archiveIsCapped() {
        var fixture = Fixture()
        for index in 0..<(BrowserState.archiveLimit + 25) {
            fixture.state.archive(.tab(url: url("https://example.com/\(index)")), spaceID: fixture.home, at: now)
        }
        #expect(fixture.state.archive.count == BrowserState.archiveLimit)
        #expect(fixture.state.archive[0].url.path == "/\(BrowserState.archiveLimit + 24)")
    }
}

@Suite struct RepairTests {
    @Test func removingASpaceKeepsAValidCurrentSpace() {
        var fixture = Fixture()
        let removed = fixture.state.removeSpace(withID: fixture.home)
        #expect(removed?.count == 4)
        #expect(fixture.state.currentSpaceID == fixture.other)
        // Nothing is lost outright: every tab the space held is in the archive, first tab on top.
        #expect(fixture.state.archive.map(\.title) == ["Nested", "Pinned", "First", "Second"])
        // The last space is not removable.
        let removedLast = fixture.state.removeSpace(withID: fixture.other)
        #expect(removedLast == nil)
        #expect(fixture.state.spaces.count == 1)
    }

    @Test func repairPromotesTheSplitTabWhenThePrimaryDisappears() {
        var fixture = Fixture()
        fixture.state.spaces[0].selectedTabID = fixture.first.id
        fixture.state.spaces[0].splitTabID = fixture.second.id
        fixture.state.removeItem(withID: fixture.first.id)
        fixture.state.repairSelections()
        #expect(fixture.state.spaces[0].selectedTabID == fixture.second.id)
        #expect(fixture.state.spaces[0].splitTabID == nil)
    }

    @Test func repairRescuesADamagedFile() {
        var state = BrowserState(profiles: [], spaces: [], currentSpaceID: UUID())
        state.repair()
        #expect(state.profiles.count == 1)
        #expect(state.spaces.count == 1)
        #expect(state.currentSpaceID == state.spaces[0].id)
        #expect(state.spaces[0].profileID == state.profiles[0].id)
    }
}

@Suite struct PersistenceTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("radian-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    @Test func roundTripsState() throws {
        var fixture = Fixture()
        fixture.state.settings.archiveAfterHours = nil
        fixture.state.spaces[0].icon = .emoji("🌊")
        let file = JSONFileStore<BrowserState>(url: temporaryFile())
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }

        #expect(try file.load() == nil)
        try file.save(fixture.state)
        let loaded = try #require(try file.load())
        // Dates are stored to the second, so compare the parts that must survive exactly.
        #expect(loaded.spaces.map(\.name) == ["Home", "Other"])
        #expect(loaded.spaces[0].icon == .emoji("🌊"))
        #expect(loaded.spaces[0].pinned[0].children[0].url == fixture.nested.url)
        #expect(loaded.settings.archiveAfterHours == nil)
        #expect(loaded.currentSpaceID == fixture.home)
    }

    @Test func settingsFromOlderFilesFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"searchEngine": "kagi"}"#.utf8))
        #expect(decoded.searchEngine == .kagi)
        #expect(decoded.archiveAfterHours == 12)
        #expect(decoded.sidebarWidth == Settings().sidebarWidth)
    }

    @Test func unreadableFilesAreSetAsideNotDeleted() throws {
        let file = JSONFileStore<BrowserState>(url: temporaryFile())
        let directory = file.url.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ truncated".utf8).write(to: file.url)

        guard case .setAside(let destination) = file.loadOrSetAside() else {
            Issue.record("expected the file to be set aside")
            return
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining == [destination.lastPathComponent])
        #expect(remaining[0].contains("unreadable"))
        let contents = try String(contentsOf: destination, encoding: .utf8)
        #expect(contents == "{ truncated")
    }
}

@Suite struct SelectionTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func leavingATabRestartsItsArchiveClock() {
        var fixture = Fixture()
        fixture.state.select(fixture.first.id, now: start)
        // Read for 13 hours, then move on. The tab was seen just now, so it is not stale.
        let later = start.addingTimeInterval(13 * 3600)
        fixture.state.select(fixture.second.id, now: later)
        #expect(fixture.state.item(withID: fixture.first.id)?.lastActiveAt == later)
        let archived = fixture.state.archiveStaleTabs(now: later.addingTimeInterval(600))
        #expect(archived.isEmpty)
    }

    @Test func switchingSpacesAndClosingTheSplitAlsoCount() {
        var fixture = Fixture()
        fixture.state.select(fixture.first.id, now: start)
        let opened = fixture.state.setSplit(fixture.second.id, now: start)
        #expect(opened)
        let later = start.addingTimeInterval(20 * 3600)
        fixture.state.showSpace(fixture.other, now: later)
        #expect(fixture.state.item(withID: fixture.first.id)?.lastActiveAt == later)
        #expect(fixture.state.item(withID: fixture.second.id)?.lastActiveAt == later)
    }

    @Test func unpinningATabStartsItsClockAfresh() {
        var fixture = Fixture()
        fixture.state.updateItem(withID: fixture.pinned.id) { $0.lastActiveAt = self.start }
        let later = start.addingTimeInterval(3 * 86_400)
        fixture.state.move(fixture.pinned.id, to: MoveDestination(spaceID: fixture.home, section: .tabs, placement: .end), now: later)
        let archived = fixture.state.archiveStaleTabs(now: later.addingTimeInterval(600))
        // The fixture's other tabs are stale on this clock; the one just unpinned must not be.
        #expect(!archived.contains(fixture.pinned.id))
        #expect(fixture.state.spaces[0].tabs.contains { $0.id == fixture.pinned.id })
    }

    @Test func selectingTheSplitTabSwapsThePanes() {
        var fixture = Fixture()
        fixture.state.select(fixture.first.id, now: start)
        fixture.state.setSplit(fixture.second.id, now: start)
        fixture.state.select(fixture.second.id, now: start)
        #expect(fixture.state.spaces[0].selectedTabID == fixture.second.id)
        #expect(fixture.state.spaces[0].splitTabID == fixture.first.id)
    }

    @Test func splitRefusesTabsFromOtherSpacesAndTheSelectedTab() {
        var fixture = Fixture()
        let foreign = SidebarItem.tab(url: URL(string: "https://elsewhere.example.com/")!)
        fixture.state.spaces[1].tabs = [foreign]
        let withoutSelection = fixture.state.setSplit(fixture.second.id, now: start)
        #expect(!withoutSelection)
        fixture.state.select(fixture.first.id, now: start)
        let withItself = fixture.state.setSplit(fixture.first.id, now: start)
        let withForeign = fixture.state.setSplit(foreign.id, now: start)
        #expect(!withItself)
        #expect(!withForeign)
    }

    @Test func closingAnUnpinnedTabArchivesIt() {
        var fixture = Fixture()
        fixture.state.select(fixture.first.id, now: start)
        fixture.state.setSplit(fixture.second.id, now: start)
        let outcome = fixture.state.close(fixture.first.id, now: start)
        guard case .archived(let entryID) = outcome else {
            Issue.record("expected the tab to be archived, got \(String(describing: outcome))")
            return
        }
        #expect(fixture.state.archive.first?.id == entryID)
        #expect(fixture.state.spaces[0].tabs.map(\.title) == ["Second"])
        // The other pane takes over the window.
        #expect(fixture.state.spaces[0].selectedTabID == fixture.second.id)
        #expect(fixture.state.spaces[0].splitTabID == nil)
    }

    @Test func closingAPinnedTabSendsItHome() {
        var fixture = Fixture()
        fixture.state.updateItem(withID: fixture.pinned.id) { $0.url = URL(string: "https://pinned.example.com/deep/page")! }
        let outcome = fixture.state.close(fixture.pinned.id, now: start)
        #expect(outcome == .unloaded)
        #expect(fixture.state.item(withID: fixture.pinned.id)?.url == fixture.pinned.url)
        #expect(fixture.state.archive.isEmpty)
    }

    @Test func deletingAFolderArchivesItsTabs() {
        var fixture = Fixture()
        fixture.state.select(fixture.nested.id, now: start)
        let removed = fixture.state.deleteItem(withID: fixture.folder.id, now: start)
        #expect(removed?.id == fixture.folder.id)
        #expect(fixture.state.archive.map(\.title) == ["Nested"])
        #expect(fixture.state.spaces[0].selectedTabID == nil)
    }

    @Test func restoringATabFromADeletedSpaceUsesTheCurrentOne() throws {
        var fixture = Fixture()
        fixture.state.removeSpace(withID: fixture.home, now: start)
        let entry = try #require(fixture.state.archive.first)
        let restoredID = fixture.state.restoreArchived(entry.id, now: start)
        let restored = try #require(restoredID)
        #expect(fixture.state.spaces[0].id == fixture.other)
        #expect(fixture.state.spaces[0].tabs.map(\.id) == [restored])
        #expect(!fixture.state.archive.contains { $0.id == entry.id })
    }
}

@Suite struct RepairRuleTests {
    @Test func repairRemovesDuplicatesAndMovesFoldersOutOfTheTabList() {
        var fixture = Fixture()
        // A folder in the unpinned list, and the same tab twice.
        fixture.state.spaces[0].tabs.append(.folder(name: "Stray", children: [.tab(url: URL(string: "https://stray.example.com/")!, title: "Stray tab")]))
        fixture.state.profiles[0].favorites = [fixture.first]
        fixture.state.repair()
        let tabs = fixture.state.spaces[0].tabs
        #expect(tabs.map(\.title) == ["First", "Second", "Stray tab"])
        #expect(!tabs.contains { $0.isFolder })
        #expect(fixture.state.profiles[0].favorites.isEmpty)
        #expect(fixture.state.allItemIDs.count == 6)
    }

    @Test func theSweepNeverDropsWhatItCannotArchive() {
        var fixture = Fixture()
        let old = Date(timeIntervalSince1970: 1_000)
        var stray = SidebarItem.folder(name: "Stray", children: [.tab(url: URL(string: "https://x.example.com/")!)])
        stray.lastActiveAt = old
        fixture.state.spaces[0].tabs.append(stray)
        fixture.state.archiveStaleTabs(now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(fixture.state.spaces[0].tabs.contains { $0.id == stray.id })
    }
}

@Suite struct DecodingTests {
    private func decode(_ json: String) throws -> BrowserState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BrowserState.self, from: Data(json.utf8))
    }

    private let profile = "11111111-1111-1111-1111-111111111111"
    private let space = "22222222-2222-2222-2222-222222222222"

    @Test func readsEveryField() throws {
        let state = try decode("""
        {
          "schemaVersion": 1,
          "currentSpaceID": "\(space)",
          "profiles": [{ "id": "\(profile)", "name": "Work", "favorites": [
            { "id": "33333333-3333-3333-3333-333333333333", "kind": "tab", "title": "Mail",
              "url": "https://mail.example.com/inbox", "homeURL": "https://mail.example.com/",
              "children": [], "isExpanded": false,
              "createdAt": "2026-01-01T00:00:00Z", "lastActiveAt": "2026-01-02T00:00:00Z" }
          ] }],
          "spaces": [{
            "id": "\(space)", "name": "Home", "profileID": "\(profile)",
            "icon": { "emoji": { "_0": "🌊" } },
            "theme": { "colors": [{ "red": 1, "green": 0, "blue": 0, "alpha": 1 }], "intensity": 0.5 },
            "pinned": [{ "id": "44444444-4444-4444-4444-444444444444", "kind": "folder", "title": "Reading",
              "isExpanded": true, "createdAt": "2026-01-01T00:00:00Z", "lastActiveAt": "2026-01-01T00:00:00Z",
              "children": [{ "id": "55555555-5555-5555-5555-555555555555", "kind": "tab", "title": "Guide",
                "customTitle": "Mine", "url": "https://docs.example.com/", "homeURL": "https://docs.example.com/",
                "children": [], "isExpanded": false,
                "createdAt": "2026-01-01T00:00:00Z", "lastActiveAt": "2026-01-01T00:00:00Z" }] }],
            "tabs": [],
            "selectedTabID": "55555555-5555-5555-5555-555555555555"
          }],
          "archive": [{ "id": "66666666-6666-6666-6666-666666666666", "title": "Old", "url": "https://old.example.com/",
            "spaceID": "\(space)", "archivedAt": "2026-01-03T00:00:00Z" }],
          "settings": { "searchEngine": "kagi", "archiveAfterHours": null, "sidebarWidth": 300 }
        }
        """)
        let home = try #require(state.spaces.first)
        let favorite = try #require(state.profiles.first?.favorites.first)
        let guide = try #require(home.pinned.first?.children.first)
        #expect(state.currentSpaceID.uuidString == space)
        #expect(favorite.homeURL?.absoluteString == "https://mail.example.com/")
        #expect(favorite.url?.path == "/inbox")
        #expect(home.icon == .emoji("🌊"))
        #expect(home.theme.colors == [RGBAColor(red: 1, green: 0, blue: 0)])
        #expect(home.pinned.first?.isExpanded == true)
        #expect(guide.customTitle == "Mine")
        #expect(home.selectedTabID == guide.id)
        #expect(state.archive.map(\.title) == ["Old"])
        #expect(state.settings.searchEngine == .kagi)
        #expect(state.settings.archiveAfterHours == nil)
        #expect(state.settings.sidebarWidth == 300)
    }

    @Test func skipsWhatItCannotReadAndKeepsTheRest() throws {
        let state = try decode("""
        {
          "schemaVersion": 7,
          "currentSpaceID": "\(space)",
          "profiles": [{ "id": "\(profile)" }],
          "spaces": [
            { "id": "\(space)", "profileID": "\(profile)", "icon": { "hologram": {} },
              "pinned": [
                { "id": "44444444-4444-4444-4444-444444444444", "kind": "board", "title": "From the future" },
                { "id": "55555555-5555-5555-5555-555555555555", "kind": "tab", "url": "https://kept.example.com/" }
              ] },
            { "name": "No id" }
          ],
          "archive": [{ "title": "No address" }]
        }
        """)
        #expect(state.schemaVersion == 7)
        #expect(state.spaces.count == 1)
        let kept = try #require(state.spaces[0].pinned.first)
        #expect(state.spaces[0].pinned.count == 1)
        #expect(kept.url?.host == "kept.example.com")
        #expect(kept.title == "")
        #expect(state.spaces[0].name == "Space")
        #expect(state.spaces[0].icon == .symbol("circle.fill"))
        #expect(state.profiles[0].name == "Profile")
        #expect(state.archive.isEmpty)
        #expect(state.settings == Settings())
    }

    @Test func refusesAFileWhoseSpacesAreAllUnreadable() {
        #expect(throws: DecodingError.self) {
            try decode(#"{ "spaces": [{ "name": "No id" }], "profiles": [] }"#)
        }
    }
}

@Suite struct ThemeTests {
    @Test func samplesTheGradientAlongItsLength() {
        let theme = SpaceTheme(colors: [RGBAColor(red: 0, green: 0, blue: 0), RGBAColor(red: 1, green: 1, blue: 1)])
        #expect(theme.color(at: 0) == RGBAColor(red: 0, green: 0, blue: 0))
        #expect(theme.color(at: 0.5).red == 0.5)
        #expect(theme.color(at: 2) == RGBAColor(red: 1, green: 1, blue: 1))
    }

    @Test func sidebarBrightnessFollowsTheStartOfTheGradient() {
        let blackToWhite = SpaceTheme(colors: [RGBAColor(red: 0, green: 0, blue: 0), RGBAColor(red: 1, green: 1, blue: 1)])
        let whiteToBlack = SpaceTheme(colors: [RGBAColor(red: 1, green: 1, blue: 1), RGBAColor(red: 0, green: 0, blue: 0)])
        // Their averages are identical, but the sidebar sits over the first color.
        #expect(blackToWhite.sidebarLuminance < 0.2)
        #expect(whiteToBlack.sidebarLuminance > 0.5)
    }
}
