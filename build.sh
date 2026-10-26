#!/usr/bin/env bash
# build.sh - Local Build Protocol v5
# MANAGED FILE: copied verbatim from ~/.claude/build-protocol/templates/build.sh.
# Do not edit it per project. Per-project settings live in build.config.json, and extra per-project
# steps go in build.config.json "hooks". To change behaviour for every project, change the template,
# bump its version, and re-copy (the build-protocol agent does this).
#
# Needs Git Bash and Node.js on PATH (python projects also need uv and devstore). Windows-only steps
# (Start Menu shortcuts, finding processes that lock dist/, starting hidden detached processes) call
# Windows PowerShell inline.
#
# usage: ./build.sh [options]
#   (no options)            build the default target
#   --target all            build every target listed in build.config.json
#   --target webgl          build one target
#   --clean                 delete dist/ first, then build
#   --run                   build, then launch (with --target: build and launch that target)
#   --launch                launch the existing build of launchTarget
#   --launch --target webgl launch a specific target (web, webgl, windows, app)
#   --pin                   create/refresh the Start Menu shortcut (builds first if needed)
#   --unpin                 remove the Start Menu shortcut
#   --info                  print the resolved configuration and outputs, and check line-ending rules
#   --stop                  stop running copies of the app (and its web launcher)
#   --force                 stop running copies of the app that lock files in dist/ (or the python env)

set -euo pipefail

PROTOCOL_VERSION=5
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
CONFIG="$ROOT/build.config.json"

TARGET="" CLEAN=0 RUN=0 LAUNCH=0 PIN=0 UNPIN=0 INFO=0 FORCE=0 STOP=0

# ---------------------------------------------------------------- helpers

if [[ -t 1 ]]; then C_STEP=$'\e[36m' C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_OFF=$'\e[0m'
else C_STEP="" C_OK="" C_WARN="" C_ERR="" C_OFF=""; fi

step() { echo "${C_STEP}==> $*${C_OFF}"; }
ok()   { echo "${C_OK}$*${C_OFF}"; }
warn() { echo "${C_WARN}warning: $*${C_OFF}" >&2; }
die()  { echo "${C_ERR}error: $*${C_OFF}" >&2; exit 1; }

