"""Friendly Windows launcher for the local PDF Combiner web app."""

from __future__ import annotations

import argparse
import json
import threading
import time
import urllib.error
import urllib.request
import webbrowser

from werkzeug.serving import BaseWSGIServer, make_server

from app import app


HOST = "127.0.0.1"
DEFAULT_PORT = 8080
LAST_PORT = 8089


def app_url(port: int) -> str:
    return f"http://{HOST}:{port}"


def is_pdf_combiner_running(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"{app_url(port)}/health", timeout=0.35) as response:
            payload = json.loads(response.read().decode("utf-8"))
        return response.status == 200 and payload.get("app") == "pdf-combiner"
    except (OSError, ValueError, urllib.error.URLError):
        return False


def create_server(preferred_port: int = DEFAULT_PORT) -> tuple[BaseWSGIServer, int]:
    ports = [preferred_port] + [port for port in range(DEFAULT_PORT, LAST_PORT + 1) if port != preferred_port]
    for port in ports:
        try:
            return make_server(HOST, port, app, threaded=True), port
        except OSError:
            continue
    raise RuntimeError(f"No available port was found between {DEFAULT_PORT} and {LAST_PORT}.")


def open_browser_when_ready(port: int) -> None:
    url = app_url(port)
    for _ in range(50):
        if is_pdf_combiner_running(port):
            webbrowser.open(url)
            return
        time.sleep(0.1)


def main() -> int:
    parser = argparse.ArgumentParser(description="Start PDF Combiner and open it in your browser.")
    parser.add_argument("--check", action="store_true", help="Check installation without starting the server.")
    parser.add_argument("--no-browser", action="store_true", help="Do not open the browser automatically.")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.check:
        print("PDF Combiner is ready.")
        return 0

    if is_pdf_combiner_running(args.port):
        url = app_url(args.port)
        print(f"PDF Combiner is already running at {url}")
        if not args.no_browser:
            webbrowser.open(url)
        return 0

    try:
        server, port = create_server(args.port)
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        return 1

    url = app_url(port)
    print(f"PDF Combiner is ready at {url}")
    print("Press Ctrl+C or close this window to stop it.")

    if not args.no_browser:
        threading.Thread(target=open_browser_when_ready, args=(port,), daemon=True).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nPDF Combiner stopped.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

