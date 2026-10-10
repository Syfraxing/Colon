#!/usr/bin/env python3
"""Build Sources/ColonCore/Resources/emoji.json (+ i18n/<lang>.json.deflate) from upstream emoji datasets.

Sources (pinned by version and SHA-256, see THIRD_PARTY_NOTICES.md):
  * github/gemoji         db/emoji.json              -> GitHub/Slack aliases + tags        (MIT)
  * emojibase-data (en)   data.json                  -> CLDR names + keywords, order, skin tones (MIT)
                          shortcodes/iamcal.json     -> Slack shortcodes
                          shortcodes/github.json     -> GitHub shortcodes
                          shortcodes/emojibase.json  -> emojibase shortcodes
                          shortcodes/cldr.json       -> CLDR shortcodes
  * emojilib              dist/emoji-en-US.json      -> extra everyday keywords            (MIT)
  * cldr-annotations-full / cldr-annotations-derived-full (npm tarballs of Unicode CLDR JSON)
                                                     -> localized names + keywords         (Unicode License v3)

emoji.json is a JSON array in Unicode order whose objects decode as `Emoji`:
  {"id", "char", "name", "category", "shortcodes", "keywords", "supportsSkinTone"}
plus an optional "v" (Unicode emoji version) when newer than 15.0, which lets
EmojiStore hide glyphs the running macOS cannot render.

i18n/<lang>.json.deflate (one per entry in LANGUAGES, raw DEFLATE so the app stays small) holds
a JSON object `{"<Emoji.id>": ["<name>", "<keyword>", ...]}` in dataset order. Terms are folded
(lowercase, accents removed: `inimă` -> `inima`) exactly like `TextFolding.fold` in Swift; the app
loads a file only when the user enables that search language.

Usage: python3 scripts/build-emoji-data.py [--cache DIR] [--out PATH] [--i18n DIR]
Python 3 standard library only. Output is deterministic for the pinned inputs.
"""

import argparse
import hashlib
import io
import json
import os
import re
import sys
import tarfile
import unicodedata
import urllib.request
import zlib

GEMOJI_REF = "fadaeaf1f1a9be82b321316a6c5502e43138b2f6"
EMOJIBASE_VERSION = "17.0.0"
EMOJILIB_VERSION = "4.0.2"
CLDR_VERSION = "48.2.0"

GEMOJI_URL = f"https://raw.githubusercontent.com/github/gemoji/{GEMOJI_REF}/db/emoji.json"
EMOJIBASE_URL = f"https://cdn.jsdelivr.net/npm/emojibase-data@{EMOJIBASE_VERSION}/en/"
EMOJILIB_URL = f"https://cdn.jsdelivr.net/npm/emojilib@{EMOJILIB_VERSION}/dist/emoji-en-US.json"
CLDR_URL = "https://registry.npmjs.org/{name}/-/{name}-" + CLDR_VERSION + ".tgz"

# cache file name -> (url, sha256)
SOURCES = {
    "gemoji.json": (
        GEMOJI_URL,
        "b174ae2aeb321b52f64adb9ff412f966a7f338839d780784dd15dcad702c2dd6",
    ),
    "emojibase-data.json": (
        EMOJIBASE_URL + "data.json",
        "ed014f1049bd370c5794f815850156196ac382850f51c3e9f6a9e83553fb3f01",
    ),
    "emojibase-iamcal.json": (
        EMOJIBASE_URL + "shortcodes/iamcal.json",
        "b1952bd90cb8580224434eaf8f1911265d23a78c7ed36f39f8590c90847443eb",
    ),
    "emojibase-github.json": (
        EMOJIBASE_URL + "shortcodes/github.json",
        "d6bb7101e7bab1e52b30f4b3562da2319b484a6266352a1119f0d1ba52db23db",
    ),
    "emojibase-emojibase.json": (
        EMOJIBASE_URL + "shortcodes/emojibase.json",
        "db3d41edf2f190bcb81bf171a51b1f889af774eed5dc24d21ad8dfcb998b40d3",
    ),
    "emojibase-cldr.json": (
        EMOJIBASE_URL + "shortcodes/cldr.json",
        "62577c7290e5335b9c80ef5d598eef8b743d4505a7d222e865b9df04ade4d564",
    ),
    "emojilib-en-US.json": (
        EMOJILIB_URL,
        "3e3ac8b3a3a12e414857efbcd06c1c74fb457848e565ecde3372cff826bfc032",
    ),
    "cldr-annotations-full.tgz": (
        CLDR_URL.format(name="cldr-annotations-full"),
        "28576e51225deb51e3ddd734b0f824a0079682cb5d8c27faa9f68149317a14d1",
    ),
    "cldr-annotations-derived-full.tgz": (
        CLDR_URL.format(name="cldr-annotations-derived-full"),
        "4be946ff5815f806ec78b50363d577a769f2fbfb90c6380a44e161a92436996e",
    ),
}

