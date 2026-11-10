import SwiftUI

/// 화면 색 (docs/DESIGN.md 색 표, ARCHITECTURE §3.0). 실제 값은 `Assets.xcassets`의 밝은/어두운 쌍에 있고,
/// 코드는 **역할 이름만** 쓴다 (hex 직접 사용 금지). 시스템 밝은·어두운 설정을 따라 자동으로 바뀐다
enum Palette {
    /// 펼친 패널 바탕 (어두운 모드는 노치와 같은 검정 — 2026-11-08 사용자 요청, DESIGN.md #1E1E20 대신)
    static let panelBackground = Color("PanelBackground")
    static let primaryText = Color("PrimaryText")
    static let secondaryText = Color("SecondaryText")
    /// 내 할 일 강조 (이화 그린)
    static let todoAccent = Color("TodoAccent")
    /// 그린 옅은 바탕 (선택한 날, "내 할 일" 칩)
    static let todoAccentSoft = Color("TodoAccentSoft")
    /// LMS 강조 (남색·파랑)
    static let lmsAccent = Color("LmsAccent")
    /// LMS 옅은 바탕 (과목명 칩, 개수 배지)
    static let lmsAccentSoft = Color("LmsAccentSoft")
    /// 지난 마감
    static let overdue = Color("OverdueAccent")
    /// 지난 마감 행 바탕
    static let overdueSoft = Color("OverdueSoft")
    /// 빈 체크 원 테두리
    static let checkRing = Color("CheckRing")
    static let separator = Color("Separator")
    static let inputBackground = Color("InputBackground")
    /// 패널 옅은 테두리 (어두운 모드는 없음: 검정 패널이 노치와 이어져 보이게)
    static let cardBorder = Color("CardBorder")
    /// 카드 그림자 (펼친 상태에서만)
    static let cardShadow = Color("CardShadow")
    /// 접힌 노치 자리 (실제·가상 모두 항상 검정, ARCHITECTURE §3.0)
    static let notchBlack = Color("NotchBlack")
    /// 강조색 위 글자 (오늘 날짜 초록 원 안 숫자)
    static let onAccent = Color("OnAccent")
    /// 잘린 제목 말풍선 (두 모드 모두 어두운 말풍선)
    static let bubbleBackground = Color("BubbleBackground")
    static let bubbleText = Color("BubbleText")
    static let bubbleSecondaryText = Color("BubbleSecondaryText")
}
