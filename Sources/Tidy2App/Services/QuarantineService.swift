import Foundation

final class QuarantineService: QuarantineServiceProtocol {
    private let store: SQLiteStore

    init(store: SQLiteStore) {
        self.store = store
    }

    func listActiveItems() throws -> [QuarantineItem] {
        try store.listActiveQuarantineItems()
    }

    func listItems(filter: QuarantineListFilter) throws -> [QuarantineItem] {
        switch filter {
        case .active:
            return try store.listQuarantineItems(states: [.active])
        case .expired:
            return try store.listQuarantineItems(states: [.expired])
        }
    }
}
