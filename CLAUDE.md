# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`md2pdf` — a macOS-only CLI that converts Markdown to PDF using **only system frameworks** (Foundation, AppKit, WebKit). No package manager, no third-party dependencies. The entire program is one file: `md2pdf.swift` (~350 lines).

## Build & run

```bash
./build.sh                 # generates md2pdf.combined.swift, then swiftc -O → md2pdf
```

`build.sh` embeds `github-style.css` into the source (see below) and compiles, so the resulting `md2pdf` binary is self-contained — no `.css` file needs to ship with it. **Do not compile `md2pdf.swift` directly** (`swiftc md2pdf.swift`) — it references `embeddedGithubCSS`, which only exists after `build.sh` injects it; standalone compilation fails. Both `md2pdf` and the generated `md2pdf.combined.swift` are gitignored.

There is no test suite, linter, or CI. Verify changes by building and running against a sample `.md`:

```bash
./md2pdf input.md                         # → input.pdf next to the source (github theme)
./md2pdf input.md --theme minimal         # built-in minimal theme
./md2pdf input.md --css github-style.css  # custom CSS (plain CSS file) — overrides theme
./md2pdf input.md --paper Letter --margin 15
```

Flags: `-o/--output`, `--theme github|minimal`, `--css`, `--paper A4|Letter`, `--margin <mm>`, `-h/--help`. Two themes are baked into the binary: `github` (default, from `github-style.css`) and `minimal` (the small embedded `defaultCSS`). `--css` overrides the theme. Building needs Xcode Command Line Tools.

## Architecture

Pipeline (all in `md2pdf.swift`):

1. **`parseArgs()`** → `Options` struct. Default output is the input path with `.pdf` extension.
2. **`markdownToHTML(_:)`** — a hand-rolled, line-based Markdown parser (no library). Walks lines with an index `i`, maintaining a `listStack` to open/close `<ul>`/`<ol>`. Handles: fenced code ` ``` `, ATX headings, `---` rules, blockquotes, pipe tables (detected by a separator line on `i+1`), lists, and paragraphs (consecutive lines glued together).
3. **`inlineMD(_:)`** — inline formatting (bold/italic/strike/links/images/inline-code) via the `regexReplace` helper. Inline code spans are extracted first to placeholder sentinels (`\u{1}…\u{1}`) so later regex passes don't corrupt them, then restored at the end.
4. **`Renderer`** (`WKNavigationDelegate`) — wraps the HTML+CSS, loads it into an off-screen `WKWebView`, and on `didFinish` waits **0.4s** (deliberate delay to let images/fonts settle) before printing. `printPDF()` drives `NSPrintOperation` with an `NSPrintInfo` whose `jobDisposition = .save` and `jobSavingURL` set to the output path — this is what does pagination (`verticalPagination = .automatic`).

### Things that are non-obvious

- **Why it runs an NSApplication event loop.** `main` calls `app.run()` with activation policy `.prohibited` (no Dock icon). WebKit needs a live main run loop to load and render; the process exits via `exit(0)/exit(1)` from the `printDone` callback, not by falling off the end of `main`. Don't restructure this into straight-line synchronous code — it won't work.
- **CSS model.** Rendered body is wrapped in `<div class="markdown-body">`. `defaultCSS` (the `minimal` theme) targets bare tags; `github-style.css` targets `.markdown-body …`. `--margin` controls page margins via `NSPrintInfo`, **not** CSS padding. `shouldPrintBackgrounds = true` (macOS 13.3+) is required to print code-block and table-header backgrounds.
- **How styles get baked in (and a placement gotcha).** `github-style.css` stays the editable source of truth; `build.sh` injects it into a copy of the source as a Swift raw string (`let embeddedGithubCSS = #"""…"""#`) and compiles that combined file. The injection point matters: the global is placed **before** the first top-level statement (`let opts = parseArgs()`), not appended at the end. In a Swift main file, top-level globals initialize in execution order, and `app.run()` never returns (the process exits via `exit()` from `printDone`). A global declared after `app.run()` is never initialized, so reading it crashes with `EXC_BAD_ACCESS` in `getSharedUTF8Start`. If you add more embedded assets, follow the same rule. The `awk` anchor in `build.sh` keys on the literal `let opts = parseArgs()` line — keep that line intact.
- **Parser limitations are by design** (compact, dependency-free): no nested lists, single-level blockquotes, no setext headings, no reference links, no HTML passthrough. When extending Markdown support, add a case to the `while i < lines.count` loop in `markdownToHTML`, mirroring the existing block detection style.

## Conventions

- Source comments and user-facing strings (errors, `--help`) are in **Russian**. Match that when editing.
- Single-file design is intentional — keep additions in `md2pdf.swift` unless there's a strong reason to split.
