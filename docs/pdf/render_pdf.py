#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Render Chinese translated markdown to PDF with:
- Body text at 10.5pt (五号字体)
- Auto-generated chapter table of contents
- Continuous page numbers
"""

import os
import re
import sys
import html as html_module

from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import cm, mm
from reportlab.lib.colors import HexColor, black, white, grey, lightgrey
from reportlab.lib.enums import TA_LEFT, TA_CENTER, TA_JUSTIFY
from reportlab.platypus import (
    BaseDocTemplate, PageTemplate, Frame,
    Paragraph, Spacer, PageBreak, KeepTogether,
    Table, TableStyle, Image as RLImage, ListFlowable, ListItem,
    Preformatted, Flowable
)
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus.tableofcontents import TableOfContents

# ─── Font Registration ───────────────────────────────────────────────
FONTS_DIR = r"C:\Windows\Fonts"

# SimSun (宋体) for body text - TTC file, index 0
pdfmetrics.registerFont(TTFont("SimSun", os.path.join(FONTS_DIR, "simsun.ttc"), subfontIndex=0))
# SimHei (黑体) for headings
pdfmetrics.registerFont(TTFont("SimHei", os.path.join(FONTS_DIR, "simhei.ttf")))
# Consolas for code blocks
pdfmetrics.registerFont(TTFont("Consolas", os.path.join(FONTS_DIR, "consola.ttf")))
# Microsoft YaHei for TOC
pdfmetrics.registerFont(TTFont("YaHei", os.path.join(FONTS_DIR, "msyh.ttc"), subfontIndex=0))

# ─── Constants ───────────────────────────────────────────────────────
BODY_FONT = "SimSun"
HEADING_FONT = "SimHei"
CODE_FONT = "Consolas"
TOC_FONT = "SimSun"

BODY_SIZE = 10.5  # 五号字体 = 10.5pt
CODE_SIZE = 9.5
TOC_SIZE = 10.5

PAGE_W, PAGE_H = A4
MARGIN_L = 2.5 * cm
MARGIN_R = 2.5 * cm
MARGIN_T = 2.5 * cm
MARGIN_B = 2.5 * cm

# ─── Styles ──────────────────────────────────────────────────────────
def make_styles():
    styles = {}
    styles["Title"] = ParagraphStyle(
        "Title", fontName=HEADING_FONT, fontSize=22, leading=30,
        alignment=TA_CENTER, spaceBefore=10, spaceAfter=20, textColor=black
    )
    styles["Heading1"] = ParagraphStyle(
        "Heading1", fontName=HEADING_FONT, fontSize=18, leading=26,
        spaceBefore=18, spaceAfter=12, textColor=HexColor("#1a1a1a")
    )
    styles["Heading2"] = ParagraphStyle(
        "Heading2", fontName=HEADING_FONT, fontSize=15, leading=22,
        spaceBefore=14, spaceAfter=8, textColor=HexColor("#222222")
    )
    styles["Heading3"] = ParagraphStyle(
        "Heading3", fontName=HEADING_FONT, fontSize=12.5, leading=18,
        spaceBefore=10, spaceAfter=6, textColor=HexColor("#333333")
    )
    styles["Heading4"] = ParagraphStyle(
        "Heading4", fontName=HEADING_FONT, fontSize=11, leading=16,
        spaceBefore=8, spaceAfter=4, textColor=HexColor("#444444")
    )
    styles["Heading5"] = ParagraphStyle(
        "Heading5", fontName=HEADING_FONT, fontSize=BODY_SIZE, leading=15,
        spaceBefore=6, spaceAfter=3, textColor=HexColor("#555555")
    )
    styles["Body"] = ParagraphStyle(
        "Body", fontName=BODY_FONT, fontSize=BODY_SIZE, leading=BODY_SIZE * 1.6,
        spaceBefore=2, spaceAfter=4, alignment=TA_JUSTIFY, firstLineIndent=0
    )
    styles["Code"] = ParagraphStyle(
        "Code", fontName=CODE_FONT, fontSize=CODE_SIZE, leading=CODE_SIZE * 1.4,
        spaceBefore=4, spaceAfter=4, leftIndent=10, rightIndent=10,
        backColor=HexColor("#f5f5f5"), borderColor=HexColor("#dddddd"),
        borderWidth=0.5, borderPadding=4
    )
    styles["TableHeader"] = ParagraphStyle(
        "TableHeader", fontName=HEADING_FONT, fontSize=BODY_SIZE, leading=14,
        textColor=white, alignment=TA_CENTER
    )
    styles["TableCell"] = ParagraphStyle(
        "TableCell", fontName=BODY_FONT, fontSize=BODY_SIZE, leading=14,
        alignment=TA_LEFT
    )
    styles["TOCTitle"] = ParagraphStyle(
        "TOCTitle", fontName=HEADING_FONT, fontSize=18, leading=26,
        spaceBefore=10, spaceAfter=14, alignment=TA_CENTER
    )
    styles["TOC1"] = ParagraphStyle(
        "TOC1", fontName=HEADING_FONT, fontSize=BODY_SIZE, leading=18,
        leftIndent=0, spaceBefore=3
    )
    styles["TOC2"] = ParagraphStyle(
        "TOC2", fontName=BODY_FONT, fontSize=BODY_SIZE, leading=16,
        leftIndent=20, spaceBefore=1
    )
    styles["TOC3"] = ParagraphStyle(
        "TOC3", fontName=BODY_FONT, fontSize=9.5, leading=14,
        leftIndent=40, spaceBefore=0
    )
    styles["ImageCaption"] = ParagraphStyle(
        "ImageCaption", fontName=BODY_FONT, fontSize=9, leading=12,
        alignment=TA_CENTER, spaceBefore=2, spaceAfter=6, textColor=grey
    )
    return styles


# ─── Inline Markdown Formatting ──────────────────────────────────────
def escape_xml(text):
    """Escape XML special characters."""
    text = text.replace("&", "&amp;")
    text = text.replace("<", "&lt;")
    text = text.replace(">", "&gt;")
    return text


def md_inline_to_rl(text):
    """Convert inline markdown formatting to ReportLab HTML."""
    # Escape XML first
    text = escape_xml(text)
    
    # Inline code: `code` -> <font name="Consolas">code</font>
    text = re.sub(r'`([^`]+)`', r'<font name="Consolas">\1</font>', text)
    
    # Bold: **text** -> <b>text</b>
    text = re.sub(r'\*\*([^*]+)\*\*', r'<b>\1</b>', text)
    
    # Italic: *text* -> <i>text</i>  (but not ** which is bold)
    text = re.sub(r'(?<!\*)\*([^*]+)\*(?!\*)', r'<i>\1</i>', text)
    
    # Links: [text](url) -> text (just keep the text for simplicity)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    
    return text


# ─── Markdown Parser ─────────────────────────────────────────────────
class MarkdownParser:
    """Parse markdown into ReportLab flowables."""
    
    def __init__(self, styles, base_dir):
        self.styles = styles
        self.base_dir = base_dir
        self.flowables = []
        self.heading_counter = 0
    
    def parse(self, md_text):
        lines = md_text.split("\n")
        i = 0
        
        # Skip the manual TOC section (everything before the first <!-- PAGE 1 --> or first # heading after TOC)
        toc_end = self._find_content_start(lines)
        if toc_end > 0:
            lines = lines[toc_end:]
        
        while i < len(lines):
            line = lines[i]
            
            # Skip HTML comments
            if line.strip().startswith("<!--") and line.strip().endswith("-->"):
                i += 1
                continue
            
            # Skip horizontal rules (---)
            if line.strip() == "---":
                i += 1
                continue
            
            # Headings
            m = re.match(r'^(#{1,5})\s+(.+)$', line)
            if m:
                level = len(m.group(1))
                text = m.group(2).strip()
                self._add_heading(level, text)
                i += 1
                continue
            
            # Code blocks
            if line.strip().startswith("```"):
                code_lines = []
                i += 1
                while i < len(lines) and not lines[i].strip().startswith("```"):
                    code_lines.append(lines[i])
                    i += 1
                i += 1  # skip closing ```
                self._add_code_block(code_lines)
                continue
            
            # Tables
            if line.strip().startswith("|") and i + 1 < len(lines) and re.match(r'^\s*\|[\s\-:|]+\|?\s*$', lines[i+1]):
                table_lines = [line]
                i += 1
                while i < len(lines) and lines[i].strip().startswith("|"):
                    table_lines.append(lines[i])
                    i += 1
                self._add_table(table_lines)
                continue
            
            # Images
            m = re.match(r'^!\[([^\]]*)\]\(([^)]+)\)\s*$', line.strip())
            if m:
                alt = m.group(1)
                img_path = m.group(2)
                self._add_image(img_path, alt)
                i += 1
                continue
            
            # Bullet lists
            if re.match(r'^[\s]*[-*]\s+', line):
                list_items = []
                while i < len(lines) and re.match(r'^[\s]*[-*]\s+', lines[i]):
                    item_text = re.sub(r'^[\s]*[-*]\s+', '', lines[i])
                    list_items.append(md_inline_to_rl(item_text))
                    i += 1
                self._add_bullet_list(list_items)
                continue
            
            # Numbered lists
            if re.match(r'^[\s]*\d+\.\s+', line):
                list_items = []
                while i < len(lines) and re.match(r'^[\s]*\d+\.\s+', lines[i]):
                    item_text = re.sub(r'^[\s]*\d+\.\s+', '', lines[i])
                    list_items.append(md_inline_to_rl(item_text))
                    i += 1
                self._add_numbered_list(list_items)
                continue
            
            # Regular paragraph (non-empty lines)
            if line.strip():
                para_lines = [line]
                i += 1
                while i < len(lines) and lines[i].strip() and not self._is_block_start(lines[i]):
                    para_lines.append(lines[i])
                    i += 1
                text = " ".join(l.strip() for l in para_lines)
                self._add_paragraph(text)
                continue
            
            # Empty line
            i += 1
        
        return self.flowables
    
    def _find_content_start(self, lines):
        """Find where the actual content starts (after the manual TOC)."""
        # Look for the first <!-- PAGE 1 --> marker
        for i, line in enumerate(lines):
            if "<!-- PAGE 1 -->" in line:
                return i
        # If not found, look for the first # heading after line 10
        for i, line in enumerate(lines):
            if i > 10 and re.match(r'^#\s+', line):
                return i
        return 0
    
    def _is_block_start(self, line):
        """Check if a line starts a new block element."""
        if line.strip().startswith("#"):
            return True
        if line.strip().startswith("```"):
            return True
        if line.strip().startswith("|"):
            return True
        if re.match(r'^!\[', line.strip()):
            return True
        if re.match(r'^[\s]*[-*]\s+', line):
            return True
        if re.match(r'^[\s]*\d+\.\s+', line):
            return True
        if line.strip().startswith("<!--"):
            return True
        return False
    
    def _add_heading(self, level, text):
        style_name = f"Heading{min(level, 5)}"
        style = self.styles[style_name]
        text_rl = md_inline_to_rl(text)
        para = Paragraph(text_rl, style)
        
        # Add bookmark and TOC entry
        self.heading_counter += 1
        key = f"heading_{self.heading_counter}"
        para._bookmarkName = key
        
        self.flowables.append(para)
        
        # Notify TOC (level must be 0-based for TableOfContents)
        # We only add levels 1-3 to the TOC
        if level <= 3:
            # We'll use afterFlowable in the doc template instead
            pass
    
    def _add_code_block(self, code_lines):
        code_text = "\n".join(code_lines)
        # Use Preformatted for code blocks
        pre = Preformatted(code_text, self.styles["Code"])
        self.flowables.append(pre)
        self.flowables.append(Spacer(1, 3))
    
    def _add_table(self, table_lines):
        """Parse markdown table lines and create a ReportLab Table."""
        rows = []
        for i, line in enumerate(table_lines):
            if re.match(r'^\s*\|[\s\-:|]+\|?\s*$', line):
                continue  # skip separator line
            # Split by | and clean up
            cells = line.strip().split("|")
            # Remove empty first/last cells from leading/trailing |
            if cells and cells[0].strip() == "":
                cells = cells[1:]
            if cells and cells[-1].strip() == "":
                cells = cells[:-1]
            cells = [c.strip() for c in cells]
            rows.append(cells)
        
        if not rows:
            return
        
        # Determine column count
        n_cols = max(len(r) for r in rows)
        
        # Pad rows to have same number of columns
        for r in rows:
            while len(r) < n_cols:
                r.append("")
        
        # Create paragraph cells
        rl_rows = []
        for row_idx, row in enumerate(rows):
            rl_cells = []
            for cell in row:
                if row_idx == 0:
                    # Header row
                    p = Paragraph(md_inline_to_rl(cell), self.styles["TableHeader"])
                else:
                    p = Paragraph(md_inline_to_rl(cell), self.styles["TableCell"])
                rl_cells.append(p)
            rl_rows.append(rl_cells)
        
        # Calculate column widths
        avail_width = PAGE_W - MARGIN_L - MARGIN_R
        col_width = avail_width / n_cols
        col_widths = [col_width] * n_cols
        
        t = Table(rl_rows, colWidths=col_widths, repeatRows=1)
        t.setStyle(TableStyle([
            # Header
            ("BACKGROUND", (0, 0), (-1, 0), HexColor("#4472C4")),
            ("TEXTCOLOR", (0, 0), (-1, 0), white),
            ("FONTNAME", (0, 0), (-1, 0), HEADING_FONT),
            ("FONTSIZE", (0, 0), (-1, 0), BODY_SIZE),
            ("ALIGN", (0, 0), (-1, 0), "CENTER"),
            # Body
            ("FONTNAME", (0, 1), (-1, -1), BODY_FONT),
            ("FONTSIZE", (0, 1), (-1, -1), BODY_SIZE),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            # Grid
            ("GRID", (0, 0), (-1, -1), 0.5, HexColor("#999999")),
            # Alternating row colors
            ("ROWBACKGROUNDS", (0, 1), (-1, -1), [white, HexColor("#f0f0f0")]),
            # Padding
            ("TOPPADDING", (0, 0), (-1, -1), 4),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ("LEFTPADDING", (0, 0), (-1, -1), 6),
            ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ]))
        
        self.flowables.append(t)
        self.flowables.append(Spacer(1, 6))
    
    def _add_image(self, img_path, alt_text):
        """Add an image to the flowables."""
        # Resolve path relative to the markdown file's directory
        full_path = os.path.join(self.base_dir, img_path)
        if not os.path.exists(full_path):
            # Try without the relative prefix
            full_path = img_path
        
        if not os.path.exists(full_path):
            # Add a placeholder
            self.flowables.append(Paragraph(f"[图片未找到: {img_path}]", self.styles["ImageCaption"]))
            return
        
        try:
            # Calculate max width
            avail_width = PAGE_W - MARGIN_L - MARGIN_R
            img = RLImage(full_path)
            
            # Scale to fit
            img_w, img_h = img.drawWidth, img.drawHeight
            if img_w > avail_width:
                ratio = avail_width / img_w
                img.drawWidth = avail_width
                img.drawHeight = img_h * ratio
            
            # Limit height to avoid overflow
            max_height = PAGE_H - MARGIN_T - MARGIN_B - 4 * cm
            if img.drawHeight > max_height:
                ratio = max_height / img.drawHeight
                img.drawHeight = max_height
                img.drawWidth = img_w * ratio
            
            self.flowables.append(img)
            if alt_text and alt_text != "image":
                self.flowables.append(Paragraph(alt_text, self.styles["ImageCaption"]))
            else:
                self.flowables.append(Spacer(1, 6))
        except Exception as e:
            self.flowables.append(Paragraph(f"[图片加载失败: {img_path} - {e}]", self.styles["ImageCaption"]))
    
    def _add_bullet_list(self, items):
        """Add a bullet list."""
        list_items = []
        for item in items:
            p = Paragraph(item, self.styles["Body"])
            list_items.append(ListItem(p, leftIndent=20, value="•"))
        
        lf = ListFlowable(
            list_items,
            bulletType="bullet",
            start="•",
            leftIndent=15,
            bulletFontName=BODY_FONT,
            bulletFontSize=BODY_SIZE,
        )
        self.flowables.append(lf)
        self.flowables.append(Spacer(1, 4))
    
    def _add_numbered_list(self, items):
        """Add a numbered list."""
        list_items = []
        for item in items:
            p = Paragraph(item, self.styles["Body"])
            list_items.append(ListItem(p, leftIndent=20))
        
        lf = ListFlowable(
            list_items,
            bulletType="1",
            leftIndent=15,
            bulletFontName=BODY_FONT,
            bulletFontSize=BODY_SIZE,
        )
        self.flowables.append(lf)
        self.flowables.append(Spacer(1, 4))
    
    def _add_paragraph(self, text):
        """Add a regular paragraph."""
        text_rl = md_inline_to_rl(text)
        para = Paragraph(text_rl, self.styles["Body"])
        self.flowables.append(para)


# ─── PDF Document Template ───────────────────────────────────────────
class PDFDocTemplate(BaseDocTemplate):
    """Custom document template with TOC support and page numbers."""
    
    def __init__(self, filename, **kw):
        BaseDocTemplate.__init__(self, filename, **kw)
        self._heading_counter = 0
        
        # Main content frame
        frame = Frame(
            MARGIN_L, MARGIN_B,
            PAGE_W - MARGIN_L - MARGIN_R,
            PAGE_H - MARGIN_T - MARGIN_B,
            id="main",
            leftPadding=0, rightPadding=0, topPadding=0, bottomPadding=0
        )
        
        template = PageTemplate(id="main", frames=frame, onPage=self._draw_page)
        self.addPageTemplates([template])
    
    def afterFlowable(self, flowable):
        """Called after each flowable is drawn. Used to collect TOC entries."""
        if isinstance(flowable, Paragraph):
            style_name = flowable.style.name
            if style_name.startswith("Heading"):
                # Extract heading level
                try:
                    level = int(style_name.replace("Heading", ""))
                except ValueError:
                    level = 1
                
                text = flowable.getPlainText()
                
                # Use id(flowable) as bookmark key - stable across multiBuild passes
                key = f"h{id(flowable)}"
                
                # Add bookmark
                self.canv.bookmarkPage(key)
                
                # Add TOC entry (level 0-based for TableOfContents)
                # Only include levels 1-3 in TOC
                if level <= 3:
                    self.notify("TOCEntry", (level - 1, text, self.page, key))
    
    def _draw_page(self, canvas, doc):
        """Draw page number in footer."""
        canvas.saveState()
        canvas.setFont(BODY_FONT, 9)
        page_num = canvas.getPageNumber()
        canvas.drawCentredString(PAGE_W / 2, 1.2 * cm, str(page_num))
        canvas.restoreState()


# ─── Main Rendering Function ─────────────────────────────────────────
def render_md_to_pdf(md_path, pdf_path, title=None):
    """Render a markdown file to PDF."""
    print(f"  Reading: {md_path}")
    with open(md_path, "r", encoding="utf-8") as f:
        md_text = f.read()
    
    if title is None:
        title = os.path.splitext(os.path.basename(md_path))[0]
    
    base_dir = os.path.dirname(md_path)
    styles = make_styles()
    
    # Create document
    doc = PDFDocTemplate(
        pdf_path,
        pagesize=A4,
        leftMargin=MARGIN_L, rightMargin=MARGIN_R,
        topMargin=MARGIN_T, bottomMargin=MARGIN_B,
        title=title,
    )
    
    # Build flowables
    story = []
    
    # Title page
    story.append(Spacer(1, 6 * cm))
    story.append(Paragraph(title, styles["Title"]))
    story.append(Spacer(1, 2 * cm))
    story.append(PageBreak())
    
    # Table of Contents
    story.append(Paragraph("目 录", styles["TOCTitle"]))
    story.append(Spacer(1, 0.5 * cm))
    
    toc = TableOfContents()
    toc.levelStyles = [styles["TOC1"], styles["TOC2"], styles["TOC3"]]
    toc.dotsMinLevel = 0
    story.append(toc)
    story.append(PageBreak())
    
    # Parse markdown and add content
    parser = MarkdownParser(styles, base_dir)
    content_flowables = parser.parse(md_text)
    story.extend(content_flowables)
    
    # Build PDF
    print(f"  Building PDF with {len(story)} flowables...")
    
    # Use multiBuild for TOC to work (needs 2 passes)
    doc.multiBuild(story)
    
    print(f"  Done: {pdf_path} ({os.path.getsize(pdf_path):,} bytes)")


# ─── Main ────────────────────────────────────────────────────────────
if __name__ == "__main__":
    base = r"j:\Work\BigWorld-Engine-14.4.1\docs\pdf\md_out"
    
    docs = [
        ("bigworld-technology-server-whitepaper", "bigworld-technology-server-whitepaper.zh.md",
         "BigWorld Technology Server Whitepaper（服务器白皮书）"),
        ("server-build-guide", "server-build-guide.zh.md",
         "Server Build Guide（服务器构建指南）"),
        ("server-installation-guide", "server-installation-guide.zh.md",
         "Server Installation Guide（服务器安装指南）"),
    ]
    
    for subdir, md_file, title in docs:
        md_path = os.path.join(base, subdir, md_file)
        pdf_path = os.path.join(base, subdir, md_file.replace(".zh.md", ".zh.pdf"))
        
        if not os.path.exists(md_path):
            print(f"SKIP (not found): {md_path}")
            continue
        
        print(f"\nRendering: {title}")
        try:
            render_md_to_pdf(md_path, pdf_path, title)
        except Exception as e:
            print(f"  ERROR: {e}")
            import traceback
            traceback.print_exc()
    
    print("\nAll done!")
