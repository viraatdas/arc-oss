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

        #expect(file.loadOrQuarantine() == nil)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.count == 1)
        #expect(remaining[0].contains("corrupt"))
    }
}
