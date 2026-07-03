#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/AppIcon-1024.png")
let size = CGSize(width: 1024, height: 1024)

final class IconView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 56, dy: 56), xRadius: 214, yRadius: 214)
        outer.addClip()

        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.16, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.09, green: 0.20, blue: 0.24, alpha: 1).cgColor,
                NSColor(calibratedRed: 0.11, green: 0.36, blue: 0.34, alpha: 1).cgColor,
            ] as CFArray,
            locations: [0.0, 0.55, 1.0]
        )!
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY),
            options: []
        )

        NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
        outer.lineWidth = 3
        outer.stroke()

        drawBridge(in: rect)
        drawCodeMarks(in: rect)
    }

    private func drawBridge(in rect: CGRect) {
        let teal = NSColor(calibratedRed: 0.23, green: 0.86, blue: 0.76, alpha: 1)
        let blue = NSColor(calibratedRed: 0.30, green: 0.58, blue: 1.00, alpha: 1)
        let pale = NSColor(calibratedRed: 0.84, green: 0.98, blue: 0.94, alpha: 1)

        let arch = NSBezierPath()
        arch.move(to: CGPoint(x: 245, y: 624))
        arch.curve(to: CGPoint(x: 779, y: 624), controlPoint1: CGPoint(x: 352, y: 380), controlPoint2: CGPoint(x: 672, y: 380))
        arch.lineWidth = 56
        arch.lineCapStyle = .round
        teal.setStroke()
        arch.stroke()

        let inner = NSBezierPath()
        inner.move(to: CGPoint(x: 310, y: 628))
        inner.curve(to: CGPoint(x: 714, y: 628), controlPoint1: CGPoint(x: 392, y: 470), controlPoint2: CGPoint(x: 632, y: 470))
        inner.lineWidth = 18
        inner.lineCapStyle = .round
        NSColor(calibratedWhite: 1, alpha: 0.24).setStroke()
        inner.stroke()

        let deck = NSBezierPath()
        deck.move(to: CGPoint(x: 228, y: 642))
        deck.line(to: CGPoint(x: 796, y: 642))
        deck.lineWidth = 42
        deck.lineCapStyle = .round
        blue.setStroke()
        deck.stroke()

        for x in [330, 420, 512, 604, 694] as [CGFloat] {
            let strut = NSBezierPath()
            strut.move(to: CGPoint(x: x, y: 610))
            strut.line(to: CGPoint(x: x, y: 700))
            strut.lineWidth = 20
            strut.lineCapStyle = .round
            pale.withAlphaComponent(0.82).setStroke()
            strut.stroke()
        }

        let leftNode = NSBezierPath(ovalIn: CGRect(x: 184, y: 580, width: 100, height: 100))
        let rightNode = NSBezierPath(ovalIn: CGRect(x: 740, y: 580, width: 100, height: 100))
        pale.setFill()
        leftNode.fill()
        rightNode.fill()
        teal.withAlphaComponent(0.35).setStroke()
        leftNode.lineWidth = 10
        rightNode.lineWidth = 10
        leftNode.stroke()
        rightNode.stroke()
    }

    private func drawCodeMarks(in rect: CGRect) {
        let markColor = NSColor(calibratedRed: 0.88, green: 1.0, blue: 0.96, alpha: 0.92)
        markColor.setStroke()

        let left = NSBezierPath()
        left.move(to: CGPoint(x: 374, y: 360))
        left.line(to: CGPoint(x: 302, y: 432))
        left.line(to: CGPoint(x: 374, y: 504))
        left.lineWidth = 34
        left.lineCapStyle = .round
        left.lineJoinStyle = .round
        left.stroke()

        let right = NSBezierPath()
        right.move(to: CGPoint(x: 650, y: 360))
        right.line(to: CGPoint(x: 722, y: 432))
        right.line(to: CGPoint(x: 650, y: 504))
        right.lineWidth = 34
        right.lineCapStyle = .round
        right.lineJoinStyle = .round
        right.stroke()

        let slash = NSBezierPath()
        slash.move(to: CGPoint(x: 560, y: 342))
        slash.line(to: CGPoint(x: 464, y: 522))
        slash.lineWidth = 28
        slash.lineCapStyle = .round
        NSColor(calibratedRed: 0.33, green: 0.90, blue: 1.0, alpha: 0.78).setStroke()
        slash.stroke()
    }
}

let image = NSImage(size: size)
image.lockFocus()
IconView(frame: CGRect(origin: .zero, size: size)).draw(CGRect(origin: .zero, size: size))
image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to render icon\n", stderr)
    exit(1)
}

try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: output)
print(output.path)
