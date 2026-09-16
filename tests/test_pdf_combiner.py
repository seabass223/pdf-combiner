import io
import re
import unittest

from PIL import Image
from pypdf import PdfReader
from reportlab.lib.pagesizes import letter
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen import canvas

from pdf_combiner import CombineError, SourceDocument, combine_documents, parse_page_selection


def sample_pdf(label: str, pages: int) -> io.BytesIO:
    stream = io.BytesIO()
    pdf = canvas.Canvas(stream, pagesize=letter)
    for number in range(1, pages + 1):
        pdf.setFont("Helvetica-Bold", 20)
        pdf.drawString(72, 700, label)
        pdf.setFont("Helvetica", 12)
        pdf.drawString(72, 675, f"Source page {number}")
        pdf.showPage()
    pdf.save()
    stream.seek(0)
    return stream


def image_only_pdf() -> io.BytesIO:
    image_stream = io.BytesIO()
    Image.new("RGB", (500, 700), "white").save(image_stream, format="PNG")
    image_stream.seek(0)
    pdf_stream = io.BytesIO()
    pdf = canvas.Canvas(pdf_stream, pagesize=letter)
    pdf.drawImage(ImageReader(image_stream), 56, 46, width=500, height=700)
    pdf.save()
    pdf_stream.seek(0)
    return pdf_stream


def checkbox_pdf(label: str, checked: bool) -> io.BytesIO:
    stream = io.BytesIO()
    pdf = canvas.Canvas(stream, pagesize=letter)
    pdf.setFont("Helvetica-Bold", 18)
    pdf.drawString(110, 700, label)
    pdf.acroForm.checkbox(
        name="approval",
        checked=checked,
        x=76,
        y=690,
        size=20,
        buttonStyle="check",
        forceBorder=True,
    )
    pdf.save()
    stream.seek(0)
    return stream


def two_page_checkbox_pdf() -> io.BytesIO:
    stream = io.BytesIO()
    pdf = canvas.Canvas(stream, pagesize=letter)
    for name, label in (("first", "First page"), ("second", "Second page")):
        pdf.drawString(110, 700, label)
        pdf.acroForm.checkbox(name=name, checked=True, x=76, y=690, size=20, forceBorder=True)
        pdf.showPage()
    pdf.save()
    stream.seek(0)
    return stream


def page_widgets(reader: PdfReader) -> list[tuple[object, object]]:
    widgets = []
    for page in reader.pages:
        for annotation_reference in page.get("/Annots", []):
            annotation = annotation_reference.get_object()
            if annotation.get("/Subtype") == "/Widget":
                parent_reference = annotation.get("/Parent")
                parent = parent_reference.get_object() if parent_reference else None
                widgets.append((annotation, parent))
    return widgets


