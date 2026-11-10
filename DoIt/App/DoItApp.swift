import SwiftUI

@main
struct DoItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 창 없는 메뉴바 앱. 실제 UI는 AppDelegate가 만드는 메뉴바 아이콘과 노치 패널이다.
        Settings { EmptyView() }
    }
}
