#!/usr/bin/env python3
"""Generate synthetic, redistributable PDF fixtures for the PoC.

No third-party Python packages and no private documents are used. Every PDF is
written from scratch with classic xref tables so the fixtures are deterministic
(apart from no timestamps at all) and safe to commit.

Usage: python3 fixtures/generate_fixtures.py [output-dir]
"""
from __future__ import annotations

import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))


class PDF:
    def __init__(self, version: str = "1.7"):
        self.version = version
        self.objects: list[bytes | None] = [None]  # 1-based
        self.info_obj = 1

    def add(self, body: bytes) -> int:
        self.objects.append(body)
        return len(self.objects) - 1

    def reserve(self) -> int:
        self.objects.append(None)
        return len(self.objects) - 1

    def set(self, num: int, body: bytes) -> None:
        self.objects[num] = body

    def stream(self, data: bytes, extra: bytes = b"") -> bytes:
        return (
            b"<< /Length " + str(len(data)).encode() + b" " + extra + b">>\nstream\n"
            + data + b"\nendstream"
        )

    def build(self) -> bytes:
        out = bytearray(b"%PDF-" + self.version.encode() + b"\n%\xe2\xe3\xcf\xd3\n")
        offsets = [0] * (len(self.objects))
        for num in range(1, len(self.objects)):
            offsets[num] = len(out)
            body = self.objects[num]
            if body is None:
                body = b"null"
            out += str(num).encode() + b" 0 obj\n" + body + b"\nendobj\n"
        xref = len(out)
        out += b"xref\n0 " + str(len(self.objects)).encode() + b"\n"
        out += b"0000000000 65535 f \n"
        for num in range(1, len(self.objects)):
            out += ("%010d 00000 n \n" % offsets[num]).encode()
        out += (
            b"trailer\n<< /Size " + str(len(self.objects)).encode()
            + b" /Root 1 0 R /Info " + str(self.info_obj).encode()
            + b" 0 R >>\nstartxref\n" + str(xref).encode() + b"\n%%EOF\n"
        )
        return bytes(out)


def esc(text: str) -> bytes:
    return text.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)").encode("latin-1", "replace")


def content(lines: list[str], start_y: int = 720, size: int = 12, font: bytes = b"/F1") -> bytes:
    out = bytearray(b"BT " + font + b" " + str(size).encode() + b" Tf 14 TL\n")
    out += b"1 0 0 1 72 " + str(start_y).encode() + b" Tm\n"
    for line in lines:
        out += b"(" + esc(line) + b") Tj T*\n"
    out += b"ET\n"
    return bytes(out)


def cjk_content(text: str) -> bytes:
    # A Type0 font with UniGB-UCS2-H takes UTF-16BE code units in a hex string.
    raw = text.encode("utf-16-be")
    out = bytearray(b"BT /F2 16 Tf 1 0 0 1 72 700 Tm\n")
    out += b"<" + raw.hex().upper().encode() + b"> Tj\nET\n"
    return bytes(out)


def add_annotations(pdf: PDF) -> list[int]:
    note = pdf.add(
        b"<< /Type /Annot /Subtype /Text /Rect [72 700 92 720] /F 0 "
        b"/C [1 1 0] /Name /Comment /T (A Previous Reader) /Contents (Pre-existing sticky note) >>"
    )
    highlight = pdf.add(
        b"<< /Type /Annot /Subtype /Highlight /Rect [72 660 320 678] "
        b"/QuadPoints [72 678 320 678 72 660 320 660] /C [1 1 0] /CA 0.4 "
        b"/T (A Previous Reader) /Contents (Pre-existing highlight) >>"
    )
    return [note, highlight]


