import io
import unittest

from pypdf import PdfReader
from reportlab.lib.pagesizes import letter
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