usage() { sed -n '/^# usage:/,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }

win()  { cygpath -w "$1"; }           # Windows path for Windows programs
now_ms() { date +%s%3N; }

repo_path() {                          # config paths are relative to the repo root
    case "$1" in
        /*|[A-Za-z]:*) cygpath -u "$1" ;;
        *) realpath -m "$ROOT/$1" ;;
    esac
}

# Runs a Windows PowerShell snippet; values are passed in BP_* environment variables, not interpolated.
ps_run() { powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "$1" | tr -d '\r'; }

json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

is_true() { [[ "${1:-false}" == true ]]; }

contains() { local x=$1; shift; local e; for e in "$@"; do [[ "$e" == "$x" ]] && return 0; done; return 1; }

# ---------------------------------------------------------------- config

load_config() {
    [[ -f "$CONFIG" ]] || die "build.config.json not found next to build.sh ($ROOT)."
    command -v node >/dev/null || die "Node.js is required (node not found on PATH)."
    # Flatten the JSON into shell variables: pin.enabled -> CFG_pin_enabled, arrays -> bash arrays.
    local src
    src=$(BP_CONFIG="$(win "$CONFIG")" node <<'JS'
const fs = require('fs');
let cfg;
try { cfg = JSON.parse(fs.readFileSync(process.env.BP_CONFIG, 'utf8')); }
catch (e) { console.error(`build.config.json: ${e.message}`); process.exit(1); }
const q = (v) => "'" + String(v).replace(/'/g, "'\\''") + "'";
const out = [];
(function walk(obj, prefix) {
  for (const [k, v] of Object.entries(obj)) {
    const name = prefix + k.replace(/[^A-Za-z0-9]/g, '_');
    if (v === null || v === undefined) continue;
    if (Array.isArray(v)) out.push(`${name}=(${v.map(q).join(' ')})`);
    else if (typeof v === 'object') walk(v, name + '_');
    else out.push(`${name}=${q(v)}`);
  }
})(cfg, 'CFG_');
console.log(out.join('\n'));
JS
    ) || die "could not read build.config.json"
    eval "$src"

    local cfg_version=${CFG_protocolVersion:-1}
    if (( cfg_version > PROTOCOL_VERSION )); then
        die "build.config.json is protocol v$cfg_version but build.sh is v$PROTOCOL_VERSION. Re-copy build.sh from ~/.claude/build-protocol/templates."
    fi

    TYPE=${CFG_type:-}
    NAME=${CFG_name:-$(basename "$ROOT")}
    DISPLAY_NAME=${CFG_displayName:-$NAME}
    PROJECT_DIR=$(repo_path "${CFG_projectPath:-.}")

    case "$TYPE" in
        node-web) VALID_TARGETS=(web) ;;
        electron) VALID_TARGETS=(windows) ;;
        unity)    VALID_TARGETS=(windows linux mac webgl android ios) ;;
        python)   VALID_TARGETS=(app) ;;
        *) die "build.config.json 'type' must be one of: node-web, electron, unity, python (got '$TYPE')." ;;
    esac

    if [[ -n "${CFG_targets+x}" ]]; then CONFIGURED_TARGETS=("${CFG_targets[@]}"); else CONFIGURED_TARGETS=("${VALID_TARGETS[0]}"); fi
    DEFAULT_TARGET=${CFG_defaultTarget:-${CONFIGURED_TARGETS[0]}}
    local t
    for t in "${CONFIGURED_TARGETS[@]}"; do
        contains "$t" "${VALID_TARGETS[@]}" || die "target '$t' is not valid for type '$TYPE' (valid: ${VALID_TARGETS[*]})."
    done

    # Targets that run on this machine: web outputs are served locally, windows runs its exe, app runs the
    # python project from its env.
    WEB_TARGETS=(web webgl)
    LAUNCHABLE_TARGETS=(web webgl windows app)
    case "$TYPE" in
        node-web) LAUNCH_TARGET=${CFG_launchTarget:-web} ;;
        python)   LAUNCH_TARGET=${CFG_launchTarget:-app} ;;
        *)        LAUNCH_TARGET=${CFG_launchTarget:-windows} ;;
    esac
    if [[ "$TYPE" == python ]]; then python_config; fi
    if ! contains "$LAUNCH_TARGET" "${VALID_TARGETS[@]}" || ! contains "$LAUNCH_TARGET" "${LAUNCHABLE_TARGETS[@]}"; then
        die "launchTarget '$LAUNCH_TARGET' must be a launchable target of type '$TYPE'."
    fi
}

resolve_launch_target() {
    if [[ -n "$TARGET" && "$TARGET" != all ]]; then echo "$TARGET"; else echo "$LAUNCH_TARGET"; fi
}

is_web() { contains "$1" "${WEB_TARGETS[@]}"; }

# ---------------------------------------------------------------- processes, hooks, build info

# Prints "name (pid)" for each process running an exe from inside $1; stops them first when $2 is 1.
processes_under() {
    [[ -d "$1" ]] || return 0
    [[ -n "$(find "$1" -iname '*.exe' -print -quit)" ]] || return 0
    BP_DIR="$(win "$1")" BP_KILL="${2:-0}" ps_run '
        $names = @(Get-ChildItem $env:BP_DIR -Recurse -Filter *.exe -File -EA SilentlyContinue | ForEach-Object BaseName | Sort-Object -Unique)
        # Compare 8.3 short paths: a process may report either form of the same path.
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $prefix = $fso.GetFolder($env:BP_DIR).ShortPath.TrimEnd("\") + "\"
        $procs = @(Get-Process -Name $names -EA SilentlyContinue | Where-Object {
            try { $_.Path -and $fso.GetFile($_.Path).ShortPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
        $procs | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }
        if ($env:BP_KILL -eq "1" -and $procs) { $procs | Stop-Process -Force; Start-Sleep -Milliseconds 800 }'
}

# Prints "name (pid)" for each process whose command line contains every line of BP_NEEDLES. When BP_ENV
# is set (folders, one per line), only processes running an exe from inside it, or their children, count.
# Stops them first when $1 is 1.
processes_matching() {
    BP_KILL="${1:-0}" ps_run '
        $needles = @($env:BP_NEEDLES -split "`n" | Where-Object { $_ -ne "" })
        $roots = @($env:BP_ENV -split "`n" | Where-Object { $_ -ne "" } | ForEach-Object { $_.TrimEnd("\") + "\" })
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine)
        $inEnv = @{}
        foreach ($p in $all) { foreach ($r in $roots) {
            if ($p.ExecutablePath -and $p.ExecutablePath.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $inEnv[[int]$p.ProcessId] = 1 } } }
        $hits = @($all | Where-Object {
            $cl = $_.CommandLine
            $_.ProcessId -ne $PID -and $cl -and $_.Name -notin @("bash.exe", "powershell.exe", "pwsh.exe") -and
            ($roots.Count -eq 0 -or $inEnv.ContainsKey([int]$_.ProcessId) -or $inEnv.ContainsKey([int]$_.ParentProcessId)) -and
            -not ($needles | Where-Object { $cl.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -lt 0 }) })
        $hits | ForEach-Object { "$($_.Name) ($($_.ProcessId))" }
        if ($env:BP_KILL -eq "1" -and $hits) { $hits | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }; Start-Sleep -Milliseconds 800 }'
}

assert_not_running() {
    local running
    running=$(processes_under "$1" 0)
    [[ -z "$running" ]] && return 0
    running=${running//$'\n'/, }
    (( FORCE )) || die "The app is running from $1 and locks its files: $running. Close it or re-run with --force."
    step "stopping $running"
    processes_under "$1" 1 >/dev/null
}

run_hooks() {
    local var="CFG_hooks_$1"
    [[ -n "${!var+x}" ]] || return 0
    local -n hooks=$var
    local cmd
    for cmd in "${hooks[@]}"; do
        [[ -n "$cmd" ]] || continue
        step "hook $1: $cmd"
        (cd "$ROOT" && bash -c "$cmd") || die "hook '$cmd' failed"
    done
}

write_build_info() { # target outDir startMs
    local commit="null" dirty="null" c
    if c=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null); then
        commit=$(json_str "$c")
        if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then dirty=true; else dirty=false; fi
    fi
    local secs=$(( ($(now_ms) - $3) / 100 ))
    cat > "$2/build-info.json" <<EOF
{
  "protocolVersion": $PROTOCOL_VERSION,
  "name": $(json_str "$NAME"),
  "type": $(json_str "$TYPE"),
  "target": $(json_str "$1"),
  "builtAt": $(json_str "$(date -Iseconds)"),
  "durationSec": $(( secs / 10 )).$(( secs % 10 )),
  "gitCommit": $commit,
  "gitDirty": $dirty
}
EOF
}

# ---------------------------------------------------------------- node (shared by node-web and electron)

package_manager() {
    local pm=${CFG_node_packageManager:-auto}
    if [[ "$pm" != auto ]]; then echo "$pm"
    elif [[ -f "$PROJECT_DIR/pnpm-lock.yaml" ]]; then echo pnpm
    elif [[ -f "$PROJECT_DIR/yarn.lock" ]]; then echo yarn
    else echo npm; fi
}

install_node_deps() {
    local stamp="$PROJECT_DIR/node_modules/.build-protocol-installed" need=0 f
    [[ -f "$stamp" ]] || need=1
    for f in package.json package-lock.json pnpm-lock.yaml yarn.lock; do
        if [[ -f "$PROJECT_DIR/$f" && "$PROJECT_DIR/$f" -nt "$stamp" ]]; then need=1; fi
    done
    (( need )) || return 0
    local pm; pm=$(package_manager)
    step "$pm install"
    (cd "$PROJECT_DIR" && "$pm" install) || die "$pm install failed"
    mkdir -p "$(dirname "$stamp")"
    date -Iseconds > "$stamp"
}

has_package_script() {
    BP_PKG="$(win "$PROJECT_DIR/package.json")" node -e \
        'process.exit((require(process.env.BP_PKG).scripts || {})[process.argv[1]] ? 0 : 1)' "$1"
}

run_package_script() {
    local pm; pm=$(package_manager)
    step "$pm run $1"
    (cd "$PROJECT_DIR" && "$pm" run "$1") || die "$pm run $1 failed"
}

# ---------------------------------------------------------------- python

# Runs the app with stdout/stderr appended to a log (started over past 1 MB). sys.argv is: log, entry [args]
# or log, -m, module [args]. It's inline so a shortcut can run it with pythonw.exe: no console, no shell.
PY_BOOT="import os,sys,runpy,time;l=sys.argv[1];os.makedirs(os.path.dirname(l),exist_ok=True);f=open(l,'w' if os.path.isfile(l) and os.path.getsize(l)>2**20 else 'a',buffering=1,encoding='utf-8',errors='replace');sys.stdout=sys.stderr=f;print(time.strftime('--- %Y-%m-%d %H:%M:%S start'),os.getpid());a=sys.argv[2:];m=a[0]=='-m';sys.argv=a[1:] if m else a;runpy.run_module(sys.argv[0],run_name='__main__',alter_sys=True) if m else (sys.path.insert(0,os.path.dirname(os.path.abspath(a[0]))),runpy.run_path(a[0],run_name='__main__'))"

project_path() { # python.* paths are relative to projectPath
    case "$1" in
        /*|[A-Za-z]:*) cygpath -u "$1" ;;
        *) realpath -ms "$PROJECT_DIR/$1" ;;
    esac
}

python_config() {
    PY_ENV=$(project_path "${CFG_python_venv:-.venv}")
    PY_EXE="$PY_ENV/Scripts/python.exe"
    PY_EXEW="$PY_ENV/Scripts/pythonw.exe"
    PY_LOG="$DIST/logs/app.log"
    PY_MODULE=${CFG_python_module:-}
    PY_ENTRY=""
    if [[ -n "$PY_MODULE" ]]; then
        PY_RUN=(-m "$PY_MODULE"); PY_NEEDLE=$PY_MODULE
    else
        PY_ENTRY=$(project_path "${CFG_python_entry:-main.py}")
        PY_RUN=("$(win "$PY_ENTRY")"); PY_NEEDLE=$(basename "$PY_ENTRY")
    fi
    PY_CHECK=("${PY_RUN[@]}")
    if [[ -n "${CFG_python_args+x}" ]]; then PY_RUN+=("${CFG_python_args[@]}"); fi
}

python_processes() { # $1 = 1 to stop them. Processes of the app run from its env (the env path and its junction target).
    local envs; envs=$(win "$PY_ENV")
    if [[ -e "$PY_ENV" ]]; then envs+=$'\n'"$(win "$(realpath "$PY_ENV")")"; fi
    BP_ENV="$envs" BP_NEEDLES="$PY_NEEDLE" processes_matching "${1:-0}"
}

assert_python_not_running() {
    local running; running=$(python_processes 0)
    [[ -z "$running" ]] && return 0
    running=${running//$'\n'/, }
    (( FORCE )) || die "The app is running from $(win "$PY_ENV") and locks its files: $running. Close it, run ./build.sh --stop, or re-run with --force."
    step "stopping $running"
    python_processes 1 >/dev/null
}

python_env_note() { # prints why the env isn't where the dev storage rules want it (a junction into A:), if it isn't
    if [[ -d "$PY_ENV" && ! -L "$PY_ENV" ]]; then echo "a plain folder inside the repo: move it to A: with 'devstore adopt $(win "$PY_ENV")'"; fi
}

ensure_python_env() {
    if [[ ! -f "$PY_EXE" ]]; then
        [[ ! -e "$PY_ENV" && ! -L "$PY_ENV" ]] || die "$(win "$PY_ENV") exists but has no Scripts\\python.exe. Remove it (it may be a junction into A:) and build again."
        command -v devstore >/dev/null || die "devstore is not on PATH. Python envs are created with 'devstore venv' (A:\\bin), never inside the repo."
        local args=("$(realpath -m --relative-to="$PROJECT_DIR" "$PY_ENV")")
        if [[ -n "${CFG_python_version:-}" ]]; then args+=(-Python "$CFG_python_version"); fi
        step "devstore venv ${args[*]}"
        (cd "$PROJECT_DIR" && devstore venv "${args[@]}") || die "devstore venv failed"
        [[ -f "$PY_EXE" ]] || die "devstore venv finished but $(win "$PY_EXE") is missing."
    fi
    local note; note=$(python_env_note)
    if [[ -n "$note" ]]; then warn "the python env $(win "$PY_ENV") is $note."; fi
}

install_python_deps() {
    local stamp="$PY_ENV/.build-protocol-installed" req pyproject="$PROJECT_DIR/pyproject.toml" need=0 f
    req=$(project_path "${CFG_python_requirements:-requirements.txt}")
    [[ -f "$stamp" ]] || need=1
    for f in "$req" "$pyproject" "$PROJECT_DIR/uv.lock"; do
        if [[ -f "$f" && "$f" -nt "$stamp" ]]; then need=1; fi
    done
    (( need )) || return 0
    command -v uv >/dev/null || die "uv is required to install python dependencies (uv not found on PATH)."
    assert_python_not_running
    if [[ -f "$req" ]]; then
        step "uv pip install -r $(basename "$req")"
        (cd "$PROJECT_DIR" && uv pip install --python "$(win "$PY_EXE")" -r "$(win "$req")") || die "uv pip install failed"
    elif [[ -f "$pyproject" ]]; then
        step "uv sync"
        (cd "$PROJECT_DIR" && UV_PROJECT_ENVIRONMENT="$(win "$PY_ENV")" uv sync --inexact) || die "uv sync failed"
    else
        warn "no $(basename "$req") or pyproject.toml: no dependencies to install"
    fi
    date -Iseconds > "$stamp"
}

build_python() {
    local out="$DIST/app"
    ensure_python_env
    install_python_deps
    if [[ -n "$PY_ENTRY" && ! -f "$PY_ENTRY" ]]; then die "python.entry $(win "$PY_ENTRY") does not exist."; fi
    if [[ -n "${CFG_python_checkArgs+x}" ]]; then
        step "check: python ${PY_CHECK[*]} ${CFG_python_checkArgs[*]}"
        (cd "$PROJECT_DIR" && "$PY_EXE" "${PY_CHECK[@]}" "${CFG_python_checkArgs[@]}") || die "the python check failed"
    fi
    mkdir -p "$out" "$DIST/logs"
    BUILT_OUT=$out
}

# ---------------------------------------------------------------- builders

build_node_web() {
    local out="$DIST/web"
    install_node_deps
    run_package_script "${CFG_node_buildScript:-build}"
    [[ -f "$out/index.html" ]] || die "The build finished but $out/index.html is missing. The bundler's output directory must be <repo>/dist/web."
    BUILT_OUT=$out
}

build_electron() {
    local out="$DIST/windows"
    assert_not_running "$out"
    install_node_deps
    local build_script=${CFG_node_buildScript:-build} package_script=${CFG_electron_packageScript:-package:dir}
    if [[ "$build_script" != "$package_script" ]] && has_package_script "$build_script"; then run_package_script "$build_script"; fi
    run_package_script "$package_script"
    local unpacked; unpacked=$(repo_path "${CFG_electron_unpackedDir:-dist/.work/electron-builder/win-unpacked}")
    [[ -d "$unpacked" ]] || die "Packaging finished but the unpacked app is not at $unpacked (build.config.json electron.unpackedDir)."
    step "mirror $unpacked -> $out"
    local rc=0
    MSYS2_ARG_CONV_EXCL='*' robocopy "$(win "$unpacked")" "$(win "$out")" /MIR /NFL /NDL /NJH /NJS /NP /R:2 /W:1 >/dev/null || rc=$?
    (( rc < 8 )) || die "robocopy failed (exit $rc) mirroring into $out"
    BUILT_OUT=$out
}

unity_cli_target() {
    case "$1" in windows) echo Win64 ;; linux) echo Linux64 ;; mac) echo OSXUniversal ;;
                 webgl) echo WebGL ;; android) echo Android ;; ios) echo iOS ;; esac
}
unity_module() {
    case "$1" in windows) echo WindowsStandaloneSupport ;; linux) echo LinuxStandaloneSupport ;;
                 mac) echo MacStandaloneSupport ;; webgl) echo WebGLSupport ;;
                 android) echo AndroidPlayer ;; ios) echo iOSSupport ;; esac
}

unity_version() {
    local f="$PROJECT_DIR/ProjectSettings/ProjectVersion.txt"
    [[ -f "$f" ]] || die "$f not found; is projectPath pointing at the Unity project?"
    sed -n 's/^m_EditorVersion:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$f" | tr -d '\r'
}

unity_editor() {
    if [[ -n "${CFG_unity_editorPath:-}" ]]; then
        local p; p=$(cygpath -u "$CFG_unity_editorPath")
        [[ -f "$p" ]] || die "unity.editorPath '$CFG_unity_editorPath' does not exist."
        echo "$p"; return
    fi
    local ver roots=() r sec
    ver=$(unity_version)
    sec="$(cygpath -u "$APPDATA")/UnityHub/secondaryInstallPath.json"
    if [[ -f "$sec" ]]; then
        r=$(tr -d '"\r\n' < "$sec"); r=${r//\\\\/\\}
        if [[ -n "$r" ]]; then roots+=("$(cygpath -u "$r")"); fi
    fi
    roots+=("$(cygpath -u "${PROGRAMFILES:-C:\\Program Files}")/Unity/Hub/Editor")
    for r in "${roots[@]}"; do
        if [[ -f "$r/$ver/Editor/Unity.exe" ]]; then echo "$r/$ver/Editor/Unity.exe"; return; fi
    done
    die "Unity $ver is not installed (looked in: ${roots[*]}). Install it with Unity Hub or set unity.editorPath."
}

unity_module_installed() { [[ -d "$(dirname "$1")/Data/PlaybackEngines/$(unity_module "$2")" ]]; }

assert_unity_closed() {
    local lock="$PROJECT_DIR/Temp/UnityLockfile"
    [[ -f "$lock" ]] || return 0
    local state
    state=$(BP_LOCK="$(win "$lock")" ps_run '
        try { $f = [IO.File]::Open($env:BP_LOCK, "Open", "ReadWrite", "None"); $f.Close(); "free" } catch { "locked" }')
    [[ "$state" != locked ]] || die "The Unity editor has this project open. Close it, then build again (a batch build can't share a project with an open editor)."
}

build_unity() {
    local target=$1 editor
    editor=$(unity_editor)
    unity_module_installed "$editor" "$target" ||
        die "Unity build support for '$target' ($(unity_module "$target")) is not installed for this editor. Add the module in Unity Hub."
    assert_unity_closed
    local out="$DIST/$target" log="$DIST/logs/unity-$target.log"
    assert_not_running "$out"
    rm -rf "$out"
    mkdir -p "$out" "$DIST/logs"

    local args=(
        -batchmode -quit
        -projectPath "$(win "$PROJECT_DIR")"
        -buildTarget "$(unity_cli_target "$target")"
        -executeMethod "${CFG_unity_buildMethod:-BuildProtocol.Build}"
        -logFile "$(win "$log")"
        -bpTarget "$target"
        -bpOutput "$(win "$out")"
    )
    if is_true "${CFG_unity_development:-}"; then args+=(-bpDevelopment); fi
    if [[ -n "${CFG_unity_extraArgs+x}" ]]; then args+=("${CFG_unity_extraArgs[@]}"); fi

    step "Unity $(unity_version) -> $target (log: $log)"
    local rc=0
    "$editor" "${args[@]}" || rc=$?
    if (( rc != 0 )); then
        if [[ -f "$log" ]]; then
            grep -E 'error CS|Exception|Error:|Build Failed|compiler errors|Aborting batchmode|\[BuildProtocol\]' "$log" |
                tail -40 | sed "s/^/  ${C_ERR}/;s/\$/${C_OFF}/" >&2 || true
        fi
        die "Unity build for '$target' failed (exit $rc). Full log: $log"
    fi
    BUILT_OUT=$out
}

build_target() {
    local target=$1 start
    start=$(now_ms)
    step "build $NAME [$TYPE -> $target]"
    case "$TYPE" in
        node-web) build_node_web ;;
        electron) build_electron ;;
        unity)    build_unity "$target" ;;
        python)   build_python ;;
    esac
    write_build_info "$target" "$BUILT_OUT" "$start"
    local ms=$(( $(now_ms) - start ))
    ok "built $target in $(( ms / 1000 )).$(( ms % 1000 / 100 ))s -> $BUILT_OUT"
}

# ---------------------------------------------------------------- launch + Start Menu

target_exe() {
    local dir="$DIST/windows"
    if [[ -n "${CFG_exe:-}" ]]; then
        [[ -f "$dir/$CFG_exe" ]] || die "exe '$CFG_exe' not found in $dir. Build first."
        echo "$dir/$CFG_exe"; return
    fi
    local exes=() f
    for f in "$dir"/*.exe; do
        [[ -f "$f" ]] || continue
        [[ "$(basename "$f")" =~ ^(UnityCrashHandler|elevate|Uninstall) ]] && continue
        exes+=("$f")
    done
    case ${#exes[@]} in
        0) die "No .exe in $dir. Run ./build.sh first." ;;
        1) echo "${exes[0]}" ;;
        *) die "Several .exe files in $dir. Set 'exe' in build.config.json." ;;
    esac
}

launch_target_built() {
    if is_web "$1"; then [[ -f "$DIST/$1/index.html" ]]
    elif [[ "$1" == app ]]; then [[ -f "$DIST/app/build-info.json" && -f "$PY_EXE" ]]
    else ( target_exe >/dev/null 2>&1 ); fi
}

# Sets PY_LAUNCH_EXE and PY_LAUNCH_ARGS (one Windows command line): how --launch and the shortcut run a python app.
# Default: the env's pythonw.exe (no window) with its output in dist/logs/app.log; python.console: the env's
# python.exe in a console window.
python_launch() {
    if is_true "${CFG_python_console:-}"; then
        PY_LAUNCH_EXE=$(win "$PY_EXE")
        PY_LAUNCH_ARGS=$(win_quote_join "${PY_RUN[@]}")
    else
        PY_LAUNCH_EXE=$(win "$PY_EXEW")
        PY_LAUNCH_ARGS=$(win_quote_join -c "$PY_BOOT" "$(win "$PY_LOG")" "${PY_RUN[@]}")
    fi
}

app_browser() {
    local exe p
    for exe in msedge.exe chrome.exe; do
        p=$(MSYS2_ARG_CONV_EXCL='*' reg query "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$exe" /ve 2>/dev/null |
            tr -d '\r' | sed -n 's/.*REG_SZ[[:space:]]*//p') || true
        if [[ -n "$p" && -f "$(cygpath -u "$p")" ]]; then echo "$p"; return 0; fi
    done
    return 1
}

web_port() {
    if [[ "${CFG_web_port:-0}" != 0 ]]; then echo "$CFG_web_port"; return; fi
    local h=0 i c
    for (( i = 0; i < ${#NAME}; i++ )); do
        c=$(printf '%d' "'${NAME:i:1}")
        h=$(( (h * 31 + c) % 1000 ))
    done
    echo $(( 41000 + h ))
}

# Starts a Windows program detached from this shell (it outlives the console that launched it).
start_detached() { # exe workdir hidden args...
    local exe=$1 wd=$2 hidden=$3; shift 3
    local IFS=$'\n'
    BP_EXE="$exe" BP_WD="$wd" BP_HIDDEN="$hidden" BP_ARGS="$*" ps_run '
        $a = @($env:BP_ARGS -split "`n" | Where-Object { $_ -ne "" } | ForEach-Object {
            if ($_ -match "[\s`"]") { "`"" + ($_ -replace "`"", "\`"") + "`"" } else { $_ } }) -join " "
        $p = @{ FilePath = $env:BP_EXE; WorkingDirectory = $env:BP_WD }
        if ($a) { $p.ArgumentList = $a }
        if ($env:BP_HIDDEN -eq "1") { $p.WindowStyle = "Hidden" }
        Start-Process @p'
}

start_app() {
    local target=$1
    contains "$target" "${LAUNCHABLE_TARGETS[@]}" || die "target '$target' can't be launched on this machine (launchable: ${LAUNCHABLE_TARGETS[*]})."
    if [[ "$target" == app ]]; then
        launch_target_built app || die "No app build. Run ./build.sh first."
        python_launch
        step "launch $DISPLAY_NAME (log: $(win "$PY_LOG"))"
        # One pre-quoted command line, passed through as is (start_detached would re-quote the bootstrap).
        BP_EXE="$PY_LAUNCH_EXE" BP_WD="$(win "$PROJECT_DIR")" BP_ARGS="$PY_LAUNCH_ARGS" ps_run '
            $p = @{ FilePath = $env:BP_EXE; WorkingDirectory = $env:BP_WD }
            if ($env:BP_ARGS) { $p.ArgumentList = $env:BP_ARGS }
            Start-Process @p'
        return
    fi
    if [[ "$target" == windows ]]; then
        local exe; exe=$(target_exe)
        step "launch $exe"
        start_detached "$(win "$exe")" "$(win "$(dirname "$exe")")" 0
        return
    fi
    [[ -f "$DIST/$target/index.html" ]] || die "No $target build at $DIST/$target. Run ./build.sh --target $target first."
    web_launch_args "$target"
    step "launch $DISPLAY_NAME at http://127.0.0.1:$(web_port)/"
    # serve.mjs owns the lifecycle: it serves the build, opens an app window, and exits when the window closes.
    start_detached node.exe "$(win "$ROOT")" 1 "${WEB_ARGS[@]}"
}

# Sets WEB_ARGS: the serve.mjs command line (Windows paths) that serves dist/<target> in an app window.
web_launch_args() {
    mkdir -p "$DIST/logs"
    WEB_ARGS=(
        "$(win "$ROOT/tools/build/serve.mjs")"
        --root "$(win "$DIST/$1")"
        --port "$(web_port)"
        --name "$NAME"
        --profile "$LOCALAPPDATA\\BuildProtocol\\$NAME\\browser-profile"
        --log "$(win "$DIST/logs/launcher.log")"
    )
    local browser
    if browser=$(app_browser); then WEB_ARGS+=(--browser "$browser"); fi
    if is_true "${CFG_web_crossOriginIsolated:-}"; then WEB_ARGS+=(--isolate); fi
}

win_quote_join() { # joins arguments into one Windows command line
    local out="" a
    for a in "$@"; do
        if [[ -z "$a" || "$a" =~ [[:space:]\"] ]]; then a="\"${a//\"/\\\"}\""; fi
        out+="${out:+ }$a"
    done
    echo "$out"
}

shortcut_path() {
    local dir; dir="$(cygpath -u "$APPDATA")/Microsoft/Windows/Start Menu/Programs"
    local folder=${CFG_pin_folder-Dev Tools}
    if [[ -n "$folder" ]]; then dir="$dir/$folder"; fi
    echo "$dir/$DISPLAY_NAME.lnk"
}

set_shortcut() {
    local lnk target args wd icon=""
    lnk=$(shortcut_path)
    mkdir -p "$(dirname "$lnk")"
    if is_web "$LAUNCH_TARGET"; then
        # The shortcut runs node serve.mjs directly under a headless console: no window flashes, and
        # node owns that console for its whole life (a detached child of a short-lived shell would be
        # killed when the headless console closes). Rebuilds and --pin refresh the baked arguments.
        local node; node=$(command -v node.exe) || die "node.exe not found on PATH."
        web_launch_args "$LAUNCH_TARGET"
        target="$(cygpath -w -W)\\System32\\conhost.exe"
        args=$(win_quote_join --headless "$(win "$node")" "${WEB_ARGS[@]}")
        wd=$(win "$ROOT")
        local f browser
        for f in favicon.ico TemplateData/favicon.ico; do
            if [[ -f "$DIST/$LAUNCH_TARGET/$f" ]]; then icon="$(win "$DIST/$LAUNCH_TARGET/$f"),0"; break; fi
        done
        if [[ -z "$icon" ]] && browser=$(app_browser); then icon="$browser,0"; fi
    elif [[ "$LAUNCH_TARGET" == app ]]; then
        python_launch
        target=$PY_LAUNCH_EXE
        args=$PY_LAUNCH_ARGS
        wd=$(win "$PROJECT_DIR")
        icon="$target,0"
    else
        local exe; exe=$(target_exe)
        target=$(win "$exe")
        args=""
        wd=$(win "$(dirname "$exe")")
        icon="$target,0"
    fi
    if [[ -n "${CFG_pin_icon:-}" ]]; then icon="$(win "$(repo_path "$CFG_pin_icon")"),0"; fi
    BP_LNK="$(win "$lnk")" BP_TARGET="$target" BP_ARGS="$args" BP_WD="$wd" BP_ICON="$icon" \
    BP_DESC="$DISPLAY_NAME (local build from $(win "$ROOT"))" ps_run '
        $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($env:BP_LNK)
        $sc.TargetPath = $env:BP_TARGET
        $sc.Arguments = $env:BP_ARGS
        $sc.WorkingDirectory = $env:BP_WD
        if ($env:BP_ICON) { $sc.IconLocation = $env:BP_ICON }
        $sc.Description = $env:BP_DESC
        $sc.Save()'
    ok "Start Menu shortcut: $(win "$lnk")"
    echo "  (Windows doesn't allow apps to pin themselves: search '$DISPLAY_NAME' in Start, right-click -> Pin to Start once.)"
}

remove_shortcut() {
    local lnk; lnk=$(shortcut_path)
    if [[ -f "$lnk" ]]; then rm -f "$lnk"; echo "removed $(win "$lnk")"; else echo "no shortcut at $(win "$lnk")"; fi
    local dir; dir=$(dirname "$lnk")
    if [[ "$(basename "$dir")" != Programs ]]; then rmdir "$dir" 2>/dev/null || true; fi
    if is_true "${CFG_pin_enabled:-}"; then warn "pin.enabled is true, so the next build recreates it. Set it to false in build.config.json."; fi
}

stop_app() {
    local found="" out t
    if [[ "$TYPE" == python ]]; then found=$(python_processes 1); fi
    if contains windows "${CONFIGURED_TARGETS[@]}"; then
        out=$(processes_under "$DIST/windows" 1); found+=${out:+${found:+$'\n'}$out}
    fi
    for t in "${CONFIGURED_TARGETS[@]}"; do
        is_web "$t" || continue
        out=$(BP_ENV="" BP_NEEDLES="serve.mjs"$'\n'"$(win "$DIST/$t")" processes_matching 1)
        found+=${out:+${found:+$'\n'}$out}
    done
    if [[ -n "$found" ]]; then ok "stopped ${found//$'\n'/, }"; else echo "$DISPLAY_NAME is not running."; fi
}

# ---------------------------------------------------------------- info

show_info() {
    local latest="" canonical="$HOME/.claude/build-protocol/VERSION"
    if [[ -f "$canonical" ]]; then latest=$(tr -d '[:space:]' < "$canonical"); fi
    local note=""
    if [[ -n "$latest" ]] && (( latest > PROTOCOL_VERSION )); then note=" (v$latest available - ask the build-protocol agent to upgrade)"; fi
    echo "Build Protocol v$PROTOCOL_VERSION$note"
    printf '  %-14s %s\n' name "$NAME ($DISPLAY_NAME)" type "$TYPE" project "$(win "$PROJECT_DIR")" \
        targets "${CONFIGURED_TARGETS[*]} (default: $DEFAULT_TARGET)"
    if [[ "$TYPE" == unity ]]; then
        local editor t
        if editor=$( C_ERR="" C_OFF=""; unity_editor 2>&1 ); then
            printf '  %-14s %s\n' unity "$(unity_version) -> $(win "$editor")"
            for t in "${CONFIGURED_TARGETS[@]}"; do
                if unity_module_installed "$editor" "$t"; then printf '    %-9s module installed\n' "$t"
                else printf '    %-9s module MISSING\n' "$t"; fi
            done
        else
            printf '  %-14s %s\n' unity "NOT FOUND: ${editor#error: }"
        fi
    elif [[ "$TYPE" == python ]]; then
        local v note
        if [[ -f "$PY_EXE" ]]; then v=$("$PY_EXE" --version 2>&1 | tr -d '\r'); else v="not created yet: the build runs devstore venv"; fi
        if [[ -L "$PY_ENV" ]]; then note=" -> $(win "$(realpath "$PY_ENV")")"; else note=""; fi
        printf '  %-14s %s\n' "python env" "$(win "$PY_ENV")$note ($v)"
        note=$(python_env_note)
        if [[ -n "$note" ]]; then warn "the python env is $note."; fi
        if [[ -n "$PY_MODULE" ]]; then v="-m $PY_MODULE"; else v=$(win "$PY_ENTRY"); fi
        if [[ -n "${CFG_python_args+x}" ]]; then v+=" ${CFG_python_args[*]}"; fi
        printf '  %-14s %s\n' entry "$v"
        local uvv="MISSING" ds="MISSING"
        if command -v uv >/dev/null; then uvv=$(uv --version | tr -d '\r'); fi
        if command -v devstore >/dev/null; then ds=found; fi
        printf '  %-14s %s\n' tools "$uvv, devstore $ds"
        if is_true "${CFG_python_console:-}"; then v="console window"; else v="pythonw, no window; log $(win "$PY_LOG")"; fi
        printf '  %-14s %s\n' "runs as" "$v"
        v=$(python_processes 0)
        v=${v//$'\n'/, }
        printf '  %-14s %s\n' running "${v:-no}"
    else
        printf '  %-14s %s\n' "package mgr" "$(package_manager)"
    fi
    local web_target="" t
    for t in "${CONFIGURED_TARGETS[@]}"; do if is_web "$t"; then web_target=$t; break; fi; done
    if [[ -n "$web_target" ]]; then
        printf '  %-14s %s\n' "launch target" "$LAUNCH_TARGET ($web_target served at http://127.0.0.1:$(web_port)/)"
    else
        printf '  %-14s %s\n' "launch target" "$LAUNCH_TARGET"
    fi
    local bi state
    for t in "${CONFIGURED_TARGETS[@]}"; do
        bi="$DIST/$t/build-info.json"
        if [[ -f "$bi" ]]; then
            state=$(BP_BI="$(win "$bi")" node -e \
                'const j=require(process.env.BP_BI); console.log(`built ${j.builtAt} @ ${j.gitCommit ?? "?"}${j.gitDirty ? "+dirty" : ""}`)')
        else state="not built"; fi
        printf '  dist/%-9s %s\n' "$t" "$state"
    done
    local lnk; lnk=$(shortcut_path)
    if [[ -f "$lnk" ]]; then state="present: $(win "$lnk")"; else state=absent; fi
    printf '  %-14s %s\n' pin "enabled=${CFG_pin_enabled:-false}, shortcut $state"

    # In a git repo the managed files must check out as LF (the lines of templates/gitattributes): with
    # core.autocrlf they'd come out CRLF, differ from the templates, and build.sh would only run in Git Bash.
    # One git call; skipped outside a repo.
    local eol_files=(build.sh) cs="$PROJECT_DIR/Assets/Editor/BuildProtocol/BuildProtocol.cs" attrs line bad=() i=0
    if [[ -f "$ROOT/tools/build/serve.mjs" ]]; then eol_files+=(tools/build/serve.mjs); fi
    if [[ -f "$cs" ]]; then eol_files+=("${cs#"$ROOT"/}"); fi
    if attrs=$(git -C "$ROOT" check-attr eol -- "${eol_files[@]}" 2>/dev/null); then
        while IFS= read -r line; do
            if [[ "${line##*: }" != lf ]]; then bad+=("${eol_files[i]}"); fi
            i=$(( i + 1 ))
        done <<< "$attrs"
        if (( ${#bad[@]} )); then
            printf '  %-14s %s\n' "line endings" "NOT eol=lf: ${bad[*]}"
            warn "${bad[*]}: not eol=lf in git, so a core.autocrlf checkout makes them CRLF: they stop matching the templates, and only Git Bash can run a CRLF build.sh. Merge ~/.claude/build-protocol/templates/gitattributes into .gitattributes (the build-protocol agent does this)."
        else
            printf '  %-14s %s\n' "line endings" "eol=lf (.gitattributes)"
        fi
    fi
}

# ---------------------------------------------------------------- main

while (( $# )); do
    case "$1" in
        --target|-t) [[ $# -ge 2 ]] || die "--target needs a value"; TARGET=$2; shift 2 ;;
        --target=*)  TARGET=${1#*=}; shift ;;
        --clean)  CLEAN=1;  shift ;;
        --run)    RUN=1;    shift ;;
        --launch) LAUNCH=1; shift ;;
        --pin)    PIN=1;    shift ;;
        --unpin)  UNPIN=1;  shift ;;
        --info)   INFO=1;   shift ;;
        --force|-f) FORCE=1; shift ;;
        --stop)   STOP=1;   shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option '$1' (see ./build.sh --help)" ;;
    esac
done

load_config

if (( INFO ));   then show_info; exit 0; fi
if (( UNPIN ));  then remove_shortcut; exit 0; fi
if (( STOP ));   then stop_app; exit 0; fi
if (( LAUNCH )); then start_app "$(resolve_launch_target)"; exit 0; fi

build_requested=0
if [[ -n "$TARGET" ]] || (( CLEAN || RUN || !PIN )); then build_requested=1; fi
if (( PIN && !build_requested )) && ! launch_target_built "$LAUNCH_TARGET"; then build_requested=1; TARGET=$LAUNCH_TARGET; fi

if (( build_requested )); then
    TARGET=${TARGET:-$DEFAULT_TARGET}
    if [[ "$TARGET" == all ]]; then targets=("${CONFIGURED_TARGETS[@]}"); else targets=("$TARGET"); fi
    for t in "${targets[@]}"; do
        contains "$t" "${VALID_TARGETS[@]}" || die "target '$t' is not valid for type '$TYPE' (valid: ${VALID_TARGETS[*]}, all)."
    done

    if (( CLEAN )) && [[ -d "$DIST" ]]; then
        assert_not_running "$DIST"
        step "clean $DIST"
        rm -rf "$DIST"
    fi

    run_hooks preBuild
    skipped=()
    for t in "${targets[@]}"; do
        if [[ "$TARGET" == all && "$TYPE" == unity ]] && ! unity_module_installed "$(unity_editor)" "$t"; then
            warn "skipping '$t': Unity module $(unity_module "$t") is not installed"
            skipped+=("$t")
            continue
        fi
        build_target "$t"
    done
    run_hooks postBuild
    if (( ${#skipped[@]} )); then warn "skipped targets: ${skipped[*]}"; fi

    if (( !PIN )) && is_true "${CFG_pin_enabled:-}" && launch_target_built "$LAUNCH_TARGET"; then set_shortcut; fi
fi

if (( PIN )); then set_shortcut; fi
if (( RUN )); then start_app "$(resolve_launch_target)"; fi
