import AppKit

// Renders Resources/AppIcon.icns: the wheel itself, on a dark tile.
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let tile = NSRect(x: 64, y: 64, width: size - 128, height: size - 128)
let background = NSBezierPath(roundedRect: tile, xRadius: 190, yRadius: 190)
NSGradient(colors: [
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.14, alpha: 1),
    NSColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 1)
])?.draw(in: background, angle: -90)

let center = NSPoint(x: size / 2, y: size / 2)
let outer: CGFloat = 318
let inner: CGFloat = 148
let per = 2 * Double.pi / 8
let start = Double.pi / 2 - per / 2
let gap = 0.035

for index in 0..<8 {
    let from = start + Double(index) * per + gap
    let to = start + Double(index + 1) * per - gap
    let path = NSBezierPath()
    path.appendArc(withCenter: center, radius: outer,
                   startAngle: from * 180 / .pi, endAngle: to * 180 / .pi)
    path.appendArc(withCenter: center, radius: inner,
                   startAngle: to * 180 / .pi, endAngle: from * 180 / .pi, clockwise: true)
    path.close()
    let color = index == 0
        ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        : NSColor(srgbRed: 1.0, green: 0.47, blue: 0.10, alpha: 1)
    color.setFill()
    path.fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    print("icon: render failed")
    exit(1)
}

let base = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = base.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let master = base.appendingPathComponent("AppIcon-1024.png")
try png.write(to: master)

for size in [16, 32, 128, 256, 512] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task.arguments = ["-z", "\(size)", "\(size)", master.path,
                      "--out", iconset.appendingPathComponent("icon_\(size)x\(size).png").path]
    try? task.run()
    task.waitUntilExit()

    let double = size * 2
    let task2 = Process()
    task2.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
    task2.arguments = ["-z", "\(double)", "\(double)", master.path,
                       "--out", iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png").path]
    try? task2.run()
    task2.waitUntilExit()
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", base.appendingPathComponent("AppIcon.icns").path]
try? convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
try? FileManager.default.removeItem(at: master)
print("icon: wrote AppIcon.icns")