class CombineTests(unittest.TestCase):
    def test_combines_in_order_with_cover_and_accurate_ranges(self):
        sources = [
            SourceDocument(sample_pdf("Alpha", 2), "alpha.pdf", "Alpha report"),
            SourceDocument(sample_pdf("Beta", 3), "beta.pdf", "Beta appendix"),
        ]
        output, infos = combine_documents(sources, document_title="Project book")
        reader = PdfReader(output)
        self.assertEqual(len(reader.pages), 6)
        self.assertEqual((infos[0].start_page, infos[0].end_page), (2, 3))
        self.assertEqual((infos[1].start_page, infos[1].end_page), (4, 6))
        cover_text = reader.pages[0].extract_text()
        self.assertIn("Project book", cover_text)
        self.assertIn("2-3", cover_text)
        self.assertIn("4-6", cover_text)

    def test_multi_page_cover_offsets_source_ranges(self):
        sources = [
            SourceDocument(sample_pdf(f"Document {n}", 1), f"document-{n}.pdf", f"Document {n}")
            for n in range(1, 27)
        ]
        output, infos = combine_documents(sources)
        self.assertEqual(len(PdfReader(output).pages), 29)
        self.assertEqual(infos[0].start_page, 4)
        self.assertEqual(infos[-1].end_page, 29)

    def test_can_combine_without_cover(self):
        output, infos = combine_documents(
            [SourceDocument(sample_pdf("Only", 2), "only.pdf", "Only")],
            include_cover=False,
        )
        self.assertEqual(len(PdfReader(output).pages), 2)
        self.assertEqual(infos[0].start_page, 1)

    def test_accepts_a_one_page_image_only_pdf(self):
        output, infos = combine_documents(
            [SourceDocument(image_only_pdf(), "scan.pdf", "Scanned page")],
            include_cover=False,
        )
        self.assertEqual(len(PdfReader(output).pages), 1)
        self.assertEqual(infos[0].page_count, 1)

    def test_automatically_repairs_a_broken_cross_reference(self):
        damaged = sample_pdf("Recoverable scan", 1).getvalue()
        damaged = re.sub(rb"(startxref\s*)\d+", rb"\g<1>999999", damaged)
        output, infos = combine_documents(
            [SourceDocument(io.BytesIO(damaged), "scanner-export.pdf", "Recovered scan")],
            include_cover=False,
        )
        reader = PdfReader(output)
        self.assertEqual(len(reader.pages), 1)
        self.assertIn("Recoverable scan", reader.pages[0].extract_text())
        self.assertEqual(infos[0].page_count, 1)

    def test_preserves_checkbox_values_appearances_and_interactivity(self):
        output, _ = combine_documents(
            [
                SourceDocument(checkbox_pdf("Approved", True), "approved.pdf", "Approved form"),
                SourceDocument(checkbox_pdf("Not approved", False), "pending.pdf", "Pending form"),
            ],
            include_cover=False,
        )
        reader = PdfReader(output)
        fields = reader.get_fields() or {}
        self.assertEqual(fields["source_1.approval"]["/V"], "/Yes")
        self.assertEqual(fields["source_2.approval"]["/V"], "/Off")

        widgets = page_widgets(reader)
        self.assertEqual(len(widgets), 2)
        self.assertEqual([widget.get("/AS") for widget, _ in widgets], ["/Yes", "/Off"])
        self.assertEqual([widget.get("/V") for widget, _ in widgets], ["/Yes", "/Off"])
        for widget, parent in widgets:
            effective_value = widget.get("/V") or (parent.get("/V") if parent else None)
            self.assertIn(effective_value, ("/Yes", "/Off"))
            self.assertIn("/AP", widget)
            self.assertIn("/N", widget["/AP"])
            self.assertGreater(len(widget["/AP"]["/N"]), 0)

    def test_page_selection_keeps_only_fields_from_selected_pages(self):
        output, _ = combine_documents(
            [SourceDocument(two_page_checkbox_pdf(), "two-pages.pdf", "Selected form page", "2")],
            include_cover=False,
        )
        reader = PdfReader(output)
        self.assertEqual(len(reader.pages), 1)
        self.assertEqual(set((reader.get_fields() or {}).keys()), {"source_1.second"})
        self.assertEqual(len(page_widgets(reader)), 1)

    def test_selects_requested_pages_and_updates_contents_range(self):
        output, infos = combine_documents(
            [SourceDocument(sample_pdf("Selected", 20), "selected.pdf", "Selected pages", "1-5,7,9,15-20")]
        )
        reader = PdfReader(output)
        self.assertEqual(len(reader.pages), 14)
        self.assertEqual(infos[0].page_count, 13)
        self.assertEqual((infos[0].start_page, infos[0].end_page), (2, 14))
        self.assertIn("Source page 15", reader.pages[8].extract_text())

    def test_page_selection_parser_handles_spaces_and_removes_duplicates(self):
        self.assertEqual(parse_page_selection("1 - 3, 3, 5", 5), (0, 1, 2, 4))

    def test_page_selection_parser_rejects_invalid_ranges(self):
        with self.assertRaisesRegex(CombineError, "low to high"):
            parse_page_selection("5-2", 5, "report.pdf")
        with self.assertRaisesRegex(CombineError, "invalid"):
            parse_page_selection("1-2;4", 5, "report.pdf")

    def test_rejects_empty_input(self):
        with self.assertRaisesRegex(CombineError, "at least one"):
            combine_documents([])


if __name__ == "__main__":
    unittest.main()
