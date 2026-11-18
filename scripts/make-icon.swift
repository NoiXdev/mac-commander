// Generates the AppIcon iconset PNGs: swift scripts/make-icon.swift Resources/AppIcon.iconset
import AppKit
import CoreGraphics

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the icon into a square bitmap of `px` x `px` pixels.
func render(px: Int) -> Data {
    let s = CGFloat(px)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    // Big Sur style: shape inset 10%, corner radius 22.4% of the shape.
    let body = CGRect(x: 0, y: 0, width: s, height: s).insetBy(dx: s * 0.1, dy: s * 0.1)
    let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.224, cornerHeight: body.width * 0.224, transform: nil)
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x1E3A8A), color(0x0F172A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Two light panes side by side with a thin gap.
    let margin = body.width * 0.12
    let gap = body.width * 0.06
    let paneW = (body.width - 2 * margin - gap) / 2
    let paneH = body.height - 2 * margin
    let radius = paneW * 0.12
    let left = CGRect(x: body.minX + margin, y: body.minY + margin, width: paneW, height: paneH)
    let right = left.offsetBy(dx: paneW + gap, dy: 0)
    ctx.setFillColor(color(0x7FB0F5))
    ctx.addPath(CGPath(roundedRect: left, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(color(0xCBD5E1))
    ctx.addPath(CGPath(roundedRect: right, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()

    // Folder-tab glyph on the left pane.
    let gw = paneW * 0.78
    let gh = gw * 0.72
    let gx = left.midX - gw / 2
    let gy = left.midY - gh / 2
    let tabH = gh * 0.22
    ctx.setFillColor(color(0xFFFFFF))
    let tab = CGRect(x: gx, y: gy + gh - tabH, width: gw * 0.45, height: tabH * 1.5)
    ctx.addPath(CGPath(roundedRect: tab, cornerWidth: tabH * 0.4, cornerHeight: tabH * 0.4, transform: nil))
    ctx.fillPath()
    let folder = CGRect(x: gx, y: gy, width: gw, height: gh - tabH)
    ctx.addPath(CGPath(roundedRect: folder, cornerWidth: gw * 0.08, cornerHeight: gw * 0.08, transform: nil))
    ctx.fillPath()

    // Detail rows on the right pane; dropped at small sizes where they would turn to mush.
    if px >= 64 {
        ctx.setFillColor(color(0x1E3A8A, 0.55))
        let rowH = paneH * 0.045
        for i in 0..<4 {
            let y = right.maxY - paneH * 0.14 - CGFloat(i) * rowH * 3.2
            let w = paneW * (i == 3 ? 0.5 : 0.76)
            ctx.addPath(CGPath(roundedRect: CGRect(x: right.minX + paneW * 0.12, y: y, width: w, height: rowH),
                               cornerWidth: rowH / 2, cornerHeight: rowH / 2, transform: nil))
            ctx.fillPath()
        }
    }
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(px: base).write(to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(px: base * 2).write(to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
