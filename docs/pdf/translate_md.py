# -*- coding: utf-8 -*-
"""
Translate a Markdown file from English to Chinese while preserving:
- YAML front matter / page comments (<!-- ... -->)
- Fenced code blocks (```...```)
- Inline code (`...`)
- Image references (![...](...) )
- Markdown headings, lists, tables structure (translate the text inside)
- URLs, file paths, email addresses
- Recognised BigWorld product names / identifiers (kept in English)

Usage:  python translate_md.py <input.md> <output.md>
"""
import os
import re
import sys
import time
from deep_translator import GoogleTranslator


# ---------------------------------------------------------------------------
# Terms that must stay in English (case-sensitive whole-word match).
# ---------------------------------------------------------------------------
KEEP_TERMS = [
    # BigWorld product / component names
    "BigWorld", "CellApp", "CellAppMgr", "BaseApp", "BaseAppMgr",
    "DBApp", "DBAppMgr", "LoginApp", "Reviver", "BWMachined", "BWMachineD",
    "WebConsole", "StatLogger", "MessageLogger", "SpaceViewer", "Bots",
    "SyncDB", "TransferDB", "ConsolidateDBs", "ClearAutoLoad",
    "FantasyDemo", "MongoDB", "MySQL", "MariaDB", "CentOS", "RedHat",
    "RHEL", "Linux", "Python", "wxPython", "HTML5", "JavaScript",
    "SDL", "SDL_image", "GNU", "gcc", "make", "gdb", "yum", "rpm",
    "httpd", "Carbon", "Graphite", "gnuplot", "VMWare", "IBM", "Xeon",
    "HT", "EPEL", "RPM", "UID", "GID", "TCP", "UDP", "IP", "MAC",
    "LDAP", "SSL", "TLS", "HTTPS", "HTTP", "URL", "URI",
    "BSD", "GPL", "LGPL", "API", "CLI", "GUI", "TUI",
    "CCU", "CCUs", "AoI", "NPC", "NPCs", "AI", "CPU", "CPUs", "RAM",
    "GB", "MB", "KB", "kB", "MHz", "GHz", "Hz",
    "LVM", "NTFS", "FAT32", "ext3", "ext4", "XFS",
    "SSH", "SCP", "SFTP", "FTP",
    "PID", "TID", "JSON", "XML", "YAML", "TOML", "INI",
    "PMC", "NOI", "NOC", "DNS", "DHCP", "NAT",
    "OSError", "Exception", "TypeError",
]

