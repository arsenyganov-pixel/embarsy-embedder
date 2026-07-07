#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

app_name="Embarsy"
app_version="0.2.0"
volume_name="Embarsy ${app_version}"
build_dir="${EMBARSY_HOME}/build"
app_bundle="${build_dir}/${app_name}.app"
dmg_final="${build_dir}/${app_name}-${app_version}-arm64.dmg"
background_name="dmg-background.png"
background_source="${build_dir}/${background_name}"
volume_icon_source="${EMBARSY_HOME}/Embarsy-icons/AppIcon/Embarsy.icns"
dmg_file_icon_source="${EMBARSY_HOME}/Embarsy-icons/AppIcon/Embarsy_1024.png"
dmg_file_icon_work="${build_dir}/dmg-file-icon.png"
dmg_file_icon_rsrc="${build_dir}/dmg-file-icon.rsrc"
window_width=720
window_height=440
icon_size=96
app_icon_x=205
app_icon_y=175
applications_icon_x=515
applications_icon_y=175
skip_app_package=false
skip_verify=false
dry_run=false
build_api_binary=true
bundle_version=""

usage() {
  cat <<'EOF'
Usage: scripts/package-dmg.sh [options]

Builds a polished drag-to-Applications DMG for Embarsy.app.

Options:
  --skip-app-package   Reuse existing build/Embarsy.app instead of rebuilding it.
  --skip-api-binary-build
                       Do not rebuild bin/embarsy-api before packaging the app.
                       Use only for fast local repackaging when the API code did not change.
  --skip-verify        Skip hdiutil verify and mount smoke checks.
  --dry-run            Print the packaging plan without writing the DMG.
  -h, --help           Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-app-package)
      skip_app_package=true
      ;;
    --skip-api-binary-build)
      build_api_binary=false
      ;;
    --skip-verify)
      skip_verify=true
      ;;
    --dry-run)
      dry_run=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

require_command hdiutil
require_command python3
require_command sips
require_command DeRez
require_command Rez
require_command SetFile

detach_existing_volume_mounts() {
  local candidate
  while IFS= read -r candidate; do
    if mount | grep -F " on ${candidate} (" >/dev/null 2>&1; then
      echo "Detaching existing mounted volume: ${candidate}"
      hdiutil detach "${candidate}" -quiet || diskutil unmount force "${candidate}" >/dev/null || true
    fi
  done < <(find /Volumes -maxdepth 1 \( -name "${volume_name}" -o -name "${volume_name} [0-9]*" \) -print 2>/dev/null | sort -r)
}

echo "Packaging ${app_name}.dmg"
echo "  app bundle: ${app_bundle}"
echo "  output: ${dmg_final}"
echo "  volume name: ${volume_name}"
echo "  skip_app_package: ${skip_app_package}"
echo "  build_api_binary: ${build_api_binary}"
echo "  skip_verify: ${skip_verify}"
echo "  dry_run: ${dry_run}"

if [[ "${dry_run}" == true ]]; then
  echo "Dry run plan:"
  if [[ "${skip_app_package}" != true ]]; then
    if [[ "${build_api_binary}" == true ]]; then
      echo "  scripts/package-macos-app.sh --build-api-binary"
    else
      echo "  scripts/package-macos-app.sh"
    fi
  fi
  echo "  generate ${background_source}"
  echo "  dmgbuild layout: ${window_width}x${window_height}, icon size ${icon_size}, background + drag-to-Applications (Finder-free)"
  echo "  build compressed DMG -> ${dmg_final}"
  echo "  apply custom Finder file icon to ${dmg_final}"
  if [[ "${skip_verify}" != true ]]; then
    echo "  hdiutil verify ${dmg_final}"
    echo "  mount smoke check"
  fi
  exit 0
fi

