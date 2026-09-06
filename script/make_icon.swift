import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
let folder = root.appendingPathComponent("Guitarget.iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16,32,128,256,512] {
    for scale in [1,2] {
        let size = base * scale
        let image = NSImage(size:NSSize(width:size,height:size))
        image.lockFocus()
        let bounds = NSRect(x:Double(size)*0.08,y:Double(size)*0.08,width:Double(size)*0.84,height:Double(size)*0.84)
        NSColor(calibratedRed:0.12,green:0.17,blue:0.19,alpha:1).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:Double(size)*0.20,yRadius:Double(size)*0.20).fill()
        if let glyph = NSImage(systemSymbolName:"guitars.fill",accessibilityDescription:nil) {
            let config = NSImage.SymbolConfiguration(pointSize:Double(size)*0.54,weight:.regular)
                .applying(NSImage.SymbolConfiguration(paletteColors:[NSColor.systemOrange]))
            glyph.withSymbolConfiguration(config)?.draw(in:NSRect(x:Double(size)*0.20,y:Double(size)*0.20,width:Double(size)*0.60,height:Double(size)*0.60))
        }
        image.unlockFocus()
        let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
        try rep.representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("icon_\(base)x\(base)\(scale == 2 ? "@2x":"").png"))
    }
}
