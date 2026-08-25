//  RSSPhotoSource.swift
//  RSS／Atom 相片來源。完全免驗證。
//
//  相片可能出現在三個地方，依序找：media:content、enclosure、description 裡的 <img src>。

import Foundation

public struct RSSPhotoSource: RemotePhotoSource {
    public let kind = RemoteSourceKind.rss
    let feed: URL

    public init(feed: String) throws {
        let trimmed = feed.trimmingCharacters(in: .whitespaces)
        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized), url.host?.isEmpty == false else {
            throw RemoteSourceError.badEndpoint(feed)
        }
        self.feed = url
    }

    public func listRequest(limit: Int) throws -> URLRequest {
        _ = limit   // feed 給多少就是多少，下載端自行取用
        var request = URLRequest(url: feed)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml",
                         forHTTPHeaderField: "Accept")
        return request
    }

    public func parse(_ data: Data) throws -> [RemoteImage] {
        try RSSImageExtractor.images(from: data, kind: kind, attribution: feed.host)
    }
}

/// RSS／Atom 的抓圖邏輯。RSSHub 產的也是一般 RSS，兩個來源共用同一套解析。
public enum RSSImageExtractor {

    public static func images(
        from data: Data, kind: RemoteSourceKind, attribution: String?
    ) throws -> [RemoteImage] {
        let parser = XMLParser(data: data)
        let collector = ImageCollector()
        parser.delegate = collector
        guard parser.parse() else { throw RemoteSourceError.malformedResponse(kind) }

        var seen = Set<String>()
        return collector.urls.compactMap { string in
            guard !seen.contains(string), let url = URL(string: string), url.host != nil
            else { return nil }
            seen.insert(string)
            return RemoteImage(id: string, url: url, attribution: attribution)
        }
    }
}

/// XMLParser 的 delegate 必須是 class；只在 parse 期間存活，不跨執行緒共用。
private final class ImageCollector: NSObject, XMLParserDelegate {

    private(set) var urls: [String] = []
    private var textBuffer = ""
    private var isInDescription = false

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "avif",
    ]

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        let name = Self.localName(elementName)

        switch name {
        case "content", "thumbnail":
            // media:content / media:thumbnail
            if let url = attributes["url"], isImage(url, type: attributes["type"]) {
                urls.append(url)
            }
        case "enclosure":
            if let url = attributes["url"], isImage(url, type: attributes["type"]) {
                urls.append(url)
            }
        case "description", "encoded", "summary":
            isInDescription = true
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInDescription { textBuffer += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if isInDescription, let text = String(data: CDATABlock, encoding: .utf8) {
            textBuffer += text
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        let name = Self.localName(elementName)
        guard name == "description" || name == "encoded" || name == "summary" else { return }
        isInDescription = false
        urls.append(contentsOf: Self.imageSources(inHTML: textBuffer))
        textBuffer = ""
    }

    /// XMLParser 預設不處理命名空間，元素名會是 `media:content` 這種完整名稱。
    /// 統一剝掉前綴再比對，才同時吃得下 media:content 與 content:encoded。
    static func localName(_ elementName: String) -> String {
        (elementName.split(separator: ":").last.map(String.init) ?? elementName).lowercased()
    }

    private func isImage(_ url: String, type: String?) -> Bool {
        if let type, type.hasPrefix("image/") { return true }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return Self.imageExtensions.contains(ext)
    }

    /// 從 description 的 HTML 抓 <img src="...">。用不著整套 HTML parser。
    static func imageSources(inHTML html: String) -> [String] {
        guard !html.isEmpty else { return [] }
        let pattern = #"<img[^>]+src\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return [] }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard let captured = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[captured])
        }
    }
}