if [[ "${skip_app_package}" != true ]]; then
  package_app_args=()
  if [[ "${build_api_binary}" == true ]]; then
    package_app_args+=("--build-api-binary")
  fi
  # Empty-array-safe expansion: bash 3.2 under `set -u` errors on "${arr[@]}"
  # when the array is empty (e.g. when --build-api-binary was not added).
  "${SCRIPT_DIR}/package-macos-app.sh" ${package_app_args[@]+"${package_app_args[@]}"}
fi

if [[ ! -d "${app_bundle}" ]]; then
  echo "Missing app bundle: ${app_bundle}" >&2
  echo "Run scripts/package-macos-app.sh first or rerun without --skip-app-package." >&2
  exit 1
fi

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app_bundle}/Contents/Info.plist")"
if [[ -z "${bundle_version}" || "${bundle_version}" == "2" ]]; then
  echo "Refusing to package suspicious/stale app build version '${bundle_version}'. Rebuild ${app_bundle} without --skip-app-package." >&2
  exit 1
fi
echo "  app build: ${bundle_version}"

codesign --verify --deep --strict "${app_bundle}"
detach_existing_volume_mounts

mkdir -p "${build_dir}"
python3 - "${background_source}" <<'PY'
from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

out = Path(sys.argv[1])
width, height = 720, 440

def chunk(kind: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )

def pixel(x: int, y: int) -> tuple[int, int, int]:
    # Embarsy Snow base with a subtle teal radial glow.
    base = [246, 250, 252]
    cx, cy = width // 2, height // 2
    distance = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
    glow = max(0.0, 1.0 - distance / 390.0)
    teal = [20, 184, 166]
    color = [int(base[i] * (1 - 0.18 * glow) + teal[i] * (0.18 * glow)) for i in range(3)]

    # Subtle title bands.
    if 0 <= y <= 72:
        blend = 0.12 * (1 - y / 72)
        color = [int(color[i] * (1 - blend) + teal[i] * blend) for i in range(3)]
    return tuple(color)

DIGITS = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
    "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
}

FONT = {
    " ": ["00000", "00000", "00000", "00000", "00000", "00000", "00000"],
    ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
    ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
    "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
    "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
    "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "F": ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
    "G": ["01111", "10000", "10000", "10011", "10001", "10001", "01111"],
    "H": ["10001", "10001", "10001", "11111", "10001", "10001", "10001"],
    "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
    "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
    "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
    "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    "W": ["10001", "10001", "10001", "10101", "10101", "10101", "01010"],
    "Y": ["10001", "10001", "01010", "00100", "00100", "00100", "00100"],
}

digit_scale = 3
digit_width = 5 * digit_scale
digit_height = 7 * digit_scale

def set_pixel(canvas: bytearray, x: int, y: int, color: tuple[int, int, int], alpha: float = 1.0) -> None:
    if not (0 <= x < width and 0 <= y < height):
        return

    offset = (y * width + x) * 3
    for channel in range(3):
        canvas[offset + channel] = int(canvas[offset + channel] * (1 - alpha) + color[channel] * alpha)

def draw_digit(canvas: bytearray, digit: str, center_x: int, center_y: int, color: tuple[int, int, int], alpha: float) -> None:
    pattern = DIGITS[digit]
    origin_x = center_x - digit_width // 2
    origin_y = center_y - digit_height // 2

    # One-pixel translucent shadow keeps the tiny numeric glyphs readable on the glow.
    shadow = (255, 255, 255)
    for y, row in enumerate(pattern):
        for x, bit in enumerate(row):
            if bit != "1":
                continue
            for dy in range(digit_scale):
                for dx in range(digit_scale):
                    set_pixel(canvas, origin_x + x * digit_scale + dx + 1, origin_y + y * digit_scale + dy + 1, shadow, 0.45)
                    set_pixel(canvas, origin_x + x * digit_scale + dx, origin_y + y * digit_scale + dy, color, alpha)

