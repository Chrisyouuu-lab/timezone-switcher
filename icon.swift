import AppKit

let size = CGFloat(1024)
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
NSGradient(starting: NSColor(red: 0.13, green: 0.47, blue: 0.85, alpha: 1),
           ending: NSColor(red: 0.05, green: 0.20, blue: 0.48, alpha: 1))!.draw(in: tile, angle: -90)
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .regular)
    .applying(.init(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "globe.americas.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
