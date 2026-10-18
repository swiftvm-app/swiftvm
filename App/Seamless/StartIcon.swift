import AppKit

extension NSImage {
    /// The app's Dock icon while a machine is in Seamless Mode, when clicking it opens the guest's Start
    /// menu: the Windows key's four panes, on a tile shaped like other Dock icons.
    static let startMenu = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
        // Apple's icon grid: an 824 point tile in the middle of the canvas, leaving room for the shadow.
        let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        shadow.shadowBlurRadius = 20
        shadow.set()
        NSColor.white.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: .white, ending: NSColor(white: 0.9, alpha: 1))?.draw(in: shape, angle: -90)

        let pane: CGFloat = 212
        let gap: CGFloat = 20
        let origin = tile.midX - pane - gap / 2
        let panes = NSBezierPath()
        for row in 0..<2 {
            for column in 0..<2 {
                let x = origin + CGFloat(column) * (pane + gap)
                let y = origin + CGFloat(row) * (pane + gap)
                panes.append(NSBezierPath(rect: NSRect(x: x, y: y, width: pane, height: pane)))
            }
        }
        let light = NSColor(srgbRed: 0.31, green: 0.76, blue: 1, alpha: 1)
        let deep = NSColor(srgbRed: 0, green: 0.47, blue: 0.83, alpha: 1)
        NSGradient(starting: light, ending: deep)?.draw(in: panes, angle: -45)
        return true
    }
}