# Search languages: Colon code -> CLDR locale. The languages macOS itself ships in (English is the
# base dataset). Codes must match `SearchLanguages.supported` in Swift (a unit test checks the files).
# A regional locale (pt-PT) is layered over its parent (pt), like CLDR inheritance.
LANGUAGES = {
    "ar": "ar", "ca": "ca", "cs": "cs", "da": "da", "de": "de", "el": "el", "es": "es",
    "fi": "fi", "fr": "fr", "he": "he", "hi": "hi", "hr": "hr", "hu": "hu", "id": "id",
    "it": "it", "ja": "ja", "ko": "ko", "ms": "ms", "nl": "nl", "no": "no", "pl": "pl",
    "pt": "pt", "pt-PT": "pt-PT", "ro": "ro", "ru": "ru", "sk": "sk", "sv": "sv", "th": "th",
    "tr": "tr", "uk": "uk", "vi": "vi", "zh": "zh", "zh-Hant": "zh-Hant",
}
CLDR_PARENTS = {"pt-PT": "pt"}

# emojibase group index -> Unicode category name.
GROUPS = {
    0: "Smileys & Emotion",
    1: "People & Body",
    2: "Component",
    3: "Animals & Nature",
    4: "Food & Drink",
    5: "Travel & Places",
    6: "Activities",
    7: "Objects",
    8: "Symbols",
    9: "Flags",
}
SKIPPED_GROUPS = {2}  # skin tone / hair components are not standalone emoji

