import Foundation

/// 변경 알림을 **여러 곳**에 나눠 주는 작은 목록 (T-006).
/// 기존 단일 콜백(`onTodosChanged`, `LmsStore.onChange`)은 노치 알림 스케줄러·패널이 쓰고 있어서 덮어쓰지 않고,
/// 편집기처럼 나중에 붙는 구독자는 여기에 등록한다. 구독을 풀 때는 `add`가 돌려준 토큰으로 지운다.
@MainActor
final class ChangeObservers {
    struct Token: Hashable { fileprivate let id = UUID() }

    private var handlers: [(Token, () -> Void)] = []

    @discardableResult
    func add(_ handler: @escaping () -> Void) -> Token {
        let token = Token()
        handlers.append((token, handler))
        return token
    }

    func remove(_ token: Token) {
        handlers.removeAll { $0.0 == token }
    }

    var count: Int { handlers.count }

    func notify() {
        for (_, handler) in handlers { handler() }
    }
}
