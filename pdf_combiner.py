"""PDF combining and cover-page generation logic."""

from __future__ import annotations

import io
import logging
import math
import os
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import BinaryIO, Iterable, Sequence

import pikepdf
from pypdf import PdfReader, PdfWriter
from pypdf.generic import NameObject, TextStringObject
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import letter
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


PAGE_WIDTH, PAGE_HEIGHT = letter
FIRST_PAGE_CAPACITY = 10
CONTINUATION_PAGE_CAPACITY = 15
LOGGER = logging.getLogger(__name__)


class CombineError(ValueError):
    """A user-facing validation error while preparing a combined PDF."""


@dataclass(frozen=True)
class SourceDocument:
    stream: BinaryIO
    filename: str
    title: str
    page_range: str = ""


@dataclass(frozen=True)
class DocumentInfo:
    filename: str
    title: str
    page_count: int
    start_page: int
    end_page: int


def _register_fonts() -> tuple[str, str]:
    """Use a Unicode TrueType font when available, then fall back safely."""
    candidates = [
        (
            Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/arial.ttf",
            Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/arialbd.ttf",
        ),
        (Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"), Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")),
        (Path("/Library/Fonts/Arial.ttf"), Path("/Library/Fonts/Arial Bold.ttf")),
    ]
    for regular, bold in candidates:
        if regular.exists() and bold.exists():
            try:
                pdfmetrics.registerFont(TTFont("CombinerSans", str(regular)))
                pdfmetrics.registerFont(TTFont("CombinerSans-Bold", str(bold)))
                return "CombinerSans", "CombinerSans-Bold"
            except Exception:
                pass
    return "Helvetica", "Helvetica-Bold"


FONT_REGULAR, FONT_BOLD = _register_fonts()


def _safe_name(name: str) -> str:
    clean = Path(name or "document.pdf").name.strip()
    return clean or "document.pdf"


def _clean_title(title: str, filename: str) -> str:
    value = (title or "").strip()
    if not value:
        value = Path(filename).stem
    return " ".join(value.split())[:240] or "Untitled document"


def _cover_page_count(document_count: int) -> int:
    if document_count <= FIRST_PAGE_CAPACITY:
        return 1
    return 1 + math.ceil((document_count - FIRST_PAGE_CAPACITY) / CONTINUATION_PAGE_CAPACITY)


def _page_range(start: int, end: int) -> str:
    return str(start) if start == end else f"{start}-{end}"


def parse_page_selection(selection: str, total_pages: int, filename: str = "PDF") -> tuple[int, ...]:
    """Parse a Windows print-dialog style page selection into zero-based indexes."""
    value = (selection or "").strip()
    if not value or value.lower() == "all":
        return tuple(range(total_pages))

    selected: list[int] = []
    seen: set[int] = set()
    for raw_part in value.split(","):
        part = raw_part.strip()
        if not part or not re.fullmatch(r"\d+(?:\s*-\s*\d+)?", part):
            raise CombineError(
                f'The page selection for {filename} is invalid. Use a format like "1-5,7,9,15-20".'
            )
        if "-" in part:
            start_text, end_text = re.split(r"\s*-\s*", part, maxsplit=1)
            start, end = int(start_text), int(end_text)
            if start > end:
                raise CombineError(f"The page range {part} for {filename} must go from low to high.")
            page_numbers = range(start, end + 1)
        else:
            page_numbers = (int(part),)

        for page_number in page_numbers:
            if page_number < 1 or page_number > total_pages:
                raise CombineError(
                    f"Page {page_number} is outside {filename}, which has {total_pages} page{'s' if total_pages != 1 else ''}."
                )
            index = page_number - 1
            if index not in seen:
                seen.add(index)
                selected.append(index)

    if not selected:
        raise CombineError(f"Choose at least one page from {filename}.")
    return tuple(selected)


def _ellipsize(value: str, max_chars: int = 68) -> str:
    if len(value) <= max_chars:
        return value
    return value[: max_chars - 3].rstrip() + "..."


def _draw_footer(pdf: canvas.Canvas, page_number: int, total_pages: int) -> None:
    pdf.setStrokeColor(HexColor("#D9DEE8"))
    pdf.setLineWidth(0.6)
    pdf.line(54, 42, PAGE_WIDTH - 54, 42)
    pdf.setFillColor(HexColor("#6C7380"))
    pdf.setFont(FONT_REGULAR, 8.5)
    pdf.drawString(54, 27, "COMBINED DOCUMENT")
    pdf.drawRightString(PAGE_WIDTH - 54, 27, f"{page_number} / {total_pages}")


