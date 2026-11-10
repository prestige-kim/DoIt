#!/usr/bin/env swift
// DoIt 아이콘 생성 (T-010, DESIGN.md "앱 아이콘: D안 검은 목록")
// 외부 도구 없이 CoreGraphics로 그려 PNG로 저장한다. 결과 PNG는 커밋한다 (앱 빌드 때 이 스크립트는 돌지 않음).
//
// 사용법: swift scripts/make-icons.swift      (저장소 루트에서)
// 만드는 것:
//   DoIt/Resources/Assets.xcassets/AppIcon.appiconset/    앱 아이콘 16~1024 (10개)
//   DoIt/Resources/Assets.xcassets/MenuBarIcon.imageset/  메뉴바 단색 템플릿 18pt @1x·@2x
//
// ※ 색 예외: 이 스크립트 안의 hex 색은 앱 UI 규칙(Asset 역할 색만 사용)의 예외다.
//   아이콘 그림 자체의 색이며 DESIGN.md D안 값 그대로다. 앱 코드에는 hex 색을 쓰지 않는다.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: 색 (DESIGN.md D안 — 아이콘 전용 예외)
func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let background = hex(0x161618)   // 검은 둥근 사각형
let green = hex(0x3FBF7F)        // 1줄: 초록 원
let blue = hex(0x6E9BFF)         // 2줄: 파란 점 (LMS)
let gray = hex(0x6A6A70)         // 3줄: 회색 빈 원·회색 줄
let light = hex(0xECECEF)        // 밝은 줄
let white = hex(0xFFFFFF)        // 체크

// MARK: 공통 그림 (단위: 0~1 비율, 원점 왼쪽 아래)

/// 세 줄의 배치 (아이콘 몸통 안 비율). 위에서부터 1·2·3줄
struct Row { let y: CGFloat; let lineEnd: CGFloat }
let rows = [Row(y: 0.70, lineEnd: 0.80), Row(y: 0.50, lineEnd: 0.80), Row(y: 0.30, lineEnd: 0.64)]
let markX: CGFloat = 0.28       // 원 중심 x
let markR: CGFloat = 0.075      // 원 반지름
let lineStart: CGFloat = 0.42
let lineWidth: CGFloat = 0.06

func checkPath(center c: CGPoint, r: CGFloat) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x - r * 0.45, y: c.y + r * 0.02))
    p.addLine(to: CGPoint(x: c.x - r * 0.12, y: c.y - r * 0.32))
    p.addLine(to: CGPoint(x: c.x + r * 0.48, y: c.y + r * 0.36))
    return p
}

func pngData(size px: Int, draw: (CGContext, CGFloat) -> Void) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(px))
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

// MARK: 앱 아이콘 (컬러)

/// macOS 아이콘 격자: 1024 캔버스에 824 몸통(가장자리 100), 모서리 반지름 약 185
func drawAppIcon(_ ctx: CGContext, _ s: CGFloat) {
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2245
    // 아주 옅은 그림자 (Big Sur 이후 아이콘처럼 살짝 떠 보이게, 작은 크기에서는 생략)
    if s >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.02, color: hex(0x000000, 0.35))
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(background)
        ctx.fillPath()
        ctx.restoreGState()
    } else {
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(background)
        ctx.fillPath()
    }

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: body.minX + x * body.width, y: body.minY + y * body.height) }
    let r = markR * body.width
    let lw = lineWidth * body.width
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    for (i, row) in rows.enumerated() {
        let c = pt(markX, row.y)
        switch i {
        case 0:  // 초록 원 + 흰 체크
            ctx.setFillColor(green)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.addPath(checkPath(center: c, r: r))
            ctx.setStrokeColor(white)
            ctx.setLineWidth(r * 0.30)
            ctx.strokePath()
        case 1:  // 파란 점 (조금 작게)
            let d = r * 0.62
            ctx.setFillColor(blue)
            ctx.fillEllipse(in: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2))
        default: // 회색 빈 원
            let w = r * 0.24
            ctx.setStrokeColor(gray)
            ctx.setLineWidth(w)
            ctx.strokeEllipse(in: CGRect(x: c.x - r + w / 2, y: c.y - r + w / 2, width: r * 2 - w, height: r * 2 - w))
        }
        // 줄
        ctx.setStrokeColor(i == 2 ? gray : light)
        ctx.setLineWidth(lw)
        ctx.move(to: pt(lineStart, row.y))
        ctx.addLine(to: pt(row.lineEnd, row.y))
        ctx.strokePath()
    }
}

