import SwiftUI

/// 노치 모양: 윗변은 메뉴바와 이어지고(양옆 위 모서리는 바깥으로 살짝 휘어짐), 아래 모서리는 둥글다.
/// 실제 몸통 너비 = 전체 너비 - 2 × topRadius
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let t = min(topRadius, w / 4, h / 2)
        let b = min(bottomRadius, (w - 2 * t) / 2, max(h - t, 0))

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.minY + h - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.minY + h),
                       control: CGPoint(x: rect.minX + t, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - t - b, y: rect.minY + h))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w - t, y: rect.minY + h - b),
                       control: CGPoint(x: rect.minX + w - t, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + w - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.minX + w, y: rect.minY),
                       control: CGPoint(x: rect.minX + w - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