def point_in_triangle(px: int, py: int, a: tuple[int, int], b: tuple[int, int], c: tuple[int, int]) -> bool:
    def sign(p1: tuple[int, int], p2: tuple[int, int], p3: tuple[int, int]) -> int:
        return (p1[0] - p3[0]) * (p2[1] - p3[1]) - (p2[0] - p3[0]) * (p1[1] - p3[1])

    point = (px, py)
    d1 = sign(point, a, b)
    d2 = sign(point, b, c)
    d3 = sign(point, c, a)
    has_negative = d1 < 0 or d2 < 0 or d3 < 0
    has_positive = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_negative and has_positive)

def inside_digit_arrow(cx: int, cy: int) -> bool:
    # Dotted-arrow silhouette: a compact rectangular tail and a triangular head,
    # positioned between Embarsy.app and Applications Finder icons.
    in_tail = 278 <= cx <= 358 and 135 <= cy <= 195
    in_head = point_in_triangle(cx, cy, (358, 105), (458, 165), (358, 225))
    return in_tail or in_head

def draw_digit_arrow(canvas: bytearray) -> None:
    positions: list[tuple[int, int]] = []
    for cy in range(110, 224, 20):
        for cx in range(280, 462, 20):
            if inside_digit_arrow(cx, cy):
                positions.append((cx, cy))

    palette = [
        (44, 105, 118),
        (55, 126, 138),
        (75, 139, 151),
        (20, 153, 142),
        (97, 129, 145),
    ]
    for index, (cx, cy) in enumerate(positions):
        color = palette[(index + cx // 20 + cy // 20) % len(palette)]
        alpha = min(0.92, 0.62 + max(0, cx - 280) / 182 * 0.24)
        draw_digit(canvas, str(index % 10), cx, cy, color, alpha)

def draw_text(canvas: bytearray, text: str, center_x: int, baseline_y: int, scale: int, color: tuple[int, int, int], alpha: float) -> None:
    glyph_width = 5 * scale
    glyph_height = 7 * scale
    spacing = 2 * scale
    total_width = sum((glyph_width if char != " " else 3 * scale) + spacing for char in text) - spacing
    x_cursor = center_x - total_width // 2
    shadow = (255, 255, 255)

    for char in text:
        pattern = FONT.get(char, FONT[" "])
        char_width = glyph_width if char != " " else 3 * scale
        for y, row in enumerate(pattern):
            for x, bit in enumerate(row):
                if bit != "1":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        px = x_cursor + x * scale + dx
                        py = baseline_y + y * scale + dy
                        set_pixel(canvas, px + 1, py + 1, shadow, 0.55)
                        set_pixel(canvas, px, py, color, alpha)
        x_cursor += char_width + spacing

canvas = bytearray(width * height * 3)
for y in range(height):
    for x in range(width):
        offset = (y * width + x) * 3
        canvas[offset:offset + 3] = bytes(pixel(x, y))

draw_digit_arrow(canvas)
draw_text(canvas, "AFTER COPY: CLOSE WINDOW.", width // 2, 302, 2, (55, 105, 118), 0.76)

rows = []
for y in range(height):
    row_start = y * width * 3
    row_end = row_start + width * 3
    rows.append(bytes([0]) + bytes(canvas[row_start:row_end]))

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
png += chunk(b"IEND", b"")
out.write_bytes(png)
PY

# --- Build the polished DMG with dmgbuild (Finder-free: works headless & on CI) ---
# dmgbuild writes the window background and icon layout straight into the volume's
# .DS_Store — no Finder/AppleScript involved, so it never times out (-1712). It
# self-installs into a cached venv under build/ on first run.
dmg_venv="${build_dir}/.dmg-venv"
if [[ ! -x "${dmg_venv}/bin/dmgbuild" ]]; then
  echo "Setting up dmgbuild (one-time) in ${dmg_venv}..."
  python3 -m venv "${dmg_venv}"
  "${dmg_venv}/bin/pip" install --quiet --disable-pip-version-check dmgbuild
fi

rm -f "${dmg_final}"
dmg_settings="${build_dir}/dmg-settings.py"
cat > "${dmg_settings}" <<PYEOF
application = "${app_bundle}"
format = "UDZO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = "${volume_icon_source}"
background = "${background_source}"

window_rect = ((120, 120), (${window_width}, ${window_height}))
default_view = "icon-view"
show_status_bar = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False
show_icon_preview = False
arrange_by = None
icon_size = ${icon_size}
text_size = 12
label_pos = "bottom"
icon_locations = {
    "${app_name}.app": (${app_icon_x}, ${app_icon_y}),
    "Applications": (${applications_icon_x}, ${applications_icon_y}),
    # Park the hidden helper files far below the visible window so they never
    # clutter the installer — even when Finder is set to show hidden files.
    # dmgbuild writes an Iloc (position) for every icon_locations entry.
    ".background.png": (180, 820),
    ".VolumeIcon.icns": (360, 820),
    ".fseventsd": (540, 820),
    ".Trashes": (720, 820),
    ".DS_Store": (900, 820),
}
# Also set the invisible bit (the default, hidden-files-off experience).
hide = [".background.png", ".VolumeIcon.icns", ".fseventsd", ".Trashes"]
PYEOF

"${dmg_venv}/bin/dmgbuild" -s "${dmg_settings}" "${volume_name}" "${dmg_final}"
rm -f "${dmg_settings}"

# dmgbuild sets the mounted-volume icon; the .dmg FILE's Finder icon is a separate
# resource-fork icon, stamped here.
cp "${dmg_file_icon_source}" "${dmg_file_icon_work}"
sips -i "${dmg_file_icon_work}" >/dev/null
DeRez -only icns "${dmg_file_icon_work}" > "${dmg_file_icon_rsrc}"
Rez -append "${dmg_file_icon_rsrc}" -o "${dmg_final}"
SetFile -a C "${dmg_final}"
rm -f "${dmg_file_icon_work}" "${dmg_file_icon_rsrc}"

if [[ "${skip_verify}" != true ]]; then
  detach_existing_volume_mounts
  hdiutil verify "${dmg_final}"
  if ! xattr -p com.apple.ResourceFork "${dmg_final}" >/dev/null 2>&1; then
    echo "Final DMG icon check failed: missing custom icon resource fork on ${dmg_final}." >&2
    exit 1
  fi
  smoke_output="$(hdiutil attach "${dmg_final}" -nobrowse -readonly -noverify)"
  smoke_device="$(printf '%s\n' "${smoke_output}" | awk '/\/Volumes\// {print $1; exit}')"
  smoke_mount="$(printf '%s\n' "${smoke_output}" | awk '/\/Volumes\// {for (i=3; i<=NF; i++) {printf "%s%s", (i==3 ? "" : OFS), $i}; print ""; exit}')"
  if [[ -z "${smoke_device}" || -z "${smoke_mount}" ]]; then
    echo "Failed to mount final DMG for smoke check." >&2
    printf '%s\n' "${smoke_output}" >&2
    exit 1
  fi
  if [[ ! -d "${smoke_mount}/${app_name}.app" || ! -L "${smoke_mount}/Applications" ]]; then
    hdiutil detach "${smoke_device}" -quiet || true
    echo "Final DMG smoke check failed: missing app bundle or Applications symlink." >&2
    exit 1
  fi
  smoke_bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${smoke_mount}/${app_name}.app/Contents/Info.plist")"
  if [[ "${smoke_bundle_version}" != "${bundle_version}" ]]; then
    hdiutil detach "${smoke_device}" -quiet || true
    echo "Final DMG smoke check failed: mounted app build ${smoke_bundle_version} != packaged build ${bundle_version}." >&2
    exit 1
  fi
  echo "Final DMG smoke check build: ${smoke_bundle_version}"
  hdiutil detach "${smoke_device}" -quiet
fi

echo "Packaged ${dmg_final}"
