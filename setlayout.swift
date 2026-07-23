// setlayout — переключение источника ввода (раскладки) без сторонних зависимостей.
// Нужен, чтобы перед вводом пароля через `keystroke` гарантированно стояла
// латинская (ASCII) раскладка: под кириллицей keystroke уходит мусором в WebView.
//
// Использование:
//   setlayout               — печатает ID текущего источника ввода и выходит
//   setlayout ASCII         — переключается на первую включённую ASCII-раскладку,
//                             печатает ID ПРЕДЫДУЩЕГО источника (для восстановления)
//   setlayout <input-source-id>  — переключается на источник с этим ID,
//                                  печатает ID предыдущего
//
// Коды выхода: 0 ок, 1 источник не найден, 2 ошибка выбора.
// Печатает предыдущий ID в stdout всегда, даже при ошибке — чтобы вызвавший
// скрипт мог восстановить раскладку.

import Carbon
import Foundation

func idOf(_ src: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func boolProp(_ src: TISInputSource, _ key: CFString) -> Bool {
    guard let p = TISGetInputSourceProperty(src, key) else { return false }
    return Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue() == kCFBooleanTrue
}

func categoryOf(_ src: TISInputSource) -> String? {
    guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) else { return nil }
    return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
}

func currentSource() -> TISInputSource? {
    return TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
}

func allSources() -> [TISInputSource] {
    guard let arr = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
    return arr
}

let prevID = currentSource().flatMap(idOf) ?? ""

let args = CommandLine.arguments
if args.count < 2 {
    print(prevID)
    exit(0)
}
let target = args[1]

var chosen: TISInputSource? = nil
if target == "ASCII" {
    let keyboardCategory = kTISCategoryKeyboardInputSource as String
    for s in allSources() {
        if categoryOf(s) == keyboardCategory
            && boolProp(s, kTISPropertyInputSourceIsASCIICapable)
            && boolProp(s, kTISPropertyInputSourceIsSelectCapable)
            && boolProp(s, kTISPropertyInputSourceIsEnabled) {
            chosen = s
            break
        }
    }
} else {
    for s in allSources() where idOf(s) == target {
        chosen = s
        break
    }
}

guard let src = chosen else {
    FileHandle.standardError.write("setlayout: источник ввода '\(target)' не найден\n".data(using: .utf8)!)
    print(prevID)
    exit(1)
}

let status = TISSelectInputSource(src)
if status != noErr {
    FileHandle.standardError.write("setlayout: не удалось выбрать источник (OSStatus \(status))\n".data(using: .utf8)!)
    print(prevID)
    exit(2)
}
print(prevID)
exit(0)
