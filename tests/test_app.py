import io
import json
import unittest

from pypdf import PdfReader
from reportlab.pdfgen import canvas

from app import app


def one_page_pdf() -> io.BytesIO:
    stream = io.BytesIO()
    pdf = canvas.Canvas(stream)
    pdf.drawString(72, 720, "Test document")
    pdf.save()
    stream.seek(0)
    return stream


class AppTests(unittest.TestCase):
    def setUp(self):
        app.config.update(TESTING=True)
        self.client = app.test_client()

    def test_health(self):
        self.assertEqual(self.client.get("/health").json, {"status": "ok", "app": "pdf-combiner"})

    def test_interface_explains_page_range_format(self):
        response = self.client.get("/")
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"Leave Pages blank for all pages", response.data)
        self.assertIn(b"1-5,7,9,15-20", response.data)

    def test_combine_download(self):
        response = self.client.post(
            "/combine",
            data={
                "files": [(one_page_pdf(), "first.pdf"), (one_page_pdf(), "second.pdf")],
                "titles": json.dumps(["First section", "Second section"]),
                "page_ranges": json.dumps(["1", ""]),
                "include_cover": "true",
                "document_title": "Test book",
                "output_name": "test-book",
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.mimetype, "application/pdf")
        self.assertIn('filename="test-book.pdf"', response.headers["Content-Disposition"])
        self.assertEqual(len(PdfReader(io.BytesIO(response.data)).pages), 3)

    def test_rejects_non_pdf_extension(self):
        response = self.client.post(
            "/combine",
            data={"files": (io.BytesIO(b"not a pdf"), "notes.txt"), "titles": "[]"},
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("not a PDF", response.json["error"])

    def test_reports_invalid_page_selection(self):
        response = self.client.post(
            "/combine",
            data={
                "files": (one_page_pdf(), "short.pdf"),
                "titles": "[]",
                "page_ranges": json.dumps(["1-3"]),
            },
            content_type="multipart/form-data",
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn("outside short.pdf", response.json["error"])


if __name__ == "__main__":
    unittest.main()
