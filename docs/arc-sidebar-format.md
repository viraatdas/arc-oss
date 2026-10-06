# Arc's sidebar file

Arc has no export feature and no documented storage format. This page records what is known
about the file that holds Arc's sidebar, so that people can move their spaces and tabs to other
browsers. It was worked out by reading the structure of real files (key names and value types,
never their contents). Arc's own program code was not studied or copied.

Everything here describes Arc 1.164 (build 86805) on macOS. Treat it as observed behavior, not a
specification: Arc can change it in any release. `ArcImporter.swift` reads it defensively and skips
anything it does not recognize.

## Where things live

```
~/Library/Application Support/Arc/
├── StorableSidebar.json                     spaces, pinned tabs, folders, favorites, open tabs
├── StorableSidebar.<yyyy-MM-dd-HH-mm-ss-SSS>.json   older copies Arc keeps as backups
├── StorableArchiveItems.json                archived tabs
├── StorableCommandBarAdditionalRanking.json command bar ranking data
├── StorableAuthState.json                   Arc account session (do not share)
├── …FaviconCache/                           cached site icons
└── User Data/                               a Chromium profile directory
    ├── Default/                             the default profile
    └── Profile 1/, Profile 2/, …             additional profiles
```

Arc is a Swift app wrapped around Chromium, which ships inside
`Arc.app/Contents/Frameworks/ArcCore.framework`. Cookies, saved passwords, history and extensions
are in Chromium's formats under `User Data/` and are encrypted with a key held in the login
keychain. This page covers only the sidebar.

## Reading the encoding

The file is the output of Swift's synthesized `Codable` support, written with `JSONEncoder`. Two
rules account for nearly all of its oddities:

1. **Dictionaries with non-string keys become flat arrays** that alternate key, value, key, value.
   Arc keys most collections by a typed identifier, so they come out like this:

   ```json
   "spaces": ["<space id>", { "id": "<space id>", … }, "<space id>", { … }]
   ```

   Each value repeats its own `id`, so a reader can ignore the keys and keep only the objects.

2. **Enums with associated values become single-key objects**, with the case name as the key and
   unnamed associated values under `_0`, `_1`, …:

   ```json
   { "custom": { "_0": { "directoryBasename": "Profile 1", "machineID": "…" } } }
   ```

   An enum case with nothing attached is written as `{ "caseName": {} }`. Some cases appear as
   `{ "caseName": true }` instead, which suggests hand-written encoding in places.

