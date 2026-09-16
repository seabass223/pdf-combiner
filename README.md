# PDF Combiner

<img src="assets/pdf-combiner.png" alt="PDF Combiner icon" width="96">

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
- Preserves interactive form fields, checkbox values, and their visual states
- Original source page sizes and orientations are preserved
- Automatically repairs many malformed scanner/export PDFs that still open in ordinary viewers
- Files are processed in memory and are not stored by the app

## Run locally

On Windows, simply double-click the **`PDF Combiner`** shortcut. It has the navy-and-gold app icon and launches `Run PDF Combiner.cmd` for you.

If the shortcut is unavailable, double-click **`Run PDF Combiner.cmd`** directly.

It handles first-time setup, starts the app, and opens your browser automatically. There is no PowerShell activation step and no execution-policy setting to change. Keep the launcher window open while using the app; close it when finished.

Python 3.10 or newer is required. If Python is missing, the launcher will display a direct download link and explain what to do.

For command-line use on other operating systems, install `requirements.txt` in a virtual environment and run `python launcher.py`.

## Test

```powershell
python -m unittest discover -s tests -v
```

The upload limit is 500 MB per request and can be changed in `app.py`.
