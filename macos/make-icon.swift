// Draws the app icon (a looper track button: red LED ring, green play centre) and
// writes a 1024px PNG.   swift macos/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
ctx.drawLinearGradient(CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.13, alpha: 1), CGColor(gray: 0.03, alpha: 1)] as CFArray, locations: [0, 1])!,
                       start: CGPoint(x: 0, y: size - inset), end: CGPoint(x: 0, y: inset), options: [])
ctx.setFillColor(CGColor(red: 0.82, green: 0.06, blue: 0.11, alpha: 1))
ctx.fill(CGRect(x: inset, y: size - inset - 34, width: size - 2 * inset, height: 34))

let center = CGPoint(x: size / 2, y: size / 2 - 12)
let segments = 24
for i in 0..<segments {
    let lit = i < 17
    let start = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(segments) - 0.03
    let end = start - 2 * .pi / CGFloat(segments) + 0.06
    ctx.setStrokeColor(lit ? CGColor(red: 1, green: 0.14, blue: 0.09, alpha: 1) : CGColor(red: 0.23, green: 0.05, blue: 0.04, alpha: 1))
    ctx.setLineWidth(52)
    if lit { ctx.setShadow(offset: .zero, blur: 22, color: CGColor(red: 1, green: 0.14, blue: 0.09, alpha: 0.9)) } else { ctx.setShadow(offset: .zero, blur: 0, color: nil) }
    ctx.addArc(center: center, radius: 300, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
}
ctx.setShadow(offset: .zero, blur: 40, color: CGColor(red: 0.12, green: 0.84, blue: 0.35, alpha: 0.8))
ctx.setFillColor(CGColor(red: 0.12, green: 0.84, blue: 0.35, alpha: 1))
ctx.fillEllipse(in: CGRect(x: center.x - 205, y: center.y - 205, width: 410, height: 410))
ctx.setShadow(offset: .zero, blur: 0, color: nil)
ctx.setFillColor(CGColor(red: 0.02, green: 0.15, blue: 0.06, alpha: 1))
ctx.move(to: CGPoint(x: center.x - 62, y: center.y + 100))
ctx.addLine(to: CGPoint(x: center.x + 108, y: center.y))
ctx.addLine(to: CGPoint(x: center.x - 62, y: center.y - 100))
ctx.closePath()
ctx.fillPath()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