# Chat slang the upstream keyword sets miss, so local search alone handles everyday shortcuts.
# Keyed by emoji; Colon's own data (MIT, same as the project).
SLANG = {
    "😂": ["lmao", "lmfao", "ded", "dying", "crying laughing", "hilarious"],
    "🤣": ["lmao", "lmfao", "rofl", "dying", "ded"],
    "💀": ["ded", "dying", "im dead", "lmao", "rip"],
    "😭": ["crying", "sobbing", "ded", "dying"],
    "🤨": ["sus", "suspicious", "sketchy", "hmm"],
    "👀": ["sus", "tea", "lookin", "watching"],
    "😏": ["sus", "smug", "flirt"],
    "🙏": ["ty", "thx", "tysm", "thanks", "thank you", "please", "pls", "plz"],
    "🫶": ["ty", "thanks", "love you", "ily"],
    "☀️": ["gm", "good morning", "morning"],
    "🌅": ["gm", "good morning", "sunrise"],
    "☕": ["gm", "morning"],
    "🌙": ["gn", "good night", "night"],
    "😴": ["gn", "good night", "tired", "sleepy"],
    "💤": ["gn", "good night"],
    "👍": ["bet", "ok", "okay", "kk", "sounds good", "sgtm", "lgtm", "yes", "yep"],
    "🤝": ["bet", "deal", "agreed"],
    "💯": ["bet", "facts", "fr", "for real", "true", "100"],
    "🐐": ["goat", "greatest", "goated", "legend"],
    "✨": ["vibes", "magic", "sparkle", "aesthetic"],
    "😎": ["vibes", "cool", "chill"],
    "🎶": ["vibes", "music", "song"],
    "🎉": ["yay", "woohoo", "congrats", "congratulations", "celebrate", "hooray", "party"],
    "🥳": ["yay", "woohoo", "party", "bday", "birthday", "celebrate"],
    "🙌": ["yay", "praise", "hooray", "finally"],
    "🎂": ["bday", "hbd", "birthday"],
    "🎁": ["bday", "present"],
    "🪦": ["rip", "rest in peace", "dead"],
    "🥀": ["rip", "wilted", "sad"],
    "😱": ["omg", "shocked", "scared"],
    "😮": ["omg", "wow", "shocked"],
    "🤯": ["omg", "mind blown", "mindblown"],
    "💪": ["flex", "strong", "gains", "gym", "workout"],
    "💅": ["slay", "sassy", "unbothered"],
    "🧢": ["cap", "lie", "no cap"],
    "🔥": ["lit", "hot", "fire", "hype", "slaps"],
    "🚀": ["ship", "shipped", "ship it", "launch", "deploy", "to the moon"],
    "🚢": ["ship", "shipped", "ship it"],
    "😅": ["nervous", "awkward", "oops", "phew"],
    "😬": ["nervous", "awkward", "yikes", "eek", "oops"],
    "🤦": ["smh", "facepalm", "ugh"],
    "🤷": ["idk", "dunno", "whatever", "shrug"],
    "👏": ["clap", "bravo", "applause", "well done"],
    "🥺": ["pls", "please", "pleading", "puppy eyes", "aww"],
    "😍": ["love", "crush", "obsessed"],
    "❤️": ["love", "ily", "luv", "<3"],
    "😘": ["love", "kiss", "xoxo", "mwah"],
    "🫡": ["salute", "on it", "yes sir", "roger"],
    "🤡": ["clown", "fool", "joke"],
    "🗿": ["moai", "stone face", "bruh"],
    "😐": ["bruh", "meh", "unamused"],
    "🙄": ["eyeroll", "ugh", "whatever"],
    "🤔": ["hmm", "think", "thinking", "wonder"],
    "😢": ["sad", "cry", "tear"],
    "😔": ["sad", "pensive", "down"],
    "😡": ["angry", "mad", "furious"],
    "😤": ["angry", "frustrated", "huffing"],
    "🤑": ["money", "rich", "cash"],
    "💸": ["money", "spending", "cash"],
    "🍻": ["beer", "cheers", "drinks"],
    "🥂": ["cheers", "toast", "celebrate"],
    "👋": ["hi", "hello", "hey", "bye", "wave"],
    "🫠": ["melting", "embarrassed", "dying", "too hot"],
    "🥲": ["happy tears", "bittersweet", "its fine"],
    "😉": ["wink", "jk", "kidding"],
    "🆗": ["ok", "okay"],
    "👌": ["ok", "okay", "perfect", "nice"],
    "🌧️": ["rain", "rainy"],
    "☔": ["rain", "rainy"],
}

SKIN_TONES = ["1F3FB", "1F3FC", "1F3FD", "1F3FE", "1F3FF"]
VS16 = "FE0F"

SHORTCODE_RE = re.compile(r"^[a-z0-9_+\-]+$")


def fetch_bytes(cache_dir, name):
    url, sha256 = SOURCES[name]
    path = os.path.join(cache_dir, name) if cache_dir else None
    if path and os.path.exists(path):
        with open(path, "rb") as fh:
            data = fh.read()
    else:
        print(f"downloading {url}", file=sys.stderr)
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != sha256:
        sys.exit(f"error: {name} sha256 {digest} does not match pinned {sha256} ({url})")
    if path and not os.path.exists(path):
        os.makedirs(cache_dir, exist_ok=True)
        with open(path, "wb") as fh:
            fh.write(data)
    return data


def fetch(cache_dir, name):
    return json.loads(fetch_bytes(cache_dir, name))


def hex_to_char(hexcode):
    return "".join(chr(int(part, 16)) for part in hexcode.split("-"))


def strip_vs(text):
    return text.replace("️", "").replace("︎", "")


def as_list(value):
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def toned_hexcode(hexcode, tone):
    """Where Colon inserts a skin tone: right after the first scalar, dropping its VS16."""
    parts = hexcode.split("-")
    rest = parts[1:]
    if rest and rest[0] == VS16:
        rest = rest[1:]
    return "-".join([parts[0], tone] + rest)


