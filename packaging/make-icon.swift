#!/usr/bin/env swift
//
//  make-icon.swift
//  產生 App icon：三張疊放的相片卡，對應 app 實際輸出的蒙太奇。
//  重跑即可改圖，不需要外部設計檔。
//
//  用法：swift packaging/make-icon.swift <輸出目錄>
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - 繪圖

/// Apple 的連續圓角比例（squircle 近似），相對於圓角方塊本身的邊長。
let cornerRatio: CGFloat = 0.2237
/// macOS 圖示網格：本體佔畫布 824/1024，四周留白給陰影。
/// 不照這個比例，圖示在 Dock 裡會比其他 app 大一號。
let plateInsetRatio: CGFloat = (1024 - 824) / 2 / 1024

func drawIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let bounds = CGRect(x: 0, y: 0, width: size, height: size)

    // 底：連續圓角 + 由深藍到暖橘的斜向漸層（照片牆的「牆」）
    let plateRect = bounds.insetBy(dx: size * plateInsetRatio, dy: size * plateInsetRatio)
    let plate = CGPath(
        roundedRect: plateRect,
        cornerWidth: plateRect.width * cornerRatio,
        cornerHeight: plateRect.width * cornerRatio,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.16, green: 0.18, blue: 0.32, alpha: 1),
            CGColor(red: 0.36, green: 0.24, blue: 0.42, alpha: 1),
            CGColor(red: 0.86, green: 0.52, blue: 0.34, alpha: 1),
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: plateRect.minX, y: plateRect.maxY),
        end: CGPoint(x: plateRect.maxX, y: plateRect.minY),
        options: []
    )

    // 三張相片卡：與 MontageComposer 一樣的白邊＋陰影＋輕微旋轉
    struct Card {
        let center: CGPoint
        let size: CGSize
        let angle: CGFloat
        let colors: [CGColor]
    }

    // 相對於圓角方塊定位，不是畫布：卡片才不會被圓角切掉一角
    let unit = plateRect.width
    func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
        CGPoint(x: plateRect.minX + plateRect.width * fx,
                y: plateRect.minY + plateRect.height * fy)
    }
    let cards: [Card] = [
        Card(center: at(0.37, 0.63),
             size: CGSize(width: unit * 0.30, height: unit * 0.23),
             angle: -9,
             colors: [CGColor(red: 0.20, green: 0.55, blue: 0.62, alpha: 1),
                      CGColor(red: 0.44, green: 0.78, blue: 0.72, alpha: 1)]),
        Card(center: at(0.62, 0.57),
             size: CGSize(width: unit * 0.28, height: unit * 0.35),
             angle: 7,
             colors: [CGColor(red: 0.90, green: 0.72, blue: 0.34, alpha: 1),
                      CGColor(red: 0.94, green: 0.86, blue: 0.60, alpha: 1)]),
        Card(center: at(0.47, 0.37),
             size: CGSize(width: unit * 0.35, height: unit * 0.26),
             angle: -3,
             colors: [CGColor(red: 0.78, green: 0.32, blue: 0.36, alpha: 1),
                      CGColor(red: 0.92, green: 0.55, blue: 0.42, alpha: 1)]),
    ]

    for card in cards {
        let border = card.size.height * 0.075
        let frame = CGRect(x: -card.size.width / 2, y: -card.size.height / 2,
                           width: card.size.width, height: card.size.height)
        let paper = frame.insetBy(dx: -border, dy: -border)

        ctx.saveGState()
        ctx.translateBy(x: card.center.x, y: card.center.y)
        ctx.rotate(by: card.angle * .pi / 180)

        // 相紙白邊
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -border * 0.9),
                      blur: border * 2.6,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.42))
        ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.97, alpha: 1))
        ctx.fill(paper)
        ctx.restoreGState()

        // 卡面漸層
        ctx.saveGState()
        ctx.clip(to: frame)
        let cardGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: card.colors as CFArray, locations: [0, 1]
        )!
        ctx.drawLinearGradient(
            cardGradient,
            start: CGPoint(x: frame.minX, y: frame.maxY),
            end: CGPoint(x: frame.maxX, y: frame.minY),
            options: []
        )
        ctx.restoreGState()

        ctx.restoreGState()
    }

    ctx.restoreGState()

    // 上緣高光，讓圖示在深色 Dock 上有立體感
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let sheen = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
                 CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: 0, y: plateRect.maxY),
                           end: CGPoint(x: 0, y: plateRect.minY + plateRect.height * 0.55),
                           options: [])
    ctx.restoreGState()

    return ctx.makeImage()!
}

// MARK: - 輸出

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url)
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("用法：swift make-icon.swift <輸出目錄>\n".utf8))
    exit(1)
}
let outDir = URL(filePath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// macOS appiconset 需要的 (尺寸, 檔名) 組合
let variants: [(px: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

// 一律從 1024 下採樣，小尺寸才不會因為直接繪製而糊掉
let master = drawIcon(size: 1024)
for variant in variants {
    let image: CGImage
    if variant.px == 1024 {
        image = master
    } else {
        let ctx = CGContext(
            data: nil, width: variant.px, height: variant.px, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(master, in: CGRect(x: 0, y: 0, width: variant.px, height: variant.px))
        image = ctx.makeImage()!
    }
    try writePNG(image, to: outDir.appending(path: "\(variant.name).png"))
}

print("已產生 \(variants.count) 個尺寸於 \(outDir.path)")
