#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Вшиваем github-style.css прямо в исходник как Swift raw-string и компилируем
# одним файлом, чтобы стили попали в бинарник (отдельный .css носить не нужно).
#
# Глобал embeddedGithubCSS вставляем ПЕРЕД первым top-level выражением
# (`let opts = parseArgs()`): в main-файле Swift глобалы инициализируются по
# порядку исполнения, а app.run() в конце не возвращается (выход через exit()
# из колбэка). Если объявить глобал после app.run(), он не инициализируется и
# обращение к нему падает с EXC_BAD_ACCESS.
awk '
  /^let opts = parseArgs\(\)/ && !done {
    print "let embeddedGithubCSS = #\"\"\""
    while ((getline line < "github-style.css") > 0) print line
    print "\"\"\"#"
    print ""
    done = 1
  }
  { print }
' md2pdf.swift > md2pdf.combined.swift

swiftc -O md2pdf.combined.swift -o md2pdf