def supports_single_skin_tone(entry):
    """True when every tone variant is exactly the base with one modifier after the first scalar."""
    skins = entry.get("skins") or []
    by_hex = {strip_vs_hex(s["hexcode"]) for s in skins}
    return bool(skins) and all(
        strip_vs_hex(toned_hexcode(entry["hexcode"], tone)) in by_hex for tone in SKIN_TONES
    )


def strip_vs_hex(hexcode):
    return "-".join(p for p in hexcode.split("-") if p != VS16)


def normalize_shortcode(code):
    code = code.strip().lower().strip(":")
    return code if SHORTCODE_RE.match(code) else None


def normalize_keyword(word):
    word = " ".join(word.replace("\u2019", "'").strip().lower().split())
    return word or None


# Letters NFD does not decompose into base + accent. Mirrors `TextFolding` in Swift.
FOLD_SPECIAL = str.maketrans({"ł": "l", "ø": "o", "đ": "d", "ß": "ss", "æ": "ae", "œ": "oe", "ı": "i"})


def fold(text):
    """Lowercase, drop combining accents (U+0300-U+036F), map FOLD_SPECIAL, NFC. Same as Swift."""
    text = unicodedata.normalize("NFD", text.lower())
    text = "".join(c for c in text if not 0x300 <= ord(c) <= 0x36F)
    return unicodedata.normalize("NFC", text.translate(FOLD_SPECIAL))


def dedupe(items):
    seen = set()
    out = []
    for item in items:
        if item and item not in seen:
            seen.add(item)
            out.append(item)
    return out


def build(cache_dir):
    gemoji = fetch(cache_dir, "gemoji.json")
    data = fetch(cache_dir, "emojibase-data.json")
    presets = [
        fetch(cache_dir, "emojibase-iamcal.json"),
        fetch(cache_dir, "emojibase-github.json"),
        fetch(cache_dir, "emojibase-emojibase.json"),
        fetch(cache_dir, "emojibase-cldr.json"),
    ]
    emojilib = {strip_vs(k): v for k, v in fetch(cache_dir, "emojilib-en-US.json").items()}

    gemoji_by_char = {strip_vs(g["emoji"]): g for g in gemoji if g.get("emoji")}
    slang = {strip_vs(k): v for k, v in SLANG.items()}

    entries = [
        e for e in data
        if e.get("group") is not None
        and e["group"] not in SKIPPED_GROUPS
        and e.get("order") is not None
    ]
    entries.sort(key=lambda e: e["order"])

    used_ids = set()
    out = []
    for e in entries:
        hexcode = e["hexcode"]
        g = gemoji_by_char.get(strip_vs(hex_to_char(hexcode)))
        # gemoji keeps the fully-qualified form (e.g. ❤️ with VS16); emojibase hexcodes may drop it.
        char = g["emoji"] if g else hex_to_char(hexcode)

        # Slack/GitHub aliases first, then the other conventions.
        codes = []
        if g:
            codes += g.get("aliases", [])
        for preset in presets:
            codes += as_list(preset.get(hexcode))
        codes = dedupe(normalize_shortcode(c) for c in codes)
        if not codes:
            continue

        emoji_id = next((c for c in codes if c not in used_ids), None)
        if emoji_id is None:
            continue
        used_ids.add(emoji_id)
        codes.remove(emoji_id)
        codes.insert(0, emoji_id)

        keywords = list(slang.pop(strip_vs(char), []))
        if g:
            keywords += g.get("tags", [])
        keywords += e.get("tags", [])
        # emojilib leads with its own snake_case name; shortcodes already cover that.
        keywords += [k for k in emojilib.get(strip_vs(char), []) if "_" not in k]
        keywords = dedupe(normalize_keyword(k) for k in keywords)

        item = {
            "id": emoji_id,
            "char": char,
            "name": e["label"],
            "category": GROUPS[e["group"]],
            "shortcodes": codes,
            "keywords": keywords,
            "supportsSkinTone": supports_single_skin_tone(e),
        }
        version = e.get("version") or 0
        if version > 15.0:
            item["v"] = version
        out.append(item)
    if slang:
        sys.exit(f"error: SLANG entries without a matching emoji: {sorted(slang)}")
    return out