Dates are `Double` seconds since 2001-01-01 00:00:00 UTC (Apple's reference date), not the Unix
epoch. Colors are objects of the form `{ "red", "green", "blue", "alpha", "colorSpace" }` where
`colorSpace` is `"extendedSRGB"`. In extended sRGB, components can fall outside 0…1.

## Top level

```
{
  "version": 1,
  "sidebar": { "containers": [ … ] },     the sidebar itself
  "sidebarSyncState": { … },               CloudKit sync bookkeeping
  "firebaseSyncState": { … }               Firestore sync bookkeeping
}
```

The two sync objects hold change tokens and copies of records (`encodedCKRecordFields` is an
opaque base64 blob). An importer can ignore them.

`sidebar.containers` has two entries. The first is `{ "global": {} }`. The second holds everything:

| Key | Contents |
| --- | --- |
| `spaces` | flat array of space id, space object |
| `items` | flat array of item id, item object. Every node in the sidebar tree lives here. |
| `topAppsContainerIDs` | flat array of profile, container id: where each profile's favorites live |

## Spaces

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Usually a UUID |
| `title` | string | Name shown in the sidebar |
| `containerIDs` | array | `["pinned", <item id>, "unpinned", <item id>]`: the two containers that hold the space's tabs |
| `newContainerIDs` | array | The same pairs with richer keys, e.g. `{"unpinned": {"_0": {"shared": {}}}}` |
| `profile` | enum | `{"default": true}` or `{"custom": {"_0": {"directoryBasename", "machineID"}}}` |
| `customInfo.iconType` | enum | `{"icon": "<name>"}` for a built-in icon, `{"emoji_v2": "🧪"}` (newer) or `{"emoji": <code point>}` (older) |
| `customInfo.windowTheme` | object | The space's colors (below). Absent if the space was never themed. |

`directoryBasename` names a folder under `User Data/`, which ties a space to a Chromium profile.

Built-in icon names are Arc's own vocabulary. `flash` and `planet` have been seen. Radian maps
names it knows to the closest SF Symbol and shows a neutral glyph for the rest.

The default space Arc creates on first launch can use fixed strings instead of UUIDs for its
containers: `thebrowser.company.defaultPersonalSpacePinnedContainerID` and
`thebrowser.company.defaultPersonalSpaceUnpinnedContainerID`.

### Themes

```
windowTheme
├── background.single._0
│   ├── contentOverBackgroundAppearance   "light" | "dark"
│   ├── isVibrant                         bool
│   └── style.color._0                    one of:
│       ├── blendedGradient._0
│       │   ├── baseColors                [color, color, …] the gradient stops
│       │   ├── overlayColors             [color, …]
│       │   ├── modifiers                 { intensityFactor, noiseFactor, overlay }
│       │   ├── translucencyStyle         string
│       │   └── wheel                     { "analogous": {} } and similar: how the picker chose the colors
│       └── blendedSingleColor._0
│           ├── color                     color
│           ├── modifiers                 { intensityFactor, noiseFactor, overlay }
│           └── translucencyStyle         string
├── primaryColorPalette                   { midTone, shaded, shadedDark, tintedLight }: colors
└── semanticColorPalette.appearanceBased.{light,dark}
                                          { background, backgroundExtra, cutoutColor, focus, hover,
                                            foregroundPrimary, foregroundSecondary, foregroundTertiary,
                                            maxContrastColor, minContrastColor, subtitle, title }
```

The palettes are derived from the background, so the background is all an importer needs.
`intensityFactor` runs from 0 to 1. `noiseFactor` is the grain slider.

## Items

Every node in the sidebar, whether a tab, a folder or a container, is an item:

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | UUID |
| `parentID` | string or null | null for containers |
| `childrenIds` | [string] | Children in display order. May reference ids that no longer exist. |
| `title` | string or null | A name the user typed. For a tab this overrides the page title. |
| `createdAt` | double | Reference-date seconds |
| `isUnread` | bool | |
| `originatingDevice` | string | Which machine created it |
| `data` | enum | What the item is (below) |

`data` has exactly one key:

| Case | Contents | Notes |
| --- | --- | --- |
| `tab` | `savedURL`, `savedTitle`, `timeLastActiveAt`, optionally `savedMuteStatus` (`"allowAudio"`), `customInfo.iconType`, `referrerID`, `activeTabBeforeCreationID` | A tab. For pinned tabs, `savedURL` is where the tab is now, not necessarily where it was pinned. |
| `list` | `{}` | A folder. Its contents are its `childrenIds`. Folders nest. |
| `splitView` | `layoutOrientation` (`"horizontal"`), `itemWidthFactors`, `focusItemID`, `customInfo`, `timeLastActiveAt` | Tabs shown side by side. Its children are the tabs. |
| `itemContainer` | `containerType`: `{"spaceItems": {"_0": <space id>}}` or `{"topApps": {"_0": <profile>}}` | The root of a space's pinned or unpinned section, or of a profile's favorites |
| `welcomeToArc` | `tabType`, `timeLastActiveAt` | The onboarding card |

Tabs can hold `arc://` URLs for Arc's internal pages. Those have no meaning outside Arc.

### The tree

```
space.containerIDs.pinned   → itemContainer (spaceItems)
                               ├── tab
                               ├── list ("Reading")
                               │   ├── tab
                               │   ├── splitView
                               │   │   ├── tab
                               │   │   └── tab
                               │   └── list …
                               └── tab
space.containerIDs.unpinned → itemContainer (spaceItems)
                               ├── tab
                               └── splitView …
topAppsContainerIDs[profile] → itemContainer (topApps)
                               └── tab …          the favorites grid
```

Favorites belong to a profile, not a space, which is why every space on a profile shows the same
grid.

## What Radian does with it

`Sources/RadianCore/ArcImporter.swift` turns the file into Radian's model:

- Spaces keep their name, icon, gradient (clamped into sRGB) and intensity. A very faint
  intensity is raised so the theme stays visible.
- Pinned containers keep their folder tree. Split views dissolve into their tabs.
- Unpinned tabs and favorites are flattened, because Radian keeps folders only in the pinned section.
- Arc's ids become Radian's ids. Ids that are not UUIDs are hashed to a stable UUID, so importing
  twice adds nothing the second time and never overwrites changes made since.
- Spaces and favorites on Arc's default profile join Radian's default profile. Each custom Arc
  profile becomes its own Radian profile.
- The onboarding card, `arc://` pages and anything unrecognized are skipped and counted.

Arc's files are only read, never written.