def make(path: str, pages: list[dict], *, cjk: bool = False, annots: bool = False) -> str:
    pdf = PDF()
    root = pdf.reserve()                       # 1 catalog
    pages_obj = pdf.reserve()                  # 2 page tree
    font = pdf.add(b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    cjk_font = 0
    if cjk:
        cid = pdf.add(
            b"<< /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light "
            b"/CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 4 >> "
            b"/DW 1000 >>"
        )
        cjk_font = pdf.add(
            b"<< /Type /Font /Subtype /Type0 /BaseFont /STSong-Light "
            b"/Encoding /UniGB-UCS2-H /DescendantFonts [" + str(cid).encode() + b" 0 R] >>"
        )
    info = pdf.add(b"<< /Title (YoPDF PoC synthetic fixture) /Producer (YoPDF-Windows-PoC fixture generator) >>")
    pdf.info_obj = info

    ann_refs = add_annotations(pdf) if annots else []
    ann_arr = b" /Annots [" + b" ".join(str(r).encode() + b" 0 R" for r in ann_refs) + b"]" if ann_refs else b""

    kids = []
    for spec in pages:
        if "cjk" in spec:
            data = cjk_content(spec["cjk"])
        else:
            data = content(spec["lines"], spec.get("y", 720), spec.get("size", 12))
        contents = pdf.add(pdf.stream(data))
        resources = b"<< /Font << /F1 " + str(font).encode() + b" 0 R"
        if cjk_font:
            resources += b" /F2 " + str(cjk_font).encode() + b" 0 R"
        resources += b" >> >>"
        rotate = b" /Rotate " + str(spec["rotate"]).encode() if spec.get("rotate") else b""
        page_extra = ann_arr if spec.get("annots") else b""
        body = (
            b"<< /Type /Page /Parent " + str(pages_obj).encode() + b" 0 R "
            b"/MediaBox [0 0 612 792] /Resources " + resources
            + b" /Contents " + str(contents).encode() + b" 0 R" + rotate + page_extra + b" >>"
        )
        kids.append(pdf.add(body))

    pdf.set(root, b"<< /Type /Catalog /Pages " + str(pages_obj).encode() + b" 0 R >>")
    kids_b = b" ".join(str(k).encode() + b" 0 R" for k in kids)
    pdf.set(pages_obj, b"<< /Type /Pages /Kids [" + kids_b + b"] /Count " + str(len(kids)).encode() + b" >>")
    full = os.path.join(OUT, path)
    with open(full, "wb") as f:
        f.write(pdf.build())
    return full


def main() -> None:
    os.makedirs(OUT, exist_ok=True)
    made = []

    made.append(make("simple-text.pdf", [{
        "lines": [
            "YoPDF Windows PoC - simple text fixture.",
            "The quick brown fox jumps over the lazy dog.",
            "Search for the word ALPHA in this document.",
            "Another line containing ALPHA twice: ALPHA and ALPHA.",
            "Selection, highlight and sticky note all start here.",
        ]
    }]))

    made.append(make("multi-page.pdf", [
        {"lines": [f"Page {i + 1} of 12.", "A repeated term BETA appears on every page.",
                   "Continuous scrolling should keep the UI responsive."]}
        for i in range(12)
    ]))

    made.append(make("cjk-text.pdf", [
        {"lines": ["Chinese and Japanese text fixture."]},
        {"cjk": "中文测试：阅读、搜索、选择与高亮。日本語のテキストも含みます。"},
    ], cjk=True))

    made.append(make("rotated-pages.pdf", [
        {"lines": ["First page, no rotation.", "Rotation fixture ALPHA."], "rotate": 0},
        {"lines": ["Second page rotated 90 degrees.", "Rotation fixture ALPHA."], "rotate": 90},
        {"lines": ["Third page rotated 180 degrees."], "rotate": 180},
        {"lines": ["Fourth page rotated 270 degrees."], "rotate": 270},
    ]))

    made.append(make("existing-annotations.pdf", [
        {"lines": ["Pre-existing annotations must survive every edit.",
                   "Highlight this sentence: GAMMA DELTA EPSILON.",
                   "ALPHA appears here too."], "annots": True},
        {"lines": ["Second page has no annotations."]},
    ], annots=True))

    made.append(make("large-320p.pdf", [
        {"lines": [f"Large fixture - page {i + 1} of 320.",
                   "Paragraph one with the searchable token BETA.",
                   "Paragraph two keeps the content stream non-trivial for rendering.",
                   "Paragraph three: Lorem ipsum dolor sit amet, consectetur adipiscing elit."]}
        for i in range(320)
    ]))

    for p in made:
        print(f"{p}  {os.path.getsize(p)} bytes")


if __name__ == "__main__":
    main()