def read_cldr(cache_dir):
    """locale -> {emoji without VS: {"default": [...], "tts": [...]}}, annotations over derived."""
    wanted = set(LANGUAGES.values()) | set(CLDR_PARENTS.values())
    found = {}
    for archive, kind in (
        ("cldr-annotations-full.tgz", "annotations"),
        ("cldr-annotations-derived-full.tgz", "annotationsDerived"),
    ):
        with tarfile.open(fileobj=io.BytesIO(fetch_bytes(cache_dir, archive)), mode="r:gz") as tar:
            for locale in sorted(wanted):
                member = tar.extractfile(f"package/{kind}/{locale}/annotations.json")
                if member is None:
                    sys.exit(f"error: {archive} has no {kind}/{locale}")
                table = found.setdefault(locale, {})
                for key, value in json.load(member)[kind]["annotations"].items():
                    table.setdefault(strip_vs(key), value)
    return found


def fold_term(text):
    return fold(" ".join(text.replace("\u2019", "'").split()))


def build_localized(emoji, cache_dir):
    """code -> {id: [name, keyword, ...]} with folded terms, in dataset order."""
    cldr = read_cldr(cache_dir)
    out = {}
    for code, locale in LANGUAGES.items():
        table = dict(cldr[locale])
        for key, value in cldr.get(CLDR_PARENTS.get(locale), {}).items():
            table.setdefault(key, value)
        terms_by_id = {}
        for e in emoji:
            entry = table.get(strip_vs(e["char"]))
            if not entry:
                continue
            name = fold_term((entry.get("tts") or [""])[0])
            keywords = [fold_term(k) for k in entry.get("default", [])]
            singles = {k for k in keywords if " " not in k}
            # Queries never contain spaces, so a phrase only matches through its first word; when
            # that word is a keyword of its own it always scores at least as well. Drop the phrase.
            keywords = [k for k in keywords if " " not in k or k.split(" ")[0] not in singles]
            terms = dedupe([name] + [k for k in keywords if k != name])
            if terms:
                terms_by_id[e["id"]] = terms
        missing = len(emoji) - len(terms_by_id)
        if missing > len(emoji) // 4:
            sys.exit(f"error: CLDR {locale} covers only {len(terms_by_id)} of {len(emoji)} emoji")
        out[code] = terms_by_id
    return out


def deflate(data):
    """Raw DEFLATE (no zlib header), what `NSData.decompressed(using: .zlib)` reads."""
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
    return compressor.compress(data) + compressor.flush()


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    resources = os.path.join(root, "Sources", "ColonCore", "Resources")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cache", help="directory for downloaded sources (reused when present)")
    parser.add_argument("--out", default=os.path.join(resources, "emoji.json"))
    parser.add_argument("--i18n", default=os.path.join(resources, "i18n"),
                        help="directory for the per-language search terms")
    args = parser.parse_args()

    emoji = build(args.cache)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write("[\n")
        fh.write(",\n".join(json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in emoji))
        fh.write("\n]\n")
    print(f"wrote {len(emoji)} emoji to {os.path.relpath(args.out, root)}", file=sys.stderr)

    os.makedirs(args.i18n, exist_ok=True)
    expected = {f"{code}.json.deflate" for code in LANGUAGES}
    for stale in sorted(set(os.listdir(args.i18n)) - expected):
        os.remove(os.path.join(args.i18n, stale))
    total = 0
    for code, terms in build_localized(emoji, args.cache).items():
        text = "{\n" + ",\n".join(
            json.dumps(key, ensure_ascii=False) + ":" + json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            for key, value in terms.items()
        ) + "\n}\n"
        data = deflate(text.encode("utf-8"))
        total += len(data)
        with open(os.path.join(args.i18n, f"{code}.json.deflate"), "wb") as fh:
            fh.write(data)
    print(f"wrote {len(LANGUAGES)} languages ({total // 1024} KiB) to {os.path.relpath(args.i18n, root)}",
          file=sys.stderr)


if __name__ == "__main__":
    main()
