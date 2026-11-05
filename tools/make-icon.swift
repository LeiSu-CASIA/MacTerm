import AppKit

let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
func color(_ value:UInt32,_ alpha:CGFloat=1)->NSColor {NSColor(calibratedRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:alpha)}
for size in [16,32,64,128,256,512,1024] {
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 let transform=NSAffineTransform();transform.scale(by:CGFloat(size)/1024);transform.concat()
 let tile=NSBezierPath(roundedRect:NSRect(x:96,y:96,width:832,height:832),xRadius:188,yRadius:188)
 NSGraphicsContext.saveGraphicsState();let shadow=NSShadow();shadow.shadowColor=color(0x02060C,0.35);shadow.shadowBlurRadius=25;shadow.shadowOffset=NSSize(width:0,height:-12);shadow.set();color(0x162131).setFill();tile.fill();NSGraphicsContext.restoreGraphicsState()
 NSGradient(starting:color(0x2B3D55),ending:color(0x101721))!.draw(in:tile,angle:-90)
 NSGraphicsContext.saveGraphicsState();tile.addClip()
 NSGradient(starting:color(0x637F9C,0.22),ending:color(0x182231,0))!.draw(in:NSRect(x:96,y:530,width:832,height:398),angle:-90)
 let divider=NSBezierPath();divider.move(to:NSPoint(x:96,y:710));divider.line(to:NSPoint(x:928,y:710));divider.lineWidth=2;color(0x9DB7D0,0.17).setStroke();divider.stroke();NSGraphicsContext.restoreGraphicsState()
 tile.lineWidth=2;color(0xBDDAEE,0.22).setStroke();tile.stroke()
 for (x,shade) in [(CGFloat(224),UInt32(0x91A6BA)),(CGFloat(282),UInt32(0x6F899F)),(CGFloat(340),UInt32(0x4C6C83))] {color(shade).setFill();NSBezierPath(ovalIn:NSRect(x:x-13,y:786-13,width:26,height:26)).fill()}
 let arrow=NSBezierPath();arrow.move(to:NSPoint(x:264,y:582));arrow.line(to:NSPoint(x:423,y:449));arrow.line(to:NSPoint(x:264,y:316));arrow.lineWidth=70;arrow.lineCapStyle = .round;arrow.lineJoinStyle = .round
 NSGraphicsContext.saveGraphicsState();let glow=NSShadow();glow.shadowColor=color(0x65E2C9,0.16);glow.shadowBlurRadius=14;glow.shadowOffset = .zero;glow.set();color(0x79E6CE).setStroke();arrow.stroke();NSGraphicsContext.restoreGraphicsState()
 let cursor=NSBezierPath();cursor.move(to:NSPoint(x:523,y:316));cursor.line(to:NSPoint(x:716,y:316));cursor.lineWidth=66;cursor.lineCapStyle = .round;color(0xE9F2FA).setStroke();cursor.stroke()
 NSGraphicsContext.restoreGraphicsState()
 let data=rep.representation(using:.png,properties:[:])!
 let names:[String];switch size {case 16:names=["icon_16x16.png"];case 32:names=["icon_16x16@2x.png","icon_32x32.png"];case 64:names=["icon_32x32@2x.png"];case 128:names=["icon_128x128.png"];case 256:names=["icon_128x128@2x.png","icon_256x256.png"];case 512:names=["icon_256x256@2x.png","icon_512x512.png"];default:names=["icon_512x512@2x.png"]}
 for name in names {try data.write(to:root.appendingPathComponent(name))}
}
