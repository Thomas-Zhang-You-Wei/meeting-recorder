// 產生 App 圖示：Resources/AppIcon.icns
// 用法：swiftc（同 build.sh 的 VFS 參數）編譯後執行，或直接跑 ./scripts/make_icon.sh
// 設計：深藍綠漸層圓角方塊，左邊白色麥克風，右邊三條逐字稿線條，右上角紅色錄製點。
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS 圖示網格：1024 畫布裡的主體是 824×824，四邊留 100
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185

// 陰影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(path)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 漸層底
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [NSColor(srgbRed: 0.06, green: 0.20, blue: 0.30, alpha: 1).cgColor,
              NSColor(srgbRed: 0.05, green: 0.42, blue: 0.47, alpha: 1).cgColor] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 100), end: CGPoint(x: 924, y: 924), options: [])
// 上緣一點高光
let hl = [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
ctx.drawLinearGradient(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hl, locations: [0, 1])!,
                       start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
ctx.restoreGState()

// 麥克風（SF Symbol）
let cfg = NSImage.SymbolConfiguration(pointSize: 360, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let s = mic.size
    let h: CGFloat = 430
    let w = s.width * h / s.height
    mic.draw(in: CGRect(x: 322 - w / 2, y: 512 - h / 2, width: w, height: h))
}

// 逐字稿線條
ctx.setLineCap(.round)
ctx.setLineWidth(46)
let lines: [(CGFloat, CGFloat, CGFloat)] = [(640, 500, 810), (512, 500, 770), (384, 500, 700)]
for (i, l) in lines.enumerated() {
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(i == 1 ? 0.95 : 0.6).cgColor)
    ctx.move(to: CGPoint(x: l.1, y: l.0))
    ctx.addLine(to: CGPoint(x: l.2, y: l.0))
    ctx.strokePath()
}

// 紅色錄製點
ctx.setFillColor(NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: 760, y: 760, width: 92, height: 92))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("寫出 \(out)")
