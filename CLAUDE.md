# PDF Combiner

## Build
This project follows the Local Build Protocol (~/.claude/build-protocol/PROTOCOL.md).
Build only through `./build.sh` from Git Bash (`--target all`, `--run`, `--launch [--target <t>]`, `--pin`, `--info`);
output goes to `dist/`. Settings live in `build.config.json`. `build.sh` is a managed copy: don't edit it; change
build behaviour through the build-protocol agent.

Type `python`: the build creates the env with `devstore venv` if `.venv` is missing (a junction into A:), installs
`requirements.txt` with uv, and runs `launcher.py --check`. The Start Menu shortcut runs `launcher.py` with
`.venv\Scripts\pythonw.exe` (no window, output in `dist/logs/app.log`); the server keeps running in the background
until `./build.sh --stop`. Tests: `.venv/Scripts/python -m unittest discover -s tests -v`.
