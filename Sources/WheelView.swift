import AppKit

/// The wheel: a ring of targets around the cursor, plus the three mode pills
/// that say which modifier is showing.
final class WheelView: NSView {
    struct Style {
        static let accent = NSColor(srgbRed: 1.0, green: 0.47, blue: 0.10, alpha: 1.0)
        static let paper = NSColor.white
        static let dim = NSColor(srgbRed: 0.70, green: 0.70, blue: 0.75, alpha: 1.0)
        static let segment = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
        static let segmentStroke = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.09)
        static let plate = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.86)
        static let plateEdge = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07)
        static var scale: CGFloat { Settings.shared.scale.value }
        static var outer: CGFloat { 168 * scale }
        static var inner: CGFloat { 88 * scale }
    }

    var items: [WheelItem] = [] {
        didSet { needsDisplay = true }
    }
    var selectedIndex: Int = 0 {
        didSet { needsDisplay = true }
    }
    var mode: WheelMode = .convert {
        didSet { needsDisplay = true }
    }
    var title: String = "" {
        didSet { needsDisplay = true }
    }
    var subtitle: String = "" {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var outerRadius: CGFloat { Style.outer }
    private var innerRadius: CGFloat { Style.inner }

    // MARK: - Geometry

    private var anglePerItem: CGFloat {
        guard !items.isEmpty else { return 0 }
        return (2 * .pi) / CGFloat(items.count)
    }

    /// Segment 0 sits at the top of the wheel.
    private var startAngle: CGFloat { .pi / 2 - anglePerItem / 2 }

    func index(at point: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let dx = point.x - center.x
        let dy = point.y - center.y
        let radius = hypot(dx, dy)
        guard radius >= innerRadius, radius <= outerRadius else { return nil }
        var relative = atan2(dy, dx) - startAngle
        let per = anglePerItem
        relative = relative.truncatingRemainder(dividingBy: 2 * .pi)
        if relative < 0 { relative += 2 * .pi }
        return min(items.count - 1, Int(relative / per))
    }

    func selectedItem() -> WheelItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setShouldAntialias(true)

        drawPlate()
        drawSegments()
        drawHub()
        drawModePills()
    }

    private func drawPlate() {
        let radius = outerRadius + 20
        let plate = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
        Style.plate.setFill()
        plate.fill()
        Style.plateEdge.setStroke()
        plate.lineWidth = 1
        plate.stroke()
    }

    private func drawSegments() {
        guard !items.isEmpty else { return }
        let per = anglePerItem
        let gap: CGFloat = items.count > 1 ? min(0.028, per * 0.09) : 0
        for (index, item) in items.enumerated() {
            let from = startAngle + CGFloat(index) * per + gap
            let to = startAngle + CGFloat(index + 1) * per - gap
            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: outerRadius,
                           startAngle: from * 180 / .pi, endAngle: to * 180 / .pi)
            path.appendArc(withCenter: center, radius: innerRadius,
                           startAngle: to * 180 / .pi, endAngle: from * 180 / .pi, clockwise: true)
            path.close()

            let selected = index == selectedIndex
            (selected ? Style.accent : Style.segment).setFill()
            path.fill()
            if !selected {
                Style.segmentStroke.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            let mid = startAngle + (CGFloat(index) + 0.5) * per
            let labelRadius = (innerRadius + outerRadius) / 2
            let anchor = NSPoint(
                x: center.x + cos(mid) * labelRadius,
                y: center.y + sin(mid) * labelRadius
            )
            drawItem(item, at: anchor, selected: selected)
        }
    }

    private func drawItem(_ item: WheelItem, at anchor: NSPoint, selected: Bool) {
        let tint = selected ? NSColor.white : Style.paper.withAlphaComponent(0.94)
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let size = image.size
            image.draw(in: NSRect(x: anchor.x - size.width / 2,
                                  y: anchor.y + 8,
                                  width: size.width,
                                  height: size.height))
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
            .foregroundColor: tint,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: item.title, attributes: attributes)
        text.draw(in: NSRect(x: anchor.x - 52, y: anchor.y - 16, width: 104, height: 16))
    }

    private func drawHub() {
        let radius = innerRadius - 12
        let hub = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                              width: radius * 2, height: radius * 2))
        NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 0.55).setFill()
        hub.fill()
        Style.plateEdge.setStroke()
        hub.lineWidth = 1
        hub.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle

        let titleText = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: Style.paper,
            .paragraphStyle: paragraph
        ])
        titleText.draw(in: NSRect(x: center.x - radius + 10, y: center.y + 3,
                                  width: radius * 2 - 20, height: 17))

        let subtitleText = NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: Style.dim,
            .paragraphStyle: paragraph
        ])
        subtitleText.draw(in: NSRect(x: center.x - radius + 10, y: center.y - 15,
                                     width: radius * 2 - 20, height: 14))
    }

    private func drawModePills() {
        let pills = WheelMode.allCases.map { ($0, $0.modifierHint) }
        var widths: [CGFloat] = []
        for (mode, _) in pills {
            widths.append(max(84, CGFloat(mode.title.count) * 6.8 + 48))
        }
        let spacing: CGFloat = 8
        let total = widths.reduce(0, +) + spacing * CGFloat(pills.count - 1)
        var x = center.x - total / 2
        let y = center.y + outerRadius + 30 * Style.scale

        for (index, (mode, hint)) in pills.enumerated() {
            let width = widths[index]
            let rect = NSRect(x: x, y: y, width: width, height: 27)
            let path = NSBezierPath(roundedRect: rect, xRadius: 13.5, yRadius: 13.5)
            let active = mode == self.mode
            (active ? Style.accent : NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.72)).setFill()
            path.fill()
            if !active {
                Style.plateEdge.setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let label = NSAttributedString(string: "\(hint)  \(mode.title)", attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .medium),
                .foregroundColor: active ? NSColor.white : Style.dim,
                .paragraphStyle: paragraph
            ])
            label.draw(in: NSRect(x: rect.minX, y: rect.minY + 7.5, width: rect.width, height: 14))
            x += width + spacing
        }
    }
}
