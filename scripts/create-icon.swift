import AppKit
import Foundation

let root = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: root).appendingPathComponent("assets/ActionFlow.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels,height: pixels))
        image.lockFocus()
        let bounds = NSRect(x:0,y:0,width:pixels,height:pixels)
        NSColor(red:0.12,green:0.31,blue:0.24,alpha:1).setFill()
        NSBezierPath(roundedRect:bounds.insetBy(dx:Double(pixels)*0.035,dy:Double(pixels)*0.035),xRadius:Double(pixels)*0.21,yRadius:Double(pixels)*0.21).fill()
        let p = NSBezierPath()
        p.lineWidth = Double(pixels) * 0.095
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        let s = Double(pixels)
        p.move(to:NSPoint(x:s*0.29,y:s*0.69))
        p.line(to:NSPoint(x:s*0.29,y:s*0.40))
        p.curve(to:NSPoint(x:s*0.47,y:s*0.24),controlPoint1:NSPoint(x:s*0.29,y:s*0.28),controlPoint2:NSPoint(x:s*0.37,y:s*0.24))
        p.line(to:NSPoint(x:s*0.66,y:s*0.24))
        p.curve(to:NSPoint(x:s*0.76,y:s*0.36),controlPoint1:NSPoint(x:s*0.74,y:s*0.24),controlPoint2:NSPoint(x:s*0.76,y:s*0.29))
        p.line(to:NSPoint(x:s*0.76,y:s*0.54))
        p.line(to:NSPoint(x:s*0.54,y:s*0.54))
        NSColor(red:0.87,green:0.97,blue:0.87,alpha:1).setStroke();p.stroke()
        let dot = NSRect(x:s*0.23,y:s*0.69,width:s*0.12,height:s*0.12)
        NSColor(red:0.61,green:0.87,blue:0.58,alpha:1).setFill();NSBezierPath(ovalIn:dot).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        let data = bitmap.representation(using:.png,properties:[:])!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try data.write(to:iconset.appendingPathComponent(name))
    }
}
