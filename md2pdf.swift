// md2pdf.swift — Markdown → PDF конвертер для macOS без внешних зависимостей.
// Использует только системные фреймворки (Foundation, AppKit, WebKit).
//
// Сборка (нужны Xcode Command Line Tools):
//   ./build.sh
// build.sh вшивает github-style.css в исходник (раздел embeddedGithubCSS) и
// компилирует, поэтому стили зашиты прямо в бинарник — отдельный .css носить
// с собой не нужно.
//
// Использование:
//   ./md2pdf input.md                          → input.pdf рядом с исходником
//   ./md2pdf input.md -o report.pdf
//   ./md2pdf input.md --theme minimal          → встроенная минимальная тема
//   ./md2pdf input.md --css style.css          → свои стили (обычный CSS)
//   ./md2pdf input.md --paper Letter --margin 15
//
// Темы зашиты в бинарник: github (по умолчанию) и minimal. --css перебивает
// тему и подключает произвольный CSS-файл.

import Foundation
import AppKit
import WebKit

// MARK: - Аргументы

struct Options {
    var input: String = ""
    var output: String = ""
    var cssPath: String? = nil
    var theme: String = "github"  // github | minimal (встроенные темы)
    var paper: String = "A4"      // A4 | Letter
    var marginMM: Double = 20
}

func parseArgs() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    var positional: [String] = []
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-o", "--output":
            if !args.isEmpty { o.output = args.removeFirst() }
        case "--css":
            if !args.isEmpty { o.cssPath = args.removeFirst() }
        case "--theme":
            if !args.isEmpty { o.theme = args.removeFirst() }
        case "--paper":
            if !args.isEmpty { o.paper = args.removeFirst() }
        case "--margin":
            if !args.isEmpty { o.marginMM = Double(args.removeFirst()) ?? 20 }
        case "-h", "--help":
            print("""
            md2pdf <input.md> [-o output.pdf] [--theme github|minimal] [--css style.css] [--paper A4|Letter] [--margin mm]
            """)
            exit(0)
        default:
            positional.append(a)
        }
    }
    guard let input = positional.first else {
        FileHandle.standardError.write("Ошибка: укажите входной .md файл. См. --help\n".data(using: .utf8)!)
        exit(1)
    }
    o.input = input
    if o.output.isEmpty {
        o.output = (input as NSString).deletingPathExtension + ".pdf"
    }
    return o
}

// MARK: - Regex helper

func regexReplace(_ input: String, _ pattern: String,
                  options: NSRegularExpression.Options = [],
                  _ transform: ([String]) -> String) -> String {
    guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return input }
    let ns = input as NSString
    var result = ""
    var last = 0
    re.enumerateMatches(in: input, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
        guard let m = m else { return }
        result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        var groups: [String] = []
        for i in 0..<m.numberOfRanges {
            let r = m.range(at: i)
            groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        result += transform(groups)
        last = m.range.location + m.range.length
    }
    result += ns.substring(from: last)
    return result
}

// MARK: - Markdown → HTML (компактный парсер: заголовки, списки, код, цитаты, таблицы, ссылки, картинки)

func escapeHTML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
}

func inlineMD(_ raw: String) -> String {
    var s = escapeHTML(raw)
    // Защищаем inline-код от дальнейших замен
    var codes: [String] = []
    s = regexReplace(s, "`([^`]+)`") { g in
        codes.append(g[1]); return "\u{1}\(codes.count - 1)\u{1}"
    }
    s = regexReplace(s, "!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)") { g in
        "<img src=\"\(g[2])\" alt=\"\(g[1])\">"
    }
    s = regexReplace(s, "\\[([^\\]]+)\\]\\(([^)\\s]+)\\)") { g in
        "<a href=\"\(g[2])\">\(g[1])</a>"
    }
    // Жирный/курсив/зачёркивание: парные маркеры. Защита (?![\s…])/(?<![\s…])
    // и (?<!…)/(?!…) не даёт «голому» прогону маркеров (---, ____, ~~~~,
    // строка-прочерк для подписи) превратиться в кривую разметку.
    s = regexReplace(s, "(?<!\\*)\\*\\*(?![\\s*])(.+?)(?<![\\s*])\\*\\*(?!\\*)") { "<strong>\($0[1])</strong>" }
    s = regexReplace(s, "(?<!\\w)__(?![\\s_])(.+?)(?<![\\s_])__(?!\\w)")         { "<strong>\($0[1])</strong>" }
    s = regexReplace(s, "(?<![\\w*])\\*([^*\\n]+)\\*(?![\\w*])") { "<em>\($0[1])</em>" }
    s = regexReplace(s, "(?<![\\w_])_([^_\\n]+)_(?![\\w_])")     { "<em>\($0[1])</em>" }
    s = regexReplace(s, "(?<!~)~~(?![\\s~])(.+?)(?<![\\s~])~~(?!~)") { "<del>\($0[1])</del>" }
    for (i, c) in codes.enumerated() {
        s = s.replacingOccurrences(of: "\u{1}\(i)\u{1}", with: "<code>\(c)</code>")
    }
    return s
}

