import XCTest

/// 시간 민감 테스트용 대기 도우미 (T-008).
/// 정해진 횟수만큼 돌며 기다리는 대신 "조건이 될 때까지 최대 `timeout`초" 기다린다. 넘으면 실패 메시지를 남긴다.
/// 1ms씩 쉬며 확인한다 (테스트 코드 전용, 앱에는 없음)
@MainActor
@discardableResult
func waitUntil(_ message: @autoclosure () -> String, timeout: TimeInterval = 5,
               file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline {
            XCTFail("\(timeout)초 안에 조건이 되지 않음: \(message())", file: file, line: line)
            return false
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}
