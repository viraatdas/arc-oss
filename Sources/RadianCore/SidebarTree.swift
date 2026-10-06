import Foundation

/// Where an item should land among its new siblings.
public enum Placement: Equatable, Sendable {
    case start
    case end
    /// Immediately before the given item, wherever in the section it sits.
    case before(UUID)
    /// Appended to the given folder.
    case inFolder(UUID)
}

extension Array where Element == SidebarItem {
    public func item(withID id: UUID) -> SidebarItem? {
        for element in self {
            if element.id == id { return element }
            if let found = element.children.item(withID: id) { return found }
        }
        return nil
    }

    public func contains(itemWithID id: UUID) -> Bool {
        item(withID: id) != nil
    }

    @discardableResult
    public mutating func updateItem(withID id: UUID, _ body: (inout SidebarItem) -> Void) -> Bool {
        for index in indices {
            if self[index].id == id {
                body(&self[index])
                return true
            }
            if self[index].children.updateItem(withID: id, body) { return true }
        }
        return false
    }

    public mutating func removeItem(withID id: UUID) -> SidebarItem? {
        if let index = firstIndex(where: { $0.id == id }) {
            return remove(at: index)
        }
        for index in indices {
            if let removed = self[index].children.removeItem(withID: id) { return removed }
        }
        return nil
    }

    /// Returns false, leaving the array untouched, when the placement names an item that is not here.
    @discardableResult
    public mutating func place(_ item: SidebarItem, _ placement: Placement) -> Bool {
        switch placement {
        case .start:
            insert(item, at: 0)
            return true
        case .end:
            append(item)
            return true
        case .before(let siblingID):
            return insert(item, beforeItemWithID: siblingID)
        case .inFolder(let folderID):
            guard self.item(withID: folderID)?.isFolder == true else { return false }
            return updateItem(withID: folderID) { folder in
                folder.children.append(item)
                folder.isExpanded = true
            }
        }
    }

    private mutating func insert(_ item: SidebarItem, beforeItemWithID siblingID: UUID) -> Bool {
        if let index = firstIndex(where: { $0.id == siblingID }) {
            insert(item, at: index)
            return true
        }
        for index in indices where self[index].isFolder {
            if self[index].children.insert(item, beforeItemWithID: siblingID) { return true }
        }
        return false
    }

    /// Every tab in the tree, depth first.
    public var allTabs: [SidebarItem] {
        flatMap { $0.isFolder ? $0.children.allTabs : [$0] }
    }

    /// Tabs the user can currently see, skipping the contents of collapsed folders.
    public var visibleTabs: [SidebarItem] {
        flatMap { item -> [SidebarItem] in
            guard item.isFolder else { return [item] }
            return item.isExpanded ? item.children.visibleTabs : []
        }
    }
}
