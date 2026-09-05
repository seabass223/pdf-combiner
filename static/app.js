const fileInput = document.querySelector("#file-input");
const dropZone = document.querySelector("#drop-zone");
const fileList = document.querySelector("#file-list");
const addMore = document.querySelector("#add-more");
const pageRangeHelp = document.querySelector("#page-range-help");
const fileCount = document.querySelector("#file-count");
const combineButton = document.querySelector("#combine-button");
const includeCover = document.querySelector("#include-cover");
const coverFields = document.querySelector("#cover-fields");
const status = document.querySelector("#status");

let documents = [];

function humanSize(bytes) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function defaultTitle(filename) {
  return filename.replace(/\.pdf$/i, "").replace(/[_-]+/g, " ").replace(/\s+/g, " ").trim();
}

function addFiles(files) {
  const rejected = [];
  [...files].forEach((file) => {
    if (!file.name.toLowerCase().endsWith(".pdf")) rejected.push(file.name);
    else documents.push({ id: crypto.randomUUID(), file, title: defaultTitle(file.name), pageRange: "" });
  });
  render();
  if (rejected.length) showStatus(`Skipped non-PDF file${rejected.length > 1 ? "s" : ""}: ${rejected.join(", ")}`, true);
}

function render() {
  fileList.innerHTML = "";
  documents.forEach((doc) => {
    const row = document.createElement("div");
    row.className = "file-card";
    row.draggable = true;
    row.dataset.id = doc.id;
    row.innerHTML = `
      <span class="drag-handle" title="Drag to reorder">⠿</span>
      <div class="file-data">
        <div class="file-fields">
          <label class="title-control"><span>Contents title</span><input class="title-input" aria-label="Table of contents title" maxlength="240"></label>
          <label class="pages-control"><span>Pages</span><input class="pages-input" aria-label="Pages to include" inputmode="numeric" placeholder="All pages"></label>
        </div>
        <div class="file-meta"></div>
      </div>
      <button class="remove" type="button" aria-label="Remove file">×</button>`;
    const title = row.querySelector(".title-input");
    title.value = doc.title;
    title.addEventListener("input", () => { doc.title = title.value; });
    const pageRange = row.querySelector(".pages-input");
    pageRange.value = doc.pageRange;
    pageRange.addEventListener("input", () => { doc.pageRange = pageRange.value; });
    row.querySelector(".file-meta").textContent = `${doc.file.name} · ${humanSize(doc.file.size)}`;
    row.querySelector(".remove").addEventListener("click", () => {
      documents = documents.filter((item) => item.id !== doc.id);
      render();
    });
    row.addEventListener("dragstart", () => row.classList.add("dragging"));
    row.addEventListener("dragend", () => row.classList.remove("dragging"));
    fileList.append(row);
  });
  const count = documents.length;
  fileCount.textContent = `${count} file${count === 1 ? "" : "s"}`;
  dropZone.hidden = count > 0;
  pageRangeHelp.hidden = count === 0;
  addMore.hidden = count === 0;
  combineButton.disabled = count === 0;
}

fileList.addEventListener("dragover", (event) => {
  event.preventDefault();
  const dragging = fileList.querySelector(".dragging");
  if (!dragging) return;
  const siblings = [...fileList.querySelectorAll(".file-card:not(.dragging)")];
  const next = siblings.find((item) => event.clientY <= item.getBoundingClientRect().top + item.offsetHeight / 2);
  fileList.insertBefore(dragging, next || null);
});

fileList.addEventListener("drop", () => {
  const order = [...fileList.querySelectorAll(".file-card")].map((row) => row.dataset.id);
  documents.sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
});

["dragenter", "dragover"].forEach((eventName) => dropZone.addEventListener(eventName, (event) => {
  event.preventDefault(); dropZone.classList.add("dragging");
}));
["dragleave", "drop"].forEach((eventName) => dropZone.addEventListener(eventName, (event) => {
  event.preventDefault(); dropZone.classList.remove("dragging");
}));
dropZone.addEventListener("drop", (event) => addFiles(event.dataTransfer.files));
fileInput.addEventListener("change", () => { addFiles(fileInput.files); fileInput.value = ""; });
addMore.addEventListener("click", () => fileInput.click());
includeCover.addEventListener("change", () => coverFields.classList.toggle("hidden", !includeCover.checked));

function showStatus(message, isError = false) {
  status.textContent = message;
  status.className = `status ${isError ? "error" : ""}`;
}

function filenameFromHeader(header) {
  const match = /filename="([^"]+)"/i.exec(header || "");
  return match ? match[1] : "combined-document.pdf";
}

combineButton.addEventListener("click", async () => {
  if (!documents.length) return;
  combineButton.disabled = true;
  combineButton.classList.add("loading");
  combineButton.querySelector("span").textContent = "Combining...";
  showStatus("Reading pages and building your document...");
  const form = new FormData();
  documents.forEach((doc) => form.append("files", doc.file, doc.file.name));
  form.append("titles", JSON.stringify(documents.map((doc) => doc.title)));
  form.append("page_ranges", JSON.stringify(documents.map((doc) => doc.pageRange)));
  form.append("include_cover", String(includeCover.checked));
  form.append("document_title", document.querySelector("#document-title").value);
  form.append("subtitle", document.querySelector("#subtitle").value);
  form.append("output_name", document.querySelector("#output-name").value);

  try {
    const response = await fetch("/combine", { method: "POST", body: form });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({}));
      throw new Error(payload.error || "The PDFs could not be combined.");
    }
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filenameFromHeader(response.headers.get("Content-Disposition"));
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    status.textContent = `Done - ${documents.length} PDF${documents.length === 1 ? "" : "s"} combined.`;
    status.className = "status success";
  } catch (error) {
    showStatus(error.message, true);
  } finally {
    combineButton.disabled = false;
    combineButton.classList.remove("loading");
    combineButton.querySelector("span").textContent = "Combine PDFs";
  }
});
