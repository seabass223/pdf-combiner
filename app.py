"""Local web application for combining PDF files."""

from __future__ import annotations

import json
import re
from pathlib import Path

from flask import Flask, Response, jsonify, render_template, request
from werkzeug.utils import secure_filename

from pdf_combiner import CombineError, SourceDocument, combine_documents


app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 500 * 1024 * 1024


def _download_name(value: str) -> str:
    stem = Path(value or "combined-document.pdf").stem
    stem = re.sub(r"[^A-Za-z0-9._ -]+", "", stem).strip(" .")
    return f"{stem or 'combined-document'}.pdf"


@app.get("/")
def index() -> str:
    return render_template("index.html")


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "app": "pdf-combiner"}


@app.post("/combine")
def combine() -> Response:
    uploads = request.files.getlist("files")
    if not uploads or not any(item.filename for item in uploads):
        return jsonify(error="Choose at least one PDF to combine."), 400

    try:
        titles = json.loads(request.form.get("titles", "[]"))
        page_ranges = json.loads(request.form.get("page_ranges", "[]"))
    except json.JSONDecodeError:
        return jsonify(error="The document options could not be read."), 400
    if not isinstance(titles, list) or not isinstance(page_ranges, list):
        return jsonify(error="The document options could not be read."), 400

    sources: list[SourceDocument] = []
    for index, upload in enumerate(uploads):
        filename = secure_filename(upload.filename or "document.pdf") or "document.pdf"
        if Path(filename).suffix.lower() != ".pdf":
            return jsonify(error=f"{filename} is not a PDF file."), 400
        title = str(titles[index]) if index < len(titles) else Path(filename).stem
        page_range = str(page_ranges[index]) if index < len(page_ranges) else ""
        sources.append(SourceDocument(upload.stream, filename, title, page_range))

    include_cover = request.form.get("include_cover", "true").lower() == "true"
    try:
        output, _ = combine_documents(
            sources,
            include_cover=include_cover,
            document_title=request.form.get("document_title", "Combined document"),
            subtitle=request.form.get("subtitle", ""),
        )
    except CombineError as exc:
        return jsonify(error=str(exc)), 400
    except Exception:
        app.logger.exception("Unexpected PDF combining error")
        return jsonify(error="The PDFs could not be combined. One of the files may be damaged."), 500

    filename = _download_name(request.form.get("output_name", "combined-document.pdf"))
    return Response(
        output.getvalue(),
        mimetype="application/pdf",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Cache-Control": "no-store",
        },
    )


@app.errorhandler(413)
def too_large(_error):
    return jsonify(error="The selected files are larger than the 500 MB upload limit."), 413


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080, debug=False)