func markdownToHTML(_ md: String) -> String {
    var html = ""
    let lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var i = 0
    var listStack: [String] = []   // "ul" / "ol"

    func closeLists() {
        while let t = listStack.popLast() { html += "</\(t)>\n" }
    }

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Пустая строка
        if trimmed.isEmpty { closeLists(); i += 1; continue }

        // Блок кода ```
        if trimmed.hasPrefix("```") {
            closeLists()
            let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
            var code = ""
            i += 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code += escapeHTML(lines[i]) + "\n"
                i += 1
            }
            i += 1
            let cls = lang.isEmpty ? "" : " class=\"language-\(lang)\""
            html += "<pre><code\(cls)>\(code)</code></pre>\n"
            continue
        }

        // Заголовки
        if let m = trimmed.range(of: "^#{1,6} ", options: .regularExpression) {
            closeLists()
            let level = trimmed.distance(from: trimmed.startIndex, to: m.upperBound) - 1
            let text = String(trimmed[m.upperBound...])
            html += "<h\(level)>\(inlineMD(text))</h\(level)>\n"
            i += 1; continue
        }

        // Горизонтальная линия
        if trimmed.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
            closeLists(); html += "<hr>\n"; i += 1; continue
        }

        // Цитата
        if trimmed.hasPrefix(">") {
            closeLists()
            var quote = ""
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                quote += inlineMD(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)) + "<br>"
                i += 1
            }
            html += "<blockquote><p>\(quote)</p></blockquote>\n"
            continue
        }

        // Таблица (строка с | и следующая строка-разделитель)
        if trimmed.contains("|"), i + 1 < lines.count,
           lines[i+1].trimmingCharacters(in: .whitespaces)
               .range(of: "^\\|?[\\s:|-]+\\|?$", options: .regularExpression) != nil,
           lines[i+1].contains("-") {
            closeLists()
            func cells(_ s: String) -> [String] {
                var t = s.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("|") { t.removeFirst() }
                if t.hasSuffix("|") { t.removeLast() }
                return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            html += "<table>\n<thead><tr>"
            for c in cells(trimmed) { html += "<th>\(inlineMD(c))</th>" }
            html += "</tr></thead>\n<tbody>\n"
            i += 2
            while i < lines.count, lines[i].contains("|"),
                  !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                html += "<tr>"
                for c in cells(lines[i]) { html += "<td>\(inlineMD(c))</td>" }
                html += "</tr>\n"
                i += 1
            }
            html += "</tbody>\n</table>\n"
            continue
        }

        // Списки (маркированные и нумерованные)
        if let m = trimmed.range(of: "^([-*+]|\\d+\\.) ", options: .regularExpression) {
            let marker = String(trimmed[m]).trimmingCharacters(in: .whitespaces)
            let type = (marker == "-" || marker == "*" || marker == "+") ? "ul" : "ol"
            if listStack.last != type {
                closeLists()
                listStack.append(type)
                html += "<\(type)>\n"
            }
            let text = String(trimmed[m.upperBound...])
            html += "<li>\(inlineMD(text))</li>\n"
            i += 1; continue
        }

        // Параграф (склеиваем последовательные строки)
        closeLists()
        var para = inlineMD(trimmed)
        i += 1
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("```")
                || t.range(of: "^([-*+]|\\d+\\.) ", options: .regularExpression) != nil { break }
            para += " " + inlineMD(t)
            i += 1
        }
        html += "<p>\(para)</p>\n"
    }
    closeLists()
    return html
}

