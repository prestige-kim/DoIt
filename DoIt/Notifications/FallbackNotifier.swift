import Foundation
import UserNotifications
import os

private let fallbackLogger = Logger(subsystem: "com.personal.doit", category: "alert")

/// macOS 알림 권한 상태 (설정 화면용)
enum AlertPermission: Equatable {
    case notDetermined, denied, authorized
}

/// `UNUserNotificationCenter`에서 쓰는 것만 (테스트는 가짜로)
protocol LocalNotificationCenter: AnyObject {
    func pendingIdentifiers(_ completion: @escaping ([String]) -> Void)
    func removePending(identifiers: [String])
    func add(identifier: String, title: String, body: String, at components: DateComponents,
             completion: @escaping (Error?) -> Void)
    func permission(_ completion: @escaping (AlertPermission) -> Void)
    func requestPermission(_ completion: @escaping (Bool) -> Void)
}

/// 실제 알림 센터 감싸기
final class SystemNotificationCenter: LocalNotificationCenter {
    private var center: UNUserNotificationCenter { .current() }

    func pendingIdentifiers(_ completion: @escaping ([String]) -> Void) {
        center.getPendingNotificationRequests { completion($0.map(\.identifier)) }
    }

    func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(identifier: String, title: String, body: String, at components: DateComponents,
             completion: @escaping (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger), withCompletionHandler: completion)
    }

    func permission(_ completion: @escaping (AlertPermission) -> Void) {
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .notDetermined: completion(.notDetermined)
            case .denied: completion(.denied)
            default: completion(.authorized)
            }
        }
    }

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in completion(granted) }
    }
}

/// 앱이 **종료돼 있을 때만** 쓰는 대신 예약 (ARCHITECTURE §3.6, D-015)
/// - 종료 직전: 노치 알림과 같은 계획을 macOS 알림으로 예약 (id `doit-day-YYYYMMDD`)
/// - 실행 시: `doit-day-` 대기 알림을 전부 지운다 → 실행 중에는 노치 알림만
final class FallbackNotifier {
    let center: LocalNotificationCenter

    init(center: LocalNotificationCenter) {
        self.center = center
    }

    /// 실행 시: 대신 예약해 둔 알림 삭제. 권한이 미결정이면 1번 요청 (거부여도 노치 알림은 동작)
    func appLaunched() {
        center.pendingIdentifiers { [center] ids in
            let ours = ids.filter { $0.hasPrefix(ReminderPlanner.identifierPrefix) }
            if !ours.isEmpty { center.removePending(identifiers: ours) }
            fallbackLogger.info("launch: removed fallback alerts \(ours.count, privacy: .public)")
        }
        center.permission { [center] status in
            guard status == .notDetermined else { return }
            center.requestPermission { granted in
                fallbackLogger.info("notification permission granted=\(granted, privacy: .public)")
            }
        }
    }

    /// 종료 직전: 계획을 예약하고 끝날 때까지 최대 `wait`초 기다린다 (완료 콜백은 메인이 아닌 큐에서 온다)
    /// - Returns: 예약 성공 개수 (시간 안에 끝난 것만)
    @discardableResult
    func appWillTerminate(plan: [DayReminder], wait: TimeInterval = 2, calendar: Calendar = LocalDate.calendar) -> Int {
        let group = DispatchGroup()
        let lock = NSLock()
        var ok = 0
        for r in plan {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: r.fireDate)
            group.enter()
            center.add(identifier: r.identifier, title: r.content.title, body: r.content.body, at: c) { error in
                if error == nil { lock.lock(); ok += 1; lock.unlock() }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + wait)
        lock.lock(); let done = ok; lock.unlock()
        fallbackLogger.info("terminate: scheduled fallback alerts \(done, privacy: .public)/\(plan.count, privacy: .public)")
        return done
    }
}
