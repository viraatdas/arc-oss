import Foundation
import Testing

@testable import RadianCore

/// A hand-written file in Arc's sidebar format. It exercises every shape the importer knows:
/// alternating key/value arrays, both profile variants, gradient and single-color themes,
/// a folder, a split view, a renamed tab, the onboarding card and an internal page.
private let fixture = """
{
  "version": 1,
  "sidebar": {
    "containers": [
      { "global": {} },
      {
        "topAppsContainerIDs": [
          { "default": true }, "TOP-DEFAULT",
          { "custom": { "_0": { "directoryBasename": "Profile 1", "machineID": "m" } } }, "TOP-WORK"
        ],
        "spaces": [
          "11111111-1111-1111-1111-111111111111",
          {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Home",
            "containerIDs": ["pinned", "PIN-HOME", "unpinned", "UNPIN-HOME"],
            "newContainerIDs": [{ "pinned": {} }, "PIN-HOME", { "unpinned": { "_0": { "shared": {} } } }, "UNPIN-HOME"],
            "profile": { "default": true },
            "customInfo": {
              "iconType": { "icon": "flash" },
              "windowTheme": {
                "background": { "single": { "_0": {
                  "contentOverBackgroundAppearance": "light",
                  "isVibrant": true,
                  "style": { "color": { "_0": { "blendedGradient": { "_0": {
                    "baseColors": [
                      { "red": 1.25, "green": 0.5, "blue": 0.25, "alpha": 1, "colorSpace": "extendedSRGB" },
                      { "red": 0.1, "green": 0.2, "blue": 0.3, "alpha": 1, "colorSpace": "extendedSRGB" }
                    ],
                    "overlayColors": [{ "red": 0, "green": 0, "blue": 0, "alpha": 1, "colorSpace": "extendedSRGB" }],
                    "modifiers": { "intensityFactor": 0.8, "noiseFactor": 0.25, "overlay": "grain" },
                    "translucencyStyle": "default",
                    "wheel": { "analogous": {} }
                  } } } } }
                } } },
                "primaryColorPalette": {
                  "midTone": { "red": 0.9, "green": 0.9, "blue": 0.9, "alpha": 1, "colorSpace": "extendedSRGB" }
                }
              }
            }
          },
          "thebrowser.company.defaultPersonalSpaceID",
          {
            "id": "thebrowser.company.defaultPersonalSpaceID",
            "title": "Work",
            "containerIDs": ["pinned", "PIN-WORK", "unpinned", "UNPIN-WORK"],
            "profile": { "custom": { "_0": { "directoryBasename": "Profile 1", "machineID": "m" } } },
            "customInfo": {
              "iconType": { "emoji_v2": "🧪" },
              "windowTheme": {
                "background": { "single": { "_0": {
                  "style": { "color": { "_0": { "blendedSingleColor": { "_0": {
                    "color": { "red": 0.2, "green": 0.4, "blue": 0.6, "alpha": 1, "colorSpace": "extendedSRGB" },
                    "modifiers": { "intensityFactor": 0.1, "noiseFactor": 0, "overlay": "none" },
                    "translucencyStyle": "default"
                  } } } } }
                } } }
              }
            }
          }
        ],
        "items": [
          "TOP-DEFAULT", {
            "id": "TOP-DEFAULT", "parentID": null, "childrenIds": ["FAV-1"], "title": null, "createdAt": 700000000,
            "data": { "itemContainer": { "containerType": { "topApps": { "_0": { "default": true } } } } }
          },
          "TOP-WORK", {
            "id": "TOP-WORK", "parentID": null, "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "itemContainer": { "containerType": { "topApps": { "_0": {
              "custom": { "_0": { "directoryBasename": "Profile 1", "machineID": "m" } } } } } } }
          },
          "FAV-1", {
            "id": "FAV-1", "parentID": "TOP-DEFAULT", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "tab": { "savedURL": "https://mail.example.com/", "savedTitle": "Mail", "timeLastActiveAt": 700000100 } }
          },
          "PIN-HOME", {
            "id": "PIN-HOME", "parentID": null, "childrenIds": ["FOLDER-1", "PINNED-1"], "title": null, "createdAt": 700000000,
            "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "11111111-1111-1111-1111-111111111111" } } } }
          },
          "UNPIN-HOME", {
            "id": "UNPIN-HOME", "parentID": null, "childrenIds": ["TAB-1", "INTERNAL", "MISSING"], "title": null, "createdAt": 700000000,
            "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "11111111-1111-1111-1111-111111111111" } } } }
          },
          "FOLDER-1", {
            "id": "FOLDER-1", "parentID": "PIN-HOME", "childrenIds": ["SPLIT-1", "WELCOME", "NESTED-TAB"], "title": "Reading", "createdAt": 700000000,
            "data": { "list": {} }
          },
          "SPLIT-1", {
            "id": "SPLIT-1", "parentID": "FOLDER-1", "childrenIds": ["SPLIT-A", "SPLIT-B"], "title": null, "createdAt": 700000000,
            "data": { "splitView": { "layoutOrientation": "horizontal", "itemWidthFactors": [], "customInfo": null, "focusItemID": null, "timeLastActiveAt": null } }
          },
          "SPLIT-A", {
            "id": "SPLIT-A", "parentID": "SPLIT-1", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "tab": { "savedURL": "https://a.example.com/", "savedTitle": "A" } }
          },
          "SPLIT-B", {
            "id": "SPLIT-B", "parentID": "SPLIT-1", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "tab": { "savedURL": "https://b.example.com/", "savedTitle": "B" } }
          },
          "WELCOME", {
            "id": "WELCOME", "parentID": "FOLDER-1", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "welcomeToArc": { "tabType": "welcome", "timeLastActiveAt": 700000000 } }
          },
          "NESTED-TAB", {
            "id": "NESTED-TAB", "parentID": "FOLDER-1", "childrenIds": [], "title": "My Name", "createdAt": 700000000,
            "data": { "tab": { "savedURL": "https://docs.example.com/guide", "savedTitle": "Guide — Docs", "savedMuteStatus": "allowAudio" } }
          },
          "PINNED-1", {
            "id": "PINNED-1", "parentID": "PIN-HOME", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "tab": { "savedURL": "https://calendar.example.com/", "savedTitle": "Calendar" } }
          },
          "TAB-1", {
            "id": "TAB-1", "parentID": "UNPIN-HOME", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "tab": { "savedURL": "https://news.example.com/story", "savedTitle": "Story", "timeLastActiveAt": 1 } }
          },
          "INTERNAL", {
            "id": "INTERNAL", "parentID": "UNPIN-HOME", "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "tab": { "savedURL": "arc://settings", "savedTitle": "Settings" } }
          },
          "PIN-WORK", {
            "id": "PIN-WORK", "parentID": null, "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "thebrowser.company.defaultPersonalSpaceID" } } } }
          },
          "UNPIN-WORK", {
            "id": "UNPIN-WORK", "parentID": null, "childrenIds": [], "title": null, "createdAt": 700000000,
            "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "thebrowser.company.defaultPersonalSpaceID" } } } }
          }
        ]
      }
    ]
  }
}
"""

