#!/usr/bin/env bash
#
# Differential test vectors for PodBoxArtName (Sources/CrateDiggerCore/
# Services/PodBox/PodBoxArtName.swift), produced by PodBox's own C.
#
# A dev tool: the build and the tests never run it. It fetches
# apps-ipod/metadata/art_name.c at the pinned commit into a temp folder
# outside the repo, compiles it with a small driver and a stub UTF-8 decoder
# written here, runs it over the fixed corpus below and prints JSON
# [{"name":…,"key":…,"altKey":…}] on stdout. PodBox is GPL: its source is
# only ever read from the temp folder, and only this output is committed, as
# Tests/CrateDiggerCoreTests/Fixtures/podbox-artname-vectors.json.
#
#   scripts/podbox-artname-vectors.sh > Tests/CrateDiggerCoreTests/Fixtures/podbox-artname-vectors.json
#
# PODBOX_ART_NAME_C=/path/to/art_name.c uses a local copy (of the same
# commit) instead of downloading. The download sends curl's default headers
# and nothing else. The corpus holds made-up and well-known names only.
#
# The stub decodes into a 32-bit ucschar_t. Every corpus name is in the
# Basic Multilingual Plane, where a 16-bit firmware build decodes the same.

set -euo pipefail

COMMIT="f0850c4647e7c1cfde11ffc89ab40b55f8aa5635"
URL="https://raw.githubusercontent.com/anthonyfletcher/podbox/${COMMIT}/apps-ipod/metadata/art_name.c"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/podbox-artname.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

if [[ -n "${PODBOX_ART_NAME_C:-}" ]]; then
  cp "${PODBOX_ART_NAME_C}" "${WORK}/art_name.c"
else
  curl --fail --silent --show-error --location --output "${WORK}/art_name.c" "${URL}"
fi

cat > "${WORK}/art_name.h" <<'EOF'
#ifndef _ART_NAME_H_
#define _ART_NAME_H_
#include <stdbool.h>
#include <stddef.h>
unsigned int art_name_hash(const char *name);
unsigned int art_name_hash_n(const char *name, size_t len);
unsigned int art_name_alt_hash(const char *name);
unsigned int art_name_alt_hash_n(const char *name, size_t len);
unsigned int art_name_work_hash(const char *artist, const char *title);
unsigned int art_name_album_hash(const char *artist, const char *title);
#endif
EOF

cat > "${WORK}/rbunicode.h" <<'EOF'
#ifndef STUB_RBUNICODE_H
#define STUB_RBUNICODE_H
#include <strings.h>
typedef unsigned int ucschar_t;
const unsigned char *utf8decode(const unsigned char *utf8, ucschar_t *ucs);
#endif
EOF

cat > "${WORK}/stub_unicode.c" <<'EOF'
#include "rbunicode.h"

/* A plain UTF-8 decoder. A malformed sequence gives U+FFFD and moves one byte. */
const unsigned char *utf8decode(const unsigned char *s, ucschar_t *ucs)
{
    unsigned char c = s[0];
    int extra;
    ucschar_t value;
    if (c < 0x80) { *ucs = c; return s + 1; }
    if ((c & 0xE0) == 0xC0) { extra = 1; value = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { extra = 2; value = c & 0x0F; }
    else if ((c & 0xF8) == 0xF0) { extra = 3; value = c & 0x07; }
    else { *ucs = 0xFFFD; return s + 1; }
    for (int i = 1; i <= extra; i++) {
        if ((s[i] & 0xC0) != 0x80) { *ucs = 0xFFFD; return s + 1; }
        value = (value << 6) | (s[i] & 0x3F);
    }
    *ucs = value;
    return s + extra + 1;
}
EOF

cat > "${WORK}/driver.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include "art_name.h"

/* Reads NUL-terminated names on stdin; prints "key altKey" per name. */
int main(void)
{
    static char name[65536];
    size_t length = 0;
    int ch;
    while ((ch = getchar()) != EOF) {
        if (length + 1 >= sizeof name) return 2;
        name[length++] = (char)ch;
        if (ch == 0) {
            printf("%u %u\n", art_name_hash(name), art_name_alt_hash(name));
            length = 0;
        }
    }
    return 0;
}
EOF

cc -std=c99 -O1 -w -I "${WORK}" -o "${WORK}/vectors" \
  "${WORK}/art_name.c" "${WORK}/stub_unicode.c" "${WORK}/driver.c"

python3 -I - "${WORK}/vectors" <<'EOF'
import json
import subprocess
import sys

corpus = [
    # Worked examples from the brief.
    "N*E*R*D", "N.E.R.D", "NERD",
    "AC/DC", "AC_DC", "AC-DC", "ACDC",
    "Björk", "Björk", "Bjork", "BJÖRK",
    "The Beatles", "Beatles", "Beatles, The", "the beatles", "BEATLES, THE",
    "Simon & Garfunkel", "Simon and Garfunkel",
    "The The", "The ", "The", "the", "Them", "Theme", ", the", "x, the", "x,the",
    "Herbert, Frank", "Frank Herbert", "Pratchett, Terry", "Terry Pratchett",
    "a, b, c", "No Comma", "Comma,", ",Comma", "The Smiths, The",
    "!!!", "", "&&&", "&", "...", " ", "?",
    "Ø", "ø", "Œ", "œ", "Æ", "æ", "ß", "Þ", "þ", "Ĳ", "ĳ", "ÿ", "ſ",
    "ＡＢＣ", "ａｂｃ", "１２３", "！", "～",
    "КИНО", "Кино", "кино", "椎名林檎", "Sigur Rós", "Sigur Ros",
    "Motörhead", "Mötley Crüe", "Röyksopp", "Hüsker Dü", "Beyoncé",
    "Łona", "Dvořák", "Antonín Dvořák", "Dvořák, Antonín",
    "R.E.M.", "R.E.M", "Who's Next?", "Who's Next", "Guns N' Roses",
    "M83", "50 Cent", "+44", "Sunn O)))",
    "Café Tacvba", "Café Tacvba",
    "Ελληνικά", "עברית", "한국어", "ﾊﾝｶｸ",
]

# Dropped ranges, one each, between two kept letters.
corpus += [
    "a©b",   # U+0080..00BF Latin-1 symbols
    "áb",   # U+0300..036F combining marks
    "a—b",   # U+2000..2BFF punctuation and symbols
    "a、b",   # U+3000..303F CJK punctuation
    "a️b",   # U+FE00..FE0F variation selectors
    "a\u0080b", "a¿b", "aͯb", "a b", "a⯿b", "a　b", "a〿b", "a︀b",
    "aƀb", "aⰀb", "a぀b", "a︐b", "a｟b", "a＀b",
]

# Every column of the six Latin table rows, U+00C0..U+017F.
corpus += ["x" + chr(c) + "y" for c in range(0xC0, 0x180)]

process = subprocess.run([sys.argv[1]], input=b"".join(n.encode("utf-8") + b"\0" for n in corpus),
                         capture_output=True, check=True)
lines = process.stdout.decode().splitlines()
assert len(lines) == len(corpus), (len(lines), len(corpus))
vectors = []
for name, line in zip(corpus, lines):
    key, alt = (int(v) for v in line.split())
    vectors.append({"name": name, "key": key, "altKey": alt})
print(json.dumps(vectors, ensure_ascii=False, indent=1))
EOF
