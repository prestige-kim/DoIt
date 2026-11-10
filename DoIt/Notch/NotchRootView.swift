import SwiftUI

/// 패널 전체를 그리는 루트 뷰 (T-011 디자인, DESIGN.md 노치 패널 · ARCHITECTURE §3.0)
///
/// - 접힘: **검은 노치 그대로** (실제 노치·가상 노치 모두)
/// - 펼침: 노치 모양 전체가 양옆·아래로 커지며 노치 옆 메뉴바 띠까지 패널이 된다 (T-004와 같은 연출, 사용자 요청).
///   커지면서 검정이 패널 바탕색으로 바뀐다. 시간·곡선은 기존 펼침·접힘 애니메이션(`isShapeExpanded`) 그대로
/// - 노치 옆 띠: 왼쪽 `DoIt · 날짜`, 오른쪽 `📆(달력에서는 목록) · ⚙`
/// - 옅은 테두리·그림자는 펼친 상태에서만 (ARCHITECTURE §5-3)
/// - 내용은 항상 펼친 크기로 배치하고 노치 모양으로 잘라낸다 (줄어들 때 노치로 말려 들어가는 느낌)
struct NotchRootView: View {
    let viewModel: NotchViewModel

    var body: some View {
        let expanded = viewModel.isShapeExpanded
        let notch = viewModel.notchSize
        let topRadius = expanded ? NotchViewModel.expandedTopRadius : NotchViewModel.collapsedTopRadius
        let bottomRadius = expanded ? NotchViewModel.cardCornerRadius : NotchViewModel.collapsedBottomRadius
        let body = expanded ? CGSize(width: viewModel.shapeCardWidth, height: viewModel.shapeBodyHeight) : notch
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
        let ear = NotchViewModel.expandedTopRadius

        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                Palette.panelBackground
                Palette.notchBlack.opacity(expanded ? 0 : 1)
                VStack(spacing: 0) {
                    PanelTopBand(viewModel: viewModel)
                        .frame(height: notch.height)
                    TodoPanelContent(viewModel: viewModel)
                }
                .padding(.horizontal, ear)
                .frame(width: viewModel.contentCardWidth + 2 * ear, height: viewModel.contentBodyHeight, alignment: .top)
                .opacity(viewModel.isContentVisible ? 1 : 0)
                .allowsHitTesting(viewModel.isContentVisible)
            }
            .frame(width: body.width + 2 * topRadius, height: body.height, alignment: .top)
            .clipShape(shape)
            .overlay(shape.stroke(Palette.cardBorder.opacity(expanded ? 1 : 0), lineWidth: 1))
            // 그림자는 펼친 상태에서만 (접히면 색 없음·반경 0)
            .shadow(color: expanded ? Palette.cardShadow : .clear, radius: expanded ? 10 : 0, x: 0, y: expanded ? 4 : 0)

            // 노치 자리는 항상 검정 (가상 노치가 빈 공간을 메움, ARCHITECTURE §3.0)
            NotchShape(topRadius: NotchViewModel.collapsedTopRadius, bottomRadius: NotchViewModel.collapsedBottomRadius)
                .fill(Palette.notchBlack)
                .frame(width: notch.width + 2 * NotchViewModel.collapsedTopRadius, height: notch.height)
                .allowsHitTesting(false)

            // 노치 알림 (T-005): 검은 노치가 양옆·아래로 조금 넓어진 캡슐
            if let alert = viewModel.alertContent {
                NotchAlertView(viewModel: viewModel, content: alert)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// 노치 옆 메뉴바 띠의 머리줄: 왼쪽 `DoIt · 11/8(일)` | 노치 | 오른쪽 `📆`(달력에서는 목록) · `⚙`
private struct PanelTopBand: View {
    let viewModel: NotchViewModel

    var body: some View {
        let calendar = viewModel.panelMode == .calendar
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("DoIt")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.primaryText)
                Text(DueDateLabel.short(viewModel.store.today))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Palette.secondaryText)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)

            // 노치 자리 (검은 노치가 위에 그려짐)
            Color.clear.frame(width: viewModel.notchSize.width + 12)

            HStack(spacing: 2) {
                PanelIconButton(symbol: calendar ? "list.bullet" : "calendar",
                                help: calendar ? "목록으로" : "달력") { viewModel.togglePanelMode() }
                PanelIconButton(symbol: "square.and.pencil", help: "전체 편집기") { viewModel.openEditor() }
                PanelIconButton(symbol: "gearshape", help: "설정") { viewModel.openSettings() }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, PanelLayout.horizontalPadding)
    }
}

/// 노치 알림 (DESIGN.md 노치 알림, 다이나믹 아일랜드 방식). 바탕은 펼친 패널과 같은 색
/// (밝은 모드 = 흰색 + 옅은 테두리, 어두운 모드 = 노치 검정 — 2026-11-08 사용자 결정). 노치 크기일 때는 검정에서 시작해 넓어지며 바뀐다.
/// 노치 자리(카메라)는 항상 검정을 겹쳐 그린다
/// 노치 줄: 왼쪽 `● 오늘 마감 n개` | 노치(카메라 자리) | 오른쪽 `×` / 아랫줄: 요약 한 줄
/// 넓어짐·줄어듦은 `isAlertOpen` 애니메이션. 마우스를 올리면(hover는 상태 머신) 또는 누르면 평소 패널로 펼친다
private struct NotchAlertView: View {
    let viewModel: NotchViewModel
    let content: NotchAlertContent

    @State private var closeHover = false

    var body: some View {
        let open = viewModel.isAlertOpen
        let notch = viewModel.notchSize
        let size = open ? viewModel.alertSize : notch
        let top = open ? NotchViewModel.alertTopRadius : NotchViewModel.collapsedTopRadius
        let bottom = open ? NotchViewModel.alertBottomRadius : NotchViewModel.collapsedBottomRadius
        let shape = NotchShape(topRadius: top, bottomRadius: bottom)
        let full = viewModel.alertSize

        ZStack(alignment: .top) {
            Palette.panelBackground
            Palette.notchBlack.opacity(open ? 0 : 1)
            // 노치 자리는 항상 검정 (가상 노치 포함)
            NotchShape(topRadius: NotchViewModel.collapsedTopRadius, bottomRadius: NotchViewModel.collapsedBottomRadius)
                .fill(Palette.notchBlack)
                .frame(width: notch.width + 2 * NotchViewModel.collapsedTopRadius, height: notch.height)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(content.includesLms ? Palette.lmsAccent : Palette.todoAccent)
                            .frame(width: 7, height: 7)
                        Text(content.title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Palette.primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear.frame(width: notch.width)  // 카메라 자리

                    Button { viewModel.closeAlert() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(closeHover ? Palette.primaryText : Palette.secondaryText)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Palette.inputBackground))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { closeHover = $0 }
                    .help("닫기")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: notch.height)

                Text(content.body)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .frame(height: NotchViewModel.alertLineHeight, alignment: .top)
            }
            .padding(.horizontal, 12)
            .frame(width: full.width, height: full.height, alignment: .top)
            .opacity(open ? 1 : 0)
        }
        .frame(width: size.width + 2 * top, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay(shape.stroke(Palette.cardBorder.opacity(open ? 1 : 0), lineWidth: 1))  // 밝은 모드만 보이는 옅은 테두리
        .contentShape(shape)
        .onTapGesture { viewModel.alertTapped() }
    }
}