private let importDate = Date(timeIntervalSince1970: 1_800_000_000)

private func importFixture() throws -> ArcImportResult {
    try ArcImporter.importSidebar(data: Data(fixture.utf8), now: importDate)
}

@Suite struct ArcImporterTests {
    @Test func importsSpacesInFileOrder() throws {
        let result = try importFixture()
        #expect(result.spaces.map(\.name) == ["Home", "Work"])
        #expect(result.spaces[0].id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    @Test func buildsPinnedTreeWithFoldersAndDissolvedSplits() throws {
        let home = try importFixture().spaces[0]
        #expect(home.pinned.map(\.kind) == [.folder, .tab])

        let folder = home.pinned[0]
        #expect(folder.title == "Reading")
        // The split view's two tabs take its place; the onboarding card is dropped.
        #expect(folder.children.map(\.url?.host) == ["a.example.com", "b.example.com", "docs.example.com"])
        #expect(home.pinned[1].title == "Calendar")
    }

    @Test func pinnedTabsRememberTheirHomeAndUnpinnedTabsDoNot() throws {
        let home = try importFixture().spaces[0]
        let calendar = home.pinned[1]
        #expect(calendar.homeURL == calendar.url)
        #expect(home.tabs.count == 1)
        #expect(home.tabs[0].homeURL == nil)
    }

    @Test func keepsCustomTitlesSeparateFromPageTitles() throws {
        let renamed = try importFixture().spaces[0].pinned[0].children[2]
        #expect(renamed.title == "Guide — Docs")
        #expect(renamed.customTitle == "My Name")
        #expect(renamed.displayTitle == "My Name")
    }

    @Test func skipsInternalPagesAndDanglingReferences() throws {
        let result = try importFixture()
        #expect(result.spaces[0].tabs.map(\.url?.absoluteString) == ["https://news.example.com/story"])
        // The onboarding card and the arc:// page. A dangling child id is ignored, not counted.
        #expect(result.stats.skipped == 2)
    }

    @Test func importedTabsStartAFreshArchiveClock() throws {
        let tab = try importFixture().spaces[0].tabs[0]
        #expect(tab.lastActiveAt == importDate)
        #expect(tab.createdAt == Date(timeIntervalSinceReferenceDate: 700_000_000))
    }

