import AppKit

/// 노치 위치에 떠 있는 테두리 없는 패널. (ARCHITECTURE §3.2)
final class NotchPanel: NSPanel {
    /// 메뉴바(.mainMenu = 24)보다 위, 메뉴바 드롭다운 메뉴(.popUpMenu = 101)보다 아래.
    static let notchLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = Self.notchLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // 입력창처럼 키보드가 필요한 뷰를 클릭했을 때만 key 창이 된다 (T-001b).
        // 그 외(표시, 체크박스 클릭 등)에는 key가 되지 않아 입력창이 저절로 포커스를 받지 않는다.
        becomesKeyOnlyIfNeeded = true
        initialFirstResponder = nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 메뉴바 영역에 놓아도 시스템이 아래로 밀어내지 않도록 프레임을 그대로 둔다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