// MARK: 메뉴바 템플릿 (단색 검정 + 투명, macOS가 메뉴바에 맞게 색을 입힌다)

func drawMenuBarIcon(_ ctx: CGContext, _ s: CGFloat) {
    let ink = hex(0x000000)
    // 18pt 칸 안에서 위아래 여백 약 1.5pt
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    let ys: [CGFloat] = [0.78, 0.50, 0.22]
    let ends: [CGFloat] = [0.94, 0.94, 0.76]
    let r = 0.13 * s
    let mx = 0.17 * s
    let lw = 0.11 * s
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for i in 0..<3 {
        let c = CGPoint(x: mx, y: ys[i] * s)
        switch i {
        case 0:  // 채운 원에서 체크를 오려 낸다
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.addPath(checkPath(center: c, r: r))
            ctx.setLineWidth(r * 0.34)
            ctx.strokePath()
            ctx.restoreGState()
        case 1:  // 점
            let d = r * 0.62
            ctx.setFillColor(ink)
            ctx.fillEllipse(in: CGRect(x: c.x - d, y: c.y - d, width: d * 2, height: d * 2))
        default: // 빈 원
            let w = r * 0.30
            ctx.setStrokeColor(ink)
            ctx.setLineWidth(w)
            ctx.strokeEllipse(in: CGRect(x: c.x - r + w / 2, y: c.y - r + w / 2, width: r * 2 - w, height: r * 2 - w))
        }
        ctx.setStrokeColor(ink)
        ctx.setLineWidth(lw)
        ctx.move(to: pt(0.40, ys[i]))
        ctx.addLine(to: pt(ends[i], ys[i]))
        ctx.strokePath()
    }
}

// MARK: 저장

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("DoIt/Resources/Assets.xcassets")
guard FileManager.default.fileExists(atPath: assets.path) else {
    print("저장소 루트에서 실행하세요: swift scripts/make-icons.swift")
    exit(1)
}

func write(_ data: Data, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

// 앱 아이콘: (pt 크기, 배율)
let appIconDir = assets.appendingPathComponent("AppIcon.appiconset")
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try write(pngData(size: size * scale, draw: drawAppIcon), appIconDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let appIconJSON: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try write(try JSONSerialization.data(withJSONObject: appIconJSON, options: [.prettyPrinted, .sortedKeys]),
          appIconDir.appendingPathComponent("Contents.json"))

// 메뉴바 템플릿: 18pt @1x(18px)·@2x(36px)
let menuDir = assets.appendingPathComponent("MenuBarIcon.imageset")
try write(pngData(size: 18, draw: drawMenuBarIcon), menuDir.appendingPathComponent("menubar.png"))
try write(pngData(size: 36, draw: drawMenuBarIcon), menuDir.appendingPathComponent("menubar@2x.png"))
let menuJSON: [String: Any] = [
    "images": [
        ["idiom": "universal", "scale": "1x", "filename": "menubar.png"],
        ["idiom": "universal", "scale": "2x", "filename": "menubar@2x.png"],
        ["idiom": "universal", "scale": "3x"],
    ],
    "info": ["author": "xcode", "version": 1],
    "properties": ["template-rendering-intent": "template"],
]
try write(try JSONSerialization.data(withJSONObject: menuJSON, options: [.prettyPrinted, .sortedKeys]),
          menuDir.appendingPathComponent("Contents.json"))

print("만듦: AppIcon 10개, MenuBarIcon 2개")
