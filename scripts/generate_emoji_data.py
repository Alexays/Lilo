#!/usr/bin/env python3
"""Generate the Space emoji picker's dataset from Unicode emoji-test.txt and the CLDR annotations of each UI locale."""
import os, re, sys, unicodedata, urllib.request
import xml.etree.ElementTree as ET

# Apple Color Emoji on macOS 27 draws Emoji 17.0; newer emoji would show as missing glyphs.
EMOJI_TEST_URL = "https://unicode.org/Public/17.0.0/emoji/emoji-test.txt"
CLDR_URL = "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/{kind}/{locale}.xml"
GROUPS = [
    "Smileys & Emotion",
    "People & Body",
    "Animals & Nature",
    "Food & Drink",
    "Activities",
    "Travel & Places",
    "Objects",
    "Symbols",
    "Flags",
]
TONES = "\U0001F3FB\U0001F3FC\U0001F3FD\U0001F3FE\U0001F3FF"
# The UI locales (lilo-ui/src/lib/i18n), each with the words too common to search by. English, the
# first, ships with the picker; every other locale is its own chunk, loaded when the picker opens in it.
LOCALES = {
    "en": {"a", "an", "and", "in", "of", "on", "the", "with"},
    "fr": {"a", "au", "aux", "avec", "d", "de", "des", "du", "en", "et", "l", "la", "le", "les", "sur", "un", "une"},
    "es": {"a", "al", "con", "de", "del", "el", "en", "la", "las", "los", "un", "una", "y"},
    "zh-Hans": set(),
    "pt-BR": {"a", "as", "com", "da", "das", "de", "do", "dos", "e", "em", "na", "nas", "no", "nos", "o", "os", "um", "uma"},
    "ru": {"в", "во", "для", "и", "из", "к", "на", "о", "от", "по", "с", "со", "у"},
    "uk": {"в", "для", "з", "зі", "й", "на", "у", "і"},
    "de": {"auf", "das", "der", "die", "ein", "eine", "im", "in", "mit", "und", "von"},
    "ja": set(),
    "it": {"a", "al", "con", "da", "di", "e", "il", "in", "la", "le", "un", "una"},
}

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
output_dir = os.path.join(root, "lilo-ui", "src", "components", "spaces")


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read().decode("utf-8")


# Folds as the picker's fold() does: no case, no accents, ligatures spelled out.
def words(text):
    folded = "".join(c for c in unicodedata.normalize("NFD", text.lower()) if not unicodedata.combining(c))
    return re.findall(r"[^\W_]+", folded.replace("œ", "oe").replace("æ", "ae").replace("ß", "ss").replace("ı", "i"))


def annotations(locale):
    names, keywords = {}, {}
    # CLDR's base Portuguese annotations use Brazilian Portuguese.
    locale = "pt" if locale == "pt-BR" else locale
    # CLDR's base Chinese catalog uses Simplified Chinese; its filename is zh.xml.
    locale = "zh" if locale == "zh-Hans" else locale
    for kind in ("annotations", "annotationsDerived"):
        for node in ET.fromstring(fetch(CLDR_URL.format(kind=kind, locale=locale))).iter("annotation"):
            cp = node.get("cp", "").replace("\uFE0F", "")
            # French puts a no-break space before a colon; a plain one reads the same in a tooltip.
            (names if node.get("type") == "tts" else keywords).setdefault(cp, " ".join(node.text.split()))
    return names, keywords


def write(name, data, source):
    path = os.path.join(output_dir, name)
    if any(mark in data for mark in ("`", "\\", "${")):
        print(f"error: a name or keyword in {name} needs escaping in a template literal", file=sys.stderr)
        sys.exit(1)
    with open(path, "w", encoding="utf-8") as f:
        f.write(source)
    print(f"{os.path.relpath(path, root)}: {len(source.encode('utf-8')):,} bytes")


def main():
    base, *others = LOCALES
    names, keywords = annotations(base)

    groups = {name: [] for name in GROUPS}
    qualified = set()
    group = None
    for line in fetch(EMOJI_TEST_URL).splitlines():
        if line.startswith("# group: "):
            group = line[len("# group: "):]
        if "; fully-qualified" not in line:
            continue
        emoji = "".join(chr(int(cp, 16)) for cp in line.split(";")[0].split())
        qualified.add(emoji)
        if group in groups and not any(tone in emoji for tone in TONES):
            groups[group].append(emoji)

    rows_by_group, english_words, order = [], [], []
    for emojis in groups.values():
        rows = []
        for emoji in emojis:
            key = emoji.replace("\uFE0F", "")
            name = names.get(key)
            if not name:
                print(f"error: no CLDR name for {emoji}", file=sys.stderr)
                sys.exit(1)
            seen = set(words(name)) | LOCALES[base]
            extra = [w for w in dict.fromkeys(words(keywords.get(key, ""))) if w not in seen]
            # A person emoji takes a skin tone when its medium-tone form (modifier after the first code
            # point, in place of FE0F) is itself an emoji; the picker builds the toned form the same way.
            rest = emoji[1:].removeprefix("\uFE0F")
            tone = "1" if emoji[0] + TONES[2] + rest in qualified else ""
            rows.append("\t".join([emoji, name, " ".join(extra), tone]).rstrip("\t"))
            english_words.append(seen | set(extra))
            order.append(key)
        rows_by_group.append("\n".join(rows))

    body = ",\n".join("  `" + rows + "`" for rows in rows_by_group)
    write("emojiData.gen.ts", "\n".join(rows_by_group), (
        "// Generated by scripts/generate_emoji_data.py (make emoji-data) from Unicode emoji 17.0 and CLDR 48.\n"
        "// One string per category; one emoji per line, tab-separated: emoji, English name, extra search\n"
        "// keywords, and 1 when it takes a skin tone.\n"
        f"export const EMOJI_GROUPS: readonly string[] = [\n{body},\n];\n"
    ))

    for locale in others:
        local_names, local_keywords = annotations(locale)
        rows = []
        for key, seen in zip(order, english_words):
            # English names the few emoji the locale has no name for yet.
            name = local_names.get(key) or names[key]
            seen = seen | set(words(name)) | LOCALES[locale]
            extra = [w for w in dict.fromkeys(words(local_keywords.get(key, ""))) if w not in seen]
            rows.append("\t".join([name, " ".join(extra)]).rstrip("\t"))
        body = "\n".join(rows)
        write(f"emojiData.{locale}.gen.ts", body, (
            "// Generated by scripts/generate_emoji_data.py (make emoji-data) from CLDR 48.\n"
            f"// One line per emoji of EMOJI_GROUPS, in order, tab-separated: {locale} name and the search keywords\n"
            "// English does not already give it.\n"
            f"export const EMOJI_NAMES = `{body}`;\n"
        ))
    print(f"{len(order)} emoji")


main()
