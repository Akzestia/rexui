// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
import AppKit

let a = CommandLine.arguments
guard a.count >= 4, let img = NSImage(contentsOfFile: a[1]), let W = Int(a[3]) else { exit(1) }
let H = Int((Double(W) * Double(img.size.height) / Double(img.size.width)).rounded())
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
