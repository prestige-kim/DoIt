import SwiftUI

/// 잘린 행 호버 시 전체 이름 상자 — 공용 부품 (T-007에서 LMS 행에 넣고, T-009에서 내 할 일·달력 행으로 넓힘)
///
/// 1. 행은 `.measuresTruncation`으로 글자가 잘렸는지 잰다 (줄이지 않은 같은 내용을 보이지 않게 재서 칸 너비와 비교)
/// 2. 마우스가 올라가 있고 잘렸으면 `.reportsHover`로 자기 위치(anchor)를 알린다
/// 3. 패널 내용 맨 바깥의 `.fullTextBubbleOverlay()`가 그 위치 아래(공간이 모자라면 위)에 상자를 그린다.
///    스크롤 영역 밖에 그려 잘리지 않고, 마우스 이벤트를 받지 않으며, **패널 크기를 바꾸지 않는다**

/// 마우스가 올라간 (잘린) 행
struct RowHover {
    let title: String
    let subtitle: String?
    let anchor: Anchor<CGRect>
}

struct RowHoverKey: PreferenceKey {
    static var defaultValue: [RowHover] { [] }
    static func reduce(value: inout [RowHover], nextValue: () -> [RowHover]) {
        value.append(contentsOf: nextValue())
    }
}

/// 잘림 측정: `content`(화면용, 잘릴 수 있음)의 너비와 `full`(같은 내용을 줄이지 않은 것)의 너비를 비교
private struct TruncationModifier<Full: View>: ViewModifier {
    @Binding var truncated: Bool
    let full: Full
    @State private var available: CGFloat = 0
    @State private var needed: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(alignment: .leading) {
                full.fixedSize().hidden()
                    .background(GeometryReader { g in
                        Color.clear
                            .onAppear { needed = g.size.width; update() }
                            .onChange(of: g.size.width) { _, w in needed = w; update() }
                    })
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { available = g.size.width; update() }
                    .onChange(of: g.size.width) { _, w in available = w; update() }
            })
    }

    private func update() {
        let t = needed > available + 0.5
        if truncated != t { truncated = t }
    }
}

extension View {
    /// 이 뷰(가로로 늘어나는 글자 칸)가 `full`보다 좁아 잘렸는지 `truncated`에 적는다
    func measuresTruncation<Full: View>(_ truncated: Binding<Bool>, @ViewBuilder full: () -> Full) -> some View {
        modifier(TruncationModifier(truncated: truncated, full: full()))
    }

    /// 잘린 행에 마우스가 올라가 있으면 전체 이름 상자를 요청한다
    func reportsHover(_ active: Bool, title: String, subtitle: String?) -> some View {
        anchorPreference(key: RowHoverKey.self, value: .bounds) { anchor in
            active ? [RowHover(title: title, subtitle: subtitle, anchor: anchor)] : []
        }
    }

    /// 패널 내용 맨 바깥에 1번: 전체 이름 상자를 그린다
    func fullTextBubbleOverlay() -> some View {
        overlayPreferenceValue(RowHoverKey.self) { hovers in
            GeometryReader { proxy in
                if let hover = hovers.last {
                    FullTextBubble(hover: hover, rowFrame: proxy[hover.anchor], containerSize: proxy.size)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

/// 전체 제목 + (있으면) 과목명 원문 상자. 행 아래에, 아래 공간이 모자라면 행 위에 놓는다
struct FullTextBubble: View {
    let hover: RowHover
    let rowFrame: CGRect
    let containerSize: CGSize

    var body: some View {
        // 기본은 행 아래 (DESIGN.md). 아래 공간이 모자라면(말풍선이 잘릴 만큼 아래쪽 행) 행 위
        let below = rowFrame.maxY + 56 <= containerSize.height || rowFrame.midY < containerSize.height / 2
        VStack(alignment: .leading, spacing: 3) {
            Text(hover.title)
                .font(.system(size: 12))
                .foregroundStyle(Palette.bubbleText)
            if let subtitle = hover.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.bubbleSecondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // 두 모드 모두 어두운 말풍선 (DESIGN.md)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.bubbleBackground))
        .shadow(color: Palette.cardShadow, radius: 6, x: 0, y: 2)
        .padding(.horizontal, rowFrame.minX)
        .padding(below ? .top : .bottom, below ? rowFrame.maxY + 2 : containerSize.height - rowFrame.minY + 2)
        .frame(width: containerSize.width, height: containerSize.height, alignment: below ? .top : .bottom)
    }
}
