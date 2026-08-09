// svg2png — SVG 轉 PNG，只用系統框架。NSImage 從 Big Sur 起原生支援 SVG，
// 所以不需要 librsvg / cairosvg / Inkscape 任何一個。
// build: xcrun swiftc -parse-as-library -O svg2png.swift -o svg2png
// usage: ./svg2png in.svg out.png 512
import AppKit

@main
struct Main {
    static func main() {
        let a = CommandLine.arguments
        guard a.count == 4, let px = Int(a[3]) else {
            FileHandle.standardError.write(Data("usage: svg2png <in.svg> <out.png> <pixels>\n".utf8))
            exit(2)
        }
        guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else {
            FileHandle.standardError.write(Data("讀不到 SVG: \(a[1])\n".utf8)); exit(1)
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { FileHandle.standardError.write(Data("建不出 bitmap\n".utf8)); exit(1) }
        rep.size = NSSize(width: px, height: px)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                 from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("PNG 編碼失敗\n".utf8)); exit(1)
        }
        do { try png.write(to: URL(fileURLWithPath: a[2])) }
        catch { FileHandle.standardError.write(Data("寫檔失敗: \(error)\n".utf8)); exit(1) }
    }
}
