import AppKit

/// 노치를 어디에 그릴지 계산한다. (ARCHITECTURE §3.1)
struct NotchGeometry: Equatable {
    /// 대상 화면 전체 프레임 (전역 좌표, 주 디스플레이라 원점은 (0,0))
    let screenFrame: CGRect
    /// 노치 영역 (전역 좌표, AppKit 기준: y가 위로 증가)
    let notchRect: CGRect
    /// 화면에 물리 노치가 있는지
    let hasPhysicalNotch: Bool
    /// 가상 노치를 그리는지 (물리 노치 없음 또는 강제 모드)
    let isVirtual: Bool
    let screenName: String
    let pixelSize: CGSize
    let backingScale: CGFloat

    static let virtualNotchWidth: CGFloat = 180

    /// 메뉴바가 있는 주 디스플레이 = `NSScreen.screens.first` (`NSScreen.main` 사용 금지)
    static func compute(forceVirtual: Bool) -> NotchGeometry? {
        guard let screen = NSScreen.screens.first else { return nil }
        let frame = screen.frame
        let topInset = screen.safeAreaInsets.top
        let hasPhysicalNotch = topInset > 0

        let notchRect: CGRect
        let isVirtual: Bool

        if hasPhysicalNotch, !forceVirtual,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // auxiliary 영역은 화면 기준 좌표. 주 디스플레이는 원점이 (0,0)이라 전역 좌표와 같지만,
            // 혹시 몰라 screen 원점을 더해 준다.
            let minX = frame.minX + left.maxX
            let maxX = frame.minX + right.minX
            notchRect = CGRect(x: minX, y: frame.maxY - topInset, width: maxX - minX, height: topInset)
            isVirtual = false
        } else {
            var height = frame.maxY - screen.visibleFrame.maxY
            if height <= 0 { height = NSStatusBar.system.thickness }
            let width = virtualNotchWidth
            notchRect = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
            isVirtual = true
        }

        let scale = screen.backingScaleFactor
        return NotchGeometry(
            screenFrame: frame,
            notchRect: notchRect,
            hasPhysicalNotch: hasPhysicalNotch,
            isVirtual: isVirtual,
            screenName: screen.localizedName,
            pixelSize: CGSize(width: frame.width * scale, height: frame.height * scale),
            backingScale: scale
        )
    }

    /// 패널을 다른 자리로 옮겨야 하는 변화인지 (화면 프레임 또는 노치 사각형이 바뀜) (T-008).
    /// 화면 이름·배율만 바뀐 경우는 자리가 그대로라 아니다
    static func placementChanged(from old: NotchGeometry, to new: NotchGeometry) -> Bool {
        old.screenFrame != new.screenFrame || old.notchRect != new.notchRect
    }

    /// 사람이 읽을 수 있는 디버그 정보 (줄 단위)
    var debugLines: [String] {
        func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
        return [
            "화면: \(screenName)",
            "해상도: \(Int(screenFrame.width))×\(Int(screenFrame.height))pt (\(Int(pixelSize.width))×\(Int(pixelSize.height))px, @\(f(backingScale))x)",
            "물리 노치: \(hasPhysicalNotch ? "있음" : "없음") · 그리는 노치: \(isVirtual ? "가상" : "실제")",
            "노치 사각형: x=\(f(notchRect.minX)) y=\(f(notchRect.minY)) w=\(f(notchRect.width)) h=\(f(notchRect.height))",
        ]
    }
}