    @Test func readsGradientAndSingleColorThemes() throws {
        let spaces = try importFixture().spaces
        // Extended sRGB components are clamped into range.
        #expect(spaces[0].theme.colors == [
            RGBAColor(red: 1, green: 0.5, blue: 0.25),
            RGBAColor(red: 0.1, green: 0.2, blue: 0.3),
        ])
        #expect(spaces[0].theme.intensity == 0.8)
        #expect(spaces[1].theme.colors == [RGBAColor(red: 0.2, green: 0.4, blue: 0.6)])
        // Very faint themes are raised to a visible floor.
        #expect(spaces[1].theme.intensity == 0.35)
    }

    @Test func mapsIconsToSymbolsAndEmoji() throws {
        let spaces = try importFixture().spaces
        #expect(spaces[0].icon == .symbol("bolt.fill"))
        #expect(spaces[1].icon == .emoji("🧪"))
    }

    @Test func groupsSpacesAndFavoritesByProfile() throws {
        let result = try importFixture()
        #expect(result.profiles.count == 2)
        #expect(result.profiles[0].id == ArcImporter.defaultProfileID)
        #expect(result.profiles[0].favorites.map(\.title) == ["Mail"])
        #expect(result.profiles[0].favorites[0].homeURL != nil)
        #expect(result.spaces[0].profileID == ArcImporter.defaultProfileID)
        #expect(result.spaces[1].profileID == result.profiles[1].id)
        #expect(result.spaces[1].profileID != ArcImporter.defaultProfileID)
    }

    @Test func reportsWhatItFound() throws {
        let stats = try importFixture().stats
        #expect(stats.spaces == 2)
        #expect(stats.pinnedTabs == 4)
        #expect(stats.folders == 1)
        #expect(stats.unpinnedTabs == 1)
        #expect(stats.favorites == 1)
    }

    @Test func isDeterministicAcrossRuns() throws {
        #expect(try importFixture() == importFixture())
    }

    @Test func rejectsFilesThatAreNotSidebars() {
        #expect(throws: ArcImportError.notJSON) {
            try ArcImporter.importSidebar(data: Data("not json".utf8))
        }
        #expect(throws: ArcImportError.self) {
            try ArcImporter.importSidebar(data: Data(#"{"sidebar": {"containers": [{"global": {}}]}}"#.utf8))
        }
        #expect(throws: ArcImportError.self) {
            try ArcImporter.importSidebar(at: URL(fileURLWithPath: "/nonexistent/StorableSidebar.json"))
        }
    }

    @Test func survivesItemsThatReferenceEachOther() throws {
        let cyclic = """
        {"sidebar": {"containers": [{
          "spaces": ["S", {"id": "S", "title": "Loop", "containerIDs": ["pinned", "P", "unpinned", "U"]}],
          "items": [
            "P", {"id": "P", "childrenIds": ["F"], "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "S"}}}}},
            "U", {"id": "U", "childrenIds": [], "data": {"itemContainer": {"containerType": {"spaceItems": {"_0": "S"}}}}},
            "F", {"id": "F", "childrenIds": ["F", "T"], "title": "Self", "data": {"list": {}}},
            "T", {"id": "T", "childrenIds": [], "data": {"tab": {"savedURL": "https://example.com/"}}}
          ]
        }]}}
        """
        let space = try ArcImporter.importSidebar(data: Data(cyclic.utf8)).spaces[0]
        #expect(space.pinned.count == 1)
        #expect(space.pinned[0].children.map(\.url?.host) == ["example.com"])
    }
}

@Suite struct ArcMergeTests {
    @Test func mapsArcDefaultProfileOntoTheLocalDefault() throws {
        var state = BrowserState.fresh()
        let localDefault = state.profiles[0].id
        let summary = state.merge(try importFixture())

        #expect(summary.addedSpaceIDs.count == 2)
        #expect(state.spaces.map(\.name) == ["Personal", "Home", "Work"])
        #expect(state.spaces[1].profileID == localDefault)
        #expect(state.profiles[0].favorites.map(\.title) == ["Mail"])
        #expect(state.profiles.count == 2)
        #expect(state.spaces[2].profileID == state.profiles[1].id)
    }

    @Test func importingTwiceChangesNothing() throws {
        var state = BrowserState.fresh()
        state.merge(try importFixture())
        state.spaces[1].name = "Renamed since import"
        let before = state

        let summary = state.merge(try importFixture())
        #expect(summary.addedSpaceIDs.isEmpty)
        #expect(summary.skippedSpaces == 2)
        #expect(summary.addedFavorites == 0)
        #expect(state == before)
    }
}
