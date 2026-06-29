# -*- coding: utf-8 -*-
"""
Extract a PDF to structured Markdown preserving TOC, headings, lists,
tables (best-effort) and images.

Usage:  python extract_pdf.py <pdf_path> <out_dir>
"""
import os
import re
import sys
import fitz  # PyMuPDF


def slugify(text: str) -> str:
    text = re.sub(r"[^\w\s-]", "", text.strip().lower())
    text = re.sub(r"[\s_-]+", "-", text)
    return text.strip("-") or "image"


def extract_images(page, page_no, out_dir, doc_name):
    """Save every image on the page; return list of (rect, relpath)."""
    img_dir = os.path.join(out_dir, "images")
    os.makedirs(img_dir, exist_ok=True)
    saved = []
    for idx, info in enumerate(page.get_images(full=True)):
        xref = info[0]
        try:
            base = doc.page_count  # placeholder, not used
            pix = fitz.Pixmap(doc, xref)
            if pix.n - pix.alpha >= 4:  # CMYK -> RGB
                pix = fitz.Pixmap(fitz.csRGB, pix)
            name = f"{doc_name}_p{page_no+1}_{idx+1}.png"
            path = os.path.join(img_dir, name)
            pix.save(path)
            saved.append(os.path.join("images", name).replace("\\", "/"))
            pix = None
        except Exception as e:
            print("img err:", e, file=sys.stderr)
    return saved


def render_full_page_image(page, page_no, out_dir, doc_name):
    """Render the whole page as a PNG – used as a fallback when a page is
    dominated by graphics/tables we cannot reliably parse to text."""
    img_dir = os.path.join(out_dir, "images")
    os.makedirs(img_dir, exist_ok=True)
    pix = page.get_pixmap(matrix=fitz.Matrix(2, 2))
    name = f"{doc_name}_page_{page_no+1}.png"
    path = os.path.join(img_dir, name)
    pix.save(path)
    return os.path.join("images", name).replace("\\", "/")


def block_to_md(b):
    """Convert a text block dict (from get_text('dict')) to markdown lines."""
    lines = []
    for ln in b["lines"]:
        text_parts = []
        cur_size = None
        cur_flags = None
        for sp in ln["spans"]:
            text_parts.append(sp["text"])
            cur_size = sp["size"]
            cur_flags = sp["flags"]
        line_text = "".join(text_parts).rstrip()
        if line_text:
            lines.append((line_text, cur_size, cur_flags, ln["bbox"]))
    return lines


def detect_heading_level(size, body_size):
    if size >= body_size * 1.6:
        return 1
    if size >= body_size * 1.35:
        return 2
    if size >= body_size * 1.18:
        return 3
    if size >= body_size * 1.08:
        return 4
    return 0


def is_bullet(text: str) -> bool:
    return bool(re.match(r"^\s*([-*•]|\d+\.)\s+", text))


def looks_like_table_row(text: str) -> bool:
    # Heuristic: multiple runs of 2+ spaces or tabs separating cells
    return bool(re.search(r" {2,}\S", text)) or "\t" in text


