import AppKit
import Carbon.HIToolbox

/// Serbian Latin from any keyboard layout. Letters go by the physical key (US positions), so the
/// Russian layout types Latin too, and the keys right of L and P give the letters with diacritics,
/// where a Serbian keyboard has them: ; č · ' ć · [ š · ] đ · \ ž.
enum SerbianKeys {
    /// The key for each letter with diacritics, as printed on a US keyboard.
    static let diacriticKeys: [(letter: Character, key: String)] = [
        ("č", ";"), ("ć", "'"), ("š", "["), ("đ", "]"), ("ž", "\\"),
    ]

    private static let serbianLetters = "čćšžđČĆŠŽĐ"

    /// The same letters by the symbol a key types, wherever the layout or an ISO keyboard puts it
    /// (on some the bracket or the backslash takes Shift): the symbol's own case decides.
    private static let bySymbol: [Character: String] = [
        ";": "č", ":": "Č", "'": "ć", "\"": "Ć", "[": "š", "{": "Š", "]": "đ", "}": "Đ", "\\": "ž", "|": "Ž",
    ]

    private static let byKeyCode: [Int: Character] = {
        var map: [Int: Character] = [
            kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d", kVK_ANSI_E: "e",
            kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h", kVK_ANSI_I: "i", kVK_ANSI_J: "j",
            kVK_ANSI_K: "k", kVK_ANSI_L: "l", kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o",
            kVK_ANSI_P: "p", kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
            kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x", kVK_ANSI_Y: "y",
            kVK_ANSI_Z: "z",
            kVK_ANSI_Semicolon: "č", kVK_ANSI_Quote: "ć", kVK_ANSI_LeftBracket: "š",
            kVK_ANSI_RightBracket: "đ", kVK_ANSI_Backslash: "ž",
        ]
        // On the Russian layout б and ю sit where , and . are.
        map[kVK_ANSI_Comma] = ","
        map[kVK_ANSI_Period] = "."
        return map
    }()

    /// The physical key's US letter, whatever the layout ("a" for the key that types ф).
    static func usLetter(_ event: NSEvent) -> Character? {
        guard let char = byKeyCode[Int(event.keyCode)], char.isASCII, char.isLetter else { return nil }
        return char
    }

    /// What a key press types in Serbian Latin, or nil to leave it alone. Latin letters (and
    /// č ć š ž đ from a Serbian layout) stay as they are; letters from another layout and the
    /// diacritic keys become the Serbian letter on that key.
    static func typed(_ event: NSEvent) -> String? {
        guard let chars = event.characters, chars.count == 1, let char = chars.first else { return nil }
        if char.isASCII, char.isLetter { return nil }
        if serbianLetters.contains(char) { return nil }
        let isDiacriticKey = [kVK_ANSI_Semicolon, kVK_ANSI_Quote, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket, kVK_ANSI_Backslash]
            .contains(Int(event.keyCode))
        guard char.isLetter || isDiacriticKey, let mapped = byKeyCode[Int(event.keyCode)] else { return bySymbol[char] }
        let shifted = event.modifierFlags.contains(.shift) != event.modifierFlags.contains(.capsLock)
        return shifted ? String(mapped).uppercased() : String(mapped)
    }

    /// The Serbian letter a key press stands for (lowercase), for the letter tiles.
    static func letter(_ event: NSEvent) -> Character? {
        if let mapped = typed(event) { return mapped.lowercased().first.flatMap { $0.isLetter ? $0 : nil } }
        guard let char = event.charactersIgnoringModifiers?.lowercased().first,
              event.charactersIgnoringModifiers?.count == 1,
              char.isLetter, char.isASCII || serbianLetters.contains(char) else { return nil }
        return char
    }

    /// "?" for Don't know: Shift-/ on a US keyboard, or wherever the layout puts it.
    static func isQuestionMark(_ event: NSEvent) -> Bool {
        event.characters == "?" || (event.keyCode == kVK_ANSI_Slash && event.modifierFlags.contains(.shift))
    }
}
