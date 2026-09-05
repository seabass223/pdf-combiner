# PDF Combiner

![example](example.png)

A private, local web application for merging PDFs in a chosen order. It can add a designed cover page with a table of contents and accurate page ranges for every source document.

## Features

- Drag and drop multiple PDF files
- Reorder documents before combining
- Rename table-of-contents entries
- Select pages from each PDF with Windows printer syntax such as `1-5,7,9,15-20` (blank means all pages)
- Optional cover and multi-page table of contents
- Accurate page ranges that include the generated cover pages
- PDF bookmarks for quick navigation
- Original source page sizes and orientations are preserved
- Files are processed in memory and are not stored by the app

## Run locally

Requires Python 3.10 or newer.

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
python -m pip install -r requirements.txt
python app.py
```

Then open [http://127.0.0.1:8080](http://127.0.0.1:8080).

## Test

```powershell
python -m unittest discover -s tests -v
```

The upload limit is 500 MB per request and can be changed in `app.py`.