def build_page_md(page, page_no, out_dir, doc_name, toc_by_page, running_header_re=None):
    """Return markdown string for a single page."""
    md_lines = []

    # Add TOC headings that start on this page
    toc_titles_on_page = set()
    for lvl, title, pg in toc_by_page.get(page_no + 1, []):
        # pg is 1-based in PyMuPDF TOC
        md_lines.append("#" * lvl + " " + title.strip())
        toc_titles_on_page.add(title.strip())

    d = page.get_text("dict")
    page_h = page.rect.height
    page_w = page.rect.width

    # Determine body font size: median size of spans with most chars
    sizes = []
    for b in d["blocks"]:
        if b.get("type", 0) != 0:
            continue
        for ln in b["lines"]:
            for sp in ln["spans"]:
                if sp["text"].strip():
                    sizes.append(round(sp["size"], 1))
    if sizes:
        body_size = sorted(sizes)[len(sizes) // 2]
    else:
        body_size = 10.0

    # Extract images and inline them where they appear
    image_rels = extract_images(page, page_no, out_dir, doc_name)
    img_idx = 0

    # Build a unified list of (y, kind, payload) and sort by y position
    items = []
    for b in d["blocks"]:
        if b.get("type", 0) == 1:  # image block
            items.append((b["bbox"][1], "img_block", b["bbox"]))
        else:
            for line_text, size, flags, bbox in block_to_md(b):
                items.append((bbox[1], "text", (line_text, size, flags, bbox)))

    items.sort(key=lambda x: x[0])

    # First pass: collect text lines, then merge fragments belonging to the
    # same paragraph (consecutive lines with similar font size and small
    # vertical gap, no blank line between them).
    raw_lines = []  # list of (text, size, flags, bbox, kind)
    for y, kind, payload in items:
        if kind == "img_block":
            raw_lines.append(("", 0, 0, payload, "img"))
            continue
        line_text, size, flags, bbox = payload
        raw_lines.append((line_text, size, flags, bbox, "text"))

    # Filter header/footer noise: short text near page top (<5% height) or
    # bottom (>93% height) that is either a number (page number) or matches
    # the running header pattern.
    def is_noise(text, bbox):
        t = text.strip()
        if not t:
            return True
        y_top = bbox[1]
        y_bot = bbox[3]
        in_header = y_top < page_h * 0.045
        in_footer = y_bot > page_h * 0.93
        if in_footer and re.fullmatch(r"\d{1,3}", t):
            return True
        if running_header_re and (in_header or in_footer) and running_header_re.search(t):
            return True
        return False

    filtered = [r for r in raw_lines if r[4] != "text" or not is_noise(r[0], r[3])]

    # Emit, merging adjacent same-size text lines into paragraphs.
    in_code = False
    last_was_blank = True
    last_size = None
    last_flags = None
    para_buf = []

    def flush_para():
        nonlocal para_buf, last_was_blank
        if para_buf:
            text = " ".join(s.strip() for s in para_buf if s.strip())
            if text:
                md_lines.append(text)
            para_buf = []
        last_was_blank = False

    for text, size, flags, bbox, kind in filtered:
        if kind == "img":
            if in_code:
                md_lines.append("```")
                in_code = False
            flush_para()
            if img_idx < len(image_rels):
                md_lines.append(f"![image]({image_rels[img_idx]})")
                md_lines.append("")
                img_idx += 1
            last_was_blank = True
            last_size = None
            continue

        stripped = text.strip()
        if not stripped:
            if not last_was_blank:
                if in_code:
                    md_lines.append("```")
                    in_code = False
                flush_para()
                md_lines.append("")
                last_was_blank = True
                last_size = None
            continue

        is_mono = bool(flags and (flags & 1 << 4))
        lvl = detect_heading_level(size, body_size)

        # Skip TOC heading duplication
        if stripped in toc_titles_on_page:
            continue

        if is_mono:
            # Monospace blocks: keep raw lines, fenced.
            if para_buf:
                flush_para()
            if not in_code:
                md_lines.append("```")
                in_code = True
            md_lines.append(text.rstrip())
            last_was_blank = False
            last_size = None
            continue
        else:
            if in_code:
                md_lines.append("```")
                in_code = False

        if lvl >= 1 and not is_bullet(stripped):
            flush_para()
            md_lines.append("#" * (lvl + 2) + " " + stripped)
            last_was_blank = False
            last_size = None
        elif is_bullet(stripped):
            flush_para()
            md_lines.append(stripped)
            last_was_blank = False
            last_size = None
        elif looks_like_table_row(stripped):
            flush_para()
            cells = [c.strip() for c in re.split(r" {2,}|\t", stripped) if c.strip()]
            md_lines.append("| " + " | ".join(cells) + " |")
            last_was_blank = False
            last_size = None
        else:
            # Body paragraph: merge with previous if same size/flags.
            if (last_size is not None
                    and abs(last_size - size) < 0.6
                    and last_flags == flags
                    and not last_was_blank):
                para_buf.append(stripped)
            else:
                flush_para()
                para_buf.append(stripped)
            last_size = size
            last_flags = flags
            last_was_blank = False

    if in_code:
        md_lines.append("```")
    flush_para()

    return "\n".join(md_lines)


def build_toc_index(toc):
    """Map page_no (1-based) -> list of (level, title, page)."""
    idx = {}
    for lvl, title, pg in toc:
        idx.setdefault(pg, []).append((lvl, title, pg))
    return idx


def detect_running_header(doc, doc_name):
    """Find a short string that appears in the top strip of many pages –
    this is the running header used by technical PDFs."""
    from collections import Counter
    candidates = Counter()
    sample = min(doc.page_count, 20)
    step = max(1, doc.page_count // sample)
    pages = list(range(0, doc.page_count, step))[:sample]
    for pno in pages:
        page = doc[pno]
        h = page.rect.height
        for b in page.get_text("dict")["blocks"]:
            if b.get("type", 0) != 0:
                continue
            for ln in b["lines"]:
                if ln["bbox"][1] > h * 0.045:
                    continue
                text = "".join(sp["text"] for sp in ln["spans"]).strip()
                if text and len(text) < 60:
                    candidates[text] += 1
    if not candidates:
        return None
    text, count = candidates.most_common(1)[0]
    if count >= max(3, sample // 3):
        # Build a regex that matches this header text (escape special chars)
        return re.compile(re.escape(text))
    return None


def convert_pdf(pdf_path: str, out_dir: str):
    global doc
    doc = fitz.open(pdf_path)
    doc_name = os.path.splitext(os.path.basename(pdf_path))[0]
    doc_name_safe = slugify(doc_name)
    out_dir = os.path.join(out_dir, doc_name_safe)
    os.makedirs(out_dir, exist_ok=True)

    toc = doc.get_toc()
    toc_idx = build_toc_index(toc)
    running_header_re = detect_running_header(doc, doc_name_safe)
    if running_header_re:
        print("Detected running header:", running_header_re.pattern, file=sys.stderr)

    # Front matter: TOC list at the top
    parts = [f"# {doc_name}\n"]
    if toc:
        parts.append("## 目录 / Table of Contents\n")
        for lvl, title, pg in toc:
            parts.append(f"{'  ' * (lvl - 1)}- {title.strip()} (p.{pg})")
        parts.append("\n---\n")

    for page_no in range(doc.page_count):
        page = doc[page_no]
        page_md = build_page_md(page, page_no, out_dir, doc_name_safe,
                                toc_idx, running_header_re)
        parts.append(f"\n<!-- PAGE {page_no + 1} -->\n")
        parts.append(page_md)

    out_md = os.path.join(out_dir, doc_name_safe + ".md")
    with open(out_md, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print("Wrote:", out_md)
    doc.close()
    return out_md


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python extract_pdf.py <pdf> <out_dir>")
        sys.exit(1)
    convert_pdf(sys.argv[1], sys.argv[2])