def _draw_entries(
    pdf: canvas.Canvas,
    entries: Sequence[DocumentInfo],
    start_y: float,
    row_height: float = 34,
) -> None:
    for entry in entries:
        range_text = _page_range(entry.start_page, entry.end_page)
        title = _ellipsize(entry.title)
        baseline = start_y - 21

        pdf.setFillColor(HexColor("#F4F6F9"))
        pdf.roundRect(54, start_y - row_height + 3, PAGE_WIDTH - 108, row_height - 6, 5, fill=1, stroke=0)
        pdf.setFillColor(HexColor("#1E2633"))
        pdf.setFont(FONT_REGULAR, 10.5)
        pdf.drawString(68, baseline, title)
        pdf.setFillColor(HexColor("#7B8492"))
        pdf.setFont(FONT_REGULAR, 8)
        pdf.drawRightString(PAGE_WIDTH - 104, baseline, f"{entry.page_count} page{'s' if entry.page_count != 1 else ''}")
        pdf.setFillColor(HexColor("#123C69"))
        pdf.setFont(FONT_BOLD, 10)
        pdf.drawRightString(PAGE_WIDTH - 68, baseline, range_text)
        start_y -= row_height


def _create_cover(
    title: str,
    subtitle: str,
    entries: Sequence[DocumentInfo],
    total_output_pages: int,
) -> io.BytesIO:
    buffer = io.BytesIO()
    cover_pages = _cover_page_count(len(entries))
    pdf = canvas.Canvas(buffer, pagesize=letter, pageCompression=1)
    pdf.setTitle(title)
    pdf.setAuthor("PDF Combiner")

    # First cover page
    pdf.setFillColor(HexColor("#123C69"))
    pdf.rect(0, PAGE_HEIGHT - 188, PAGE_WIDTH, 188, fill=1, stroke=0)
    pdf.setFillColor(HexColor("#C9A54B"))
    pdf.rect(54, PAGE_HEIGHT - 66, 38, 4, fill=1, stroke=0)
    pdf.setFillColor(HexColor("#FFFFFF"))
    pdf.setFont(FONT_BOLD, 25)
    pdf.drawString(54, PAGE_HEIGHT - 108, _ellipsize(title, 40))
    if subtitle:
        pdf.setFillColor(HexColor("#D7E2EE"))
        pdf.setFont(FONT_REGULAR, 10.5)
        pdf.drawString(54, PAGE_HEIGHT - 132, _ellipsize(subtitle, 78))
    pdf.setFillColor(HexColor("#D7E2EE"))
    pdf.setFont(FONT_REGULAR, 8.5)
    pdf.drawString(54, PAGE_HEIGHT - 163, date.today().strftime("%B %d, %Y").replace(" 0", " "))

    pdf.setFillColor(HexColor("#1E2633"))
    pdf.setFont(FONT_BOLD, 13)
    pdf.drawString(54, PAGE_HEIGHT - 226, "CONTENTS")
    pdf.setFillColor(HexColor("#7B8492"))
    pdf.setFont(FONT_REGULAR, 8)
    pdf.drawRightString(PAGE_WIDTH - 68, PAGE_HEIGHT - 226, "PAGES")
    _draw_entries(pdf, entries[:FIRST_PAGE_CAPACITY], PAGE_HEIGHT - 244)
    _draw_footer(pdf, 1, total_output_pages)

    remaining = list(entries[FIRST_PAGE_CAPACITY:])
    cover_page_number = 2
    while remaining:
        pdf.showPage()
        pdf.setFillColor(HexColor("#123C69"))
        pdf.rect(0, PAGE_HEIGHT - 92, PAGE_WIDTH, 92, fill=1, stroke=0)
        pdf.setFillColor(HexColor("#C9A54B"))
        pdf.rect(54, PAGE_HEIGHT - 48, 26, 3, fill=1, stroke=0)
        pdf.setFillColor(HexColor("#FFFFFF"))
        pdf.setFont(FONT_BOLD, 17)
        pdf.drawString(54, PAGE_HEIGHT - 70, "CONTENTS - CONTINUED")
        page_entries = remaining[:CONTINUATION_PAGE_CAPACITY]
        remaining = remaining[CONTINUATION_PAGE_CAPACITY:]
        _draw_entries(pdf, page_entries, PAGE_HEIGHT - 124, row_height=38)
        _draw_footer(pdf, cover_page_number, total_output_pages)
        cover_page_number += 1

    pdf.save()
    buffer.seek(0)
    assert cover_page_number - 1 == cover_pages
    return buffer