// MARK: - CSS по умолчанию (переопределяется через --css)

let defaultCSS = """
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif;
       font-size: 11pt; line-height: 1.55; color: #1a1a1a; }
h1 { font-size: 22pt; border-bottom: 2px solid #444; padding-bottom: 4pt; }
h2 { font-size: 16pt; margin-top: 1.4em; }
h3 { font-size: 13pt; }
code { font-family: 'SF Mono', Menlo, monospace; font-size: 9.5pt;
       background: #f2f2f2; padding: 1px 4px; border-radius: 3px; }
pre  { background: #f6f6f6; border: 1px solid #ddd; border-radius: 6px;
       padding: 10px; overflow-x: auto; }
pre code { background: none; padding: 0; }
blockquote { border-left: 3px solid #bbb; margin-left: 0;
             padding-left: 12px; color: #555; }
table { border-collapse: collapse; width: 100%; margin: 1em 0; }
th, td { border: 1px solid #ccc; padding: 5px 9px; text-align: left; }
th { background: #efefef; }
img { max-width: 100%; }
a { color: #0a58c2; text-decoration: none; }
hr { border: none; border-top: 1px solid #ccc; margin: 1.5em 0; }
"""

// MARK: - Рендеринг в PDF через WebKit + NSPrintOperation (с разбивкой на страницы)

final class Renderer: NSObject, WKNavigationDelegate {
    let opts: Options
    var webView: WKWebView!

    init(opts: Options) { self.opts = opts }

    func run() {
        guard let md = try? String(contentsOfFile: opts.input, encoding: .utf8) else {
            FileHandle.standardError.write("Не удалось прочитать \(opts.input)\n".data(using: .utf8)!)
            exit(1)
        }
        let css: String
        if let path = opts.cssPath {
            guard let custom = try? String(contentsOfFile: path, encoding: .utf8) else {
                FileHandle.standardError.write("Не удалось прочитать CSS \(path)\n".data(using: .utf8)!)
                exit(1)
            }
            css = custom
        } else if opts.theme.lowercased() == "minimal" {
            css = defaultCSS
        } else {
            css = embeddedGithubCSS   // тема по умолчанию, вшита в бинарник (см. build.sh)
        }
        let body = markdownToHTML(md)
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>\(css)</style></head><body><div class="markdown-body">\(body)</div></body></html>
        """

        let paperSize: NSSize = opts.paper.lowercased() == "letter"
            ? NSSize(width: 612, height: 792)
            : NSSize(width: 595, height: 842)   // A4 в пунктах

        let config = WKWebViewConfiguration()
        if #available(macOS 13.3, *) {
            config.preferences.shouldPrintBackgrounds = true   // печатать фоны (код, шапки таблиц)
        }
        webView = WKWebView(frame: NSRect(origin: .zero,
                                          size: NSSize(width: paperSize.width, height: paperSize.height)),
                            configuration: config)
        webView.navigationDelegate = self
        let baseURL = URL(fileURLWithPath: (opts.input as NSString).deletingLastPathComponent,
                          isDirectory: true)
        webView.loadHTMLString(html, baseURL: baseURL) // baseURL — чтобы работали относительные картинки
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // небольшая пауза, чтобы успели загрузиться картинки/шрифты
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.printPDF() }
    }

    func printPDF() {
        let pt = opts.marginMM * 72.0 / 25.4
        let info = NSPrintInfo()
        info.paperSize = opts.paper.lowercased() == "letter"
            ? NSSize(width: 612, height: 792) : NSSize(width: 595, height: 842)
        info.topMargin = pt; info.bottomMargin = pt
        info.leftMargin = pt; info.rightMargin = pt
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] =
            URL(fileURLWithPath: opts.output)

        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        op.runModal(for: NSWindow(), delegate: self,
                    didRun: #selector(printDone(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if success {
            print("OK: \(opts.output)")
            exit(0)
        } else {
            FileHandle.standardError.write("Ошибка при сохранении PDF\n".data(using: .utf8)!)
            exit(1)
        }
    }
}

// MARK: - main

let opts = parseArgs()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // без иконки в доке
let renderer = Renderer(opts: opts)
DispatchQueue.main.async { renderer.run() }
app.run()