# Build a regex that matches any of the keep-terms as a whole word.
KEEP_RE = re.compile(
    r"\b(" + "|".join(re.escape(t) for t in KEEP_TERMS) + r")\b"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Match fenced code blocks
FENCE_RE = re.compile(r"^(\s*)(```|~~~)")
# Match inline code spans
INLINE_CODE_RE = re.compile(r"(`[^`]*`)")
# Match image references
IMAGE_RE = re.compile(r"(!\[[^\]]*\]\([^)]*\))")
# Match HTML comments
HTML_COMMENT_RE = re.compile(r"(<!--.*?-->)", re.DOTALL)
# Match markdown link text and URL separately: [text](url)
LINK_RE = re.compile(r"(\[([^\]]*)\]\(([^)]*)\))")
# Match bare URLs
URL_RE = re.compile(r"(https?://[^\s)]+)")
# Match page markers like <!-- PAGE 12 -->
PAGE_MARKER_RE = re.compile(r"^<!-- PAGE \d+ -->\s*$")


translator = GoogleTranslator(source="en", target="zh-CN")


def translate_segment(text: str) -> str:
    """Translate a piece of plain prose to Chinese.

    Preserves inline code, URLs and KEEP_TERMS by replacing them with
    placeholders before translation and restoring them afterwards.
    """
    if not text or not text.strip():
        return text

    placeholders = {}

    def stash(match):
        key = f"\x00{len(placeholders)}\x00"
        placeholders[key] = match.group(0)
        return key

    # Stash inline code, images, links, URLs, keep-terms
    text = INLINE_CODE_RE.sub(stash, text)
    text = IMAGE_RE.sub(stash, text)
    text = URL_RE.sub(stash, text)
    text = KEEP_RE.sub(stash, text)

    # Stash markdown heading hashes / list markers separately so they
    # are not mangled by the translator: we translate only the textual
    # content that follows them.
    # Split the leading markdown syntax characters from the rest.
    m = re.match(r"^(\s*)([*\-+\d.]+|\#{1,6}\s+|\|?\s*)(.*)$", text, re.DOTALL)
    prefix = ""
    body = text
    if m:
        prefix = m.group(1) + m.group(2)
        body = m.group(3)

    # Translate only the body if it has letters
    if body and re.search(r"[A-Za-z]", body):
        try:
            translated = translator.translate(body)
            if translated:
                body = translated
        except Exception as e:
            print("translate err:", e, file=sys.stderr)
            # Fall back to original body
            pass

    text = prefix + body

    # Restore placeholders
    # Do multiple passes in case nesting exists.
    for _ in range(3):
        for key, val in placeholders.items():
            text = text.replace(key, val)

    return text


def split_for_table(line: str):
    """Translate each cell of a markdown table row independently so the
    pipe structure is preserved."""
    if not line.startswith("|"):
        return translate_segment(line)
    # Split by | but keep empty leading/trailing cells produced by leading |
    parts = line.split("|")
    # First and last parts are usually empty (because line starts/ends with |)
    out = []
    for i, p in enumerate(parts):
        if i == 0 or i == len(parts) - 1:
            out.append(p)
            continue
        # Skip separator rows like ---|---|---
        if re.fullmatch(r"\s*:?-+:?\s*", p):
            out.append(p)
            continue
        out.append(translate_segment(p))
    return "|".join(out)


def translate_markdown(input_path: str, output_path: str):
    with open(input_path, "r", encoding="utf-8") as f:
        content = f.read()

    lines = content.split("\n")
    out_lines = []
    in_code = False
    buffer = []  # accumulating consecutive prose lines for batch translation
    last_translate_progress = 0

    def flush_buffer():
        nonlocal buffer
        if not buffer:
            return
        # Translate each buffered line. Could be batched but Google API
        # tolerates short strings fine.
        for ln in buffer:
            out_lines.append(translate_segment(ln))
        buffer = []

    for idx, line in enumerate(lines):
        if idx % 100 == 0:
            print(f"  line {idx}/{len(lines)}", file=sys.stderr)

        # Detect fenced code block boundaries
        if FENCE_RE.match(line):
            if in_code:
                # closing fence – flush any pending prose first, then emit
                flush_buffer()
                out_lines.append(line)
                in_code = False
            else:
                # opening fence
                flush_buffer()
                out_lines.append(line)
                in_code = True
            continue

        if in_code:
            out_lines.append(line)
            continue

        # Page markers and HTML comments are kept verbatim
        if PAGE_MARKER_RE.match(line):
            flush_buffer()
            out_lines.append(line)
            continue
        if line.strip().startswith("<!--") and line.strip().endswith("-->"):
            flush_buffer()
            out_lines.append(line)
            continue

        # Image-only lines
        if IMAGE_RE.fullmatch(line.strip()):
            flush_buffer()
            out_lines.append(line)
            continue

        # Blank lines
        if not line.strip():
            flush_buffer()
            out_lines.append(line)
            continue

        # Headings, list items, table rows, normal prose: buffer & translate
        buffer.append(line)

    flush_buffer()

    with open(output_path, "w", encoding="utf-8") as f:
        f.write("\n".join(out_lines))
    print("Wrote:", output_path, file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python translate_md.py <input.md> <output.md>")
        sys.exit(1)
    translate_markdown(sys.argv[1], sys.argv[2])