def _read_pdf(data: bytes, filename: str) -> tuple[PdfReader, int]:
    reader = PdfReader(io.BytesIO(data), strict=False)
    if reader.is_encrypted:
        try:
            unlocked = reader.decrypt("")
        except Exception as exc:
            raise CombineError(f"{filename} is password protected.") from exc
        if not unlocked:
            raise CombineError(f"{filename} is password protected.")
    return reader, len(reader.pages)


def _repair_pdf(data: bytes, filename: str) -> tuple[PdfReader, int]:
    """Normalize a malformed but viewable PDF, then reopen it with pypdf."""
    try:
        document = pikepdf.open(io.BytesIO(data), attempt_recovery=True)
    except pikepdf.PasswordError as exc:
        raise CombineError(f"{filename} is password protected.") from exc
    with document:
        if len(document.pages) == 0:
            raise CombineError(f"{filename} has no pages.")
        repaired = io.BytesIO()
        document.save(repaired)
    return _read_pdf(repaired.getvalue(), filename)


def _namespace_form_fields(reader: PdfReader, prefix: str) -> None:
    """Prefix top-level field names so forms from different PDFs cannot collide."""
    acroform = reader.root_object.get("/AcroForm")
    if not acroform or "/Fields" not in acroform:
        return
    for position, field_reference in enumerate(acroform["/Fields"], start=1):
        field = field_reference.get_object()
        current_name = str(field.get("/T", "")).strip()
        suffix = current_name or f"field_{position}"
        field[NameObject("/T")] = TextStringObject(f"{prefix}.{suffix}")


def inspect_sources(
    sources: Iterable[SourceDocument],
) -> tuple[list[tuple[SourceDocument, PdfReader, tuple[int, ...]]], int]:
    inspected: list[tuple[SourceDocument, PdfReader, tuple[int, ...]]] = []
    total_pages = 0
    for index, source in enumerate(sources, start=1):
        filename = _safe_name(source.filename)
        data = b""
        try:
            source.stream.seek(0)
            data = source.stream.read()
            reader, page_count = _read_pdf(data, filename)
        except CombineError:
            raise
        except Exception as primary_error:
            LOGGER.warning("Primary reader rejected %s; attempting automatic repair: %s", filename, primary_error)
            try:
                reader, page_count = _repair_pdf(data, filename)
            except CombineError:
                raise
            except Exception as repair_error:
                raise CombineError(
                    f"{filename} could not be decoded, even after automatic repair. "
                    "Try opening it and using Print to PDF, then add the new copy."
                ) from repair_error
        if page_count == 0:
            raise CombineError(f"{filename} has no pages.")
        selected_pages = parse_page_selection(source.page_range, page_count, filename)
        inspected.append((source, reader, selected_pages))
        total_pages += len(selected_pages)
    if not inspected:
        raise CombineError("Choose at least one PDF to combine.")
    return inspected, total_pages


def combine_documents(
    sources: Sequence[SourceDocument],
    *,
    include_cover: bool = True,
    document_title: str = "Combined document",
    subtitle: str = "",
) -> tuple[io.BytesIO, list[DocumentInfo]]:
    """Combine sources, optionally adding a generated cover and TOC."""
    inspected, source_page_total = inspect_sources(sources)
    title = " ".join((document_title or "Combined document").split())[:160] or "Combined document"
    subtitle = " ".join((subtitle or "").split())[:240]
    cover_pages = _cover_page_count(len(inspected)) if include_cover else 0

    infos: list[DocumentInfo] = []
    next_page = cover_pages + 1
    for source, reader, selected_pages in inspected:
        count = len(selected_pages)
        filename = _safe_name(source.filename)
        info = DocumentInfo(
            filename=filename,
            title=_clean_title(source.title, filename),
            page_count=count,
            start_page=next_page,
            end_page=next_page + count - 1,
        )
        infos.append(info)
        next_page += count

    writer = PdfWriter()
    total_output_pages = source_page_total + cover_pages
    if include_cover:
        cover = PdfReader(_create_cover(title, subtitle, infos, total_output_pages))
        for page in cover.pages:
            writer.add_page(page)

    for source_number, (info, (_, reader, selected_pages)) in enumerate(zip(infos, inspected), start=1):
        # Keep AcroForm fields and widget annotations together. A unique top-level
        # name prevents identically named fields from separate PDFs from sharing
        # (and potentially overwriting) each other's values.
        _namespace_form_fields(reader, f"source_{source_number}")
        writer.append(
            reader,
            outline_item=info.title,
            pages=list(selected_pages),
            import_outline=False,
        )

    writer.add_metadata(
        {
            "/Title": title,
            "/Author": "PDF Combiner",
            "/Subject": f"Combined from {len(infos)} PDF document(s)",
        }
    )
    output = io.BytesIO()
    writer.write(output)
    output.seek(0)
    return output, infos
