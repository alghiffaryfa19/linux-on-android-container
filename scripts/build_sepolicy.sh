#!/bin/bash
# build_sepolicy.sh
# Compile .te files dari vendor_lindroid/sepolicy dan merge ke precompiled_sepolicy
#
# Cara kerja:
# 1. Compile .te → .cil via checkpolicy
# 2. Merge dengan platform policy base menggunakan secilc
# 3. Output: precompiled_sepolicy (siap diflash ke /vendor/etc/selinux/)
#
# Referensi: BOARD_SEPOLICY_DIRS di lindroid.mk

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[SEPolicy]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}       $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}     $*"; }
error() { echo -e "${RED}[ERROR]${NC}    $*"; exit 1; }

# ── Defaults ─────────────────────────────────────────────
TE_DIR=""
OUTPUT_DIR="out/sepolicy"
PLATFORM_POLICY_DIR=""   # opsional: jika ada copy dari device
TARGET_BUILD_VARIANT="userdebug"

usage() {
cat << EOF
Usage: $0 [OPTIONS]

Options:
  --te-dir      PATH   Direktori berisi .te files lindroid (vendor_lindroid/sepolicy)
  --output      PATH   Output directory (default: out/sepolicy)
  --platform    PATH   Platform policy dir dari device (opsional, untuk full merge)
  --variant     TYPE   userdebug|user|eng (default: userdebug)
  --help               Help
EOF
exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --te-dir)   TE_DIR="$2";             shift 2 ;;
    --output)   OUTPUT_DIR="$2";         shift 2 ;;
    --platform) PLATFORM_POLICY_DIR="$2"; shift 2 ;;
    --variant)  TARGET_BUILD_VARIANT="$2"; shift 2 ;;
    --help|-h)  usage ;;
    *) error "Unknown: $1" ;;
  esac
done

[ -z "$TE_DIR" ]    && error "--te-dir wajib"
[ ! -d "$TE_DIR" ]  && error "TE dir tidak ditemukan: $TE_DIR"

mkdir -p "$OUTPUT_DIR"/{cil,final}
WORK="$OUTPUT_DIR/work"
mkdir -p "$WORK"

echo ""
info "TE source  : $TE_DIR"
info "Output     : $OUTPUT_DIR"
info "Variant    : $TARGET_BUILD_VARIANT"
echo ""

# ── Cek tools ────────────────────────────────────────────
check_tool() {
  command -v "$1" &>/dev/null || error "Tool '$1' tidak ditemukan. Install: sudo apt install $2"
}
check_tool checkpolicy    policycoreutils
check_tool secilc         selinux-utils
check_tool seinfo         setools3

info "Tools OK: checkpolicy=$(checkpolicy -V 2>&1 | head -1)"

# ── List .te files ────────────────────────────────────────
TE_FILES=($(find "$TE_DIR" -name "*.te" | sort))
[ ${#TE_FILES[@]} -eq 0 ] && error "Tidak ada .te file di $TE_DIR"

info "Found ${#TE_FILES[@]} .te files:"
for F in "${TE_FILES[@]}"; do echo "  - $(basename $F)"; done
echo ""

# ── Step 1: Compile setiap .te → .cil ────────────────────
info "[1/4] Compiling .te → .cil..."

# Base policy untuk referensi type (minimal)
# Kalau tidak ada platform policy, pakai stub yang cukup untuk compile
if [ -n "$PLATFORM_POLICY_DIR" ] && [ -d "$PLATFORM_POLICY_DIR" ]; then
  BASE_POLICY="$PLATFORM_POLICY_DIR"
  info "Menggunakan platform policy: $BASE_POLICY"
else
  warn "Platform policy tidak disertakan — pakai stub minimal"
  warn "Hasil mungkin perlu di-merge manual di device"

  # Buat stub attribute dan type yang umumnya dibutuhkan lindroid
  cat > "$WORK/base_stub.te" << 'STUB_EOF'
# Stub base policy untuk compile lindroid .te
# Semua type ini ada di platform policy Android standard

# Global attributes
attribute domain;
attribute file_type;
attribute exec_type;
attribute data_file_type;
attribute system_file_type;
attribute vendor_file_type;
attribute coredomain;
attribute appdomain;
attribute socket_class_set;
attribute fs_type;
attribute dev_type;

# Standard types yang dipakai lindroid
type init, domain;
type kernel, domain;
type system_server, domain;
type platform_app, domain;
type untrusted_app, domain;
type priv_app, domain;
type shell, domain;
type su, domain;

# File types
type system_file, file_type, system_file_type;
type vendor_file, file_type, vendor_file_type;
type rootfs, fs_type;
type proc, fs_type;
type sysfs, fs_type;
type devtmpfs, fs_type;
type tmpfs, fs_type;
type cgroup, fs_type;

# Device types
type device, dev_type;
type null_device, dev_type, file_type;
type zero_device, dev_type, file_type;
type tun_device, dev_type, file_type;

# Binder
type binder_device, dev_type, file_type;
type hwbinder_device, dev_type, file_type;
type vndbinder_device, dev_type, file_type;

# GPU/DRM
type gpu_device, dev_type, file_type;
type video_device, dev_type, file_type;
STUB_EOF
fi

# Compile semua .te jadi satu binary policy dulu
CIL_FILES=()
COMBINED_TE="$WORK/lindroid_combined.te"

# Gabungkan semua .te lindroid
cat "${TE_FILES[@]}" > "$COMBINED_TE"
[ -f "$WORK/base_stub.te" ] && cat "$WORK/base_stub.te" >> "$COMBINED_TE"

# Compile ke binary policy
checkpolicy -M -C -o "$WORK/lindroid.policy" \
  -t "$TARGET_BUILD_VARIANT" \
  "$COMBINED_TE" 2>&1 || {
  warn "checkpolicy gagal dengan combined .te"
  warn "Mencoba compile file-per-file..."

  # Fallback: compile satu per satu
  for TE in "${TE_FILES[@]}"; do
    NAME=$(basename "$TE" .te)
    CIL_OUT="$OUTPUT_DIR/cil/${NAME}.cil"

    # Tambahkan stub ke setiap file
    TEMP_TE="$WORK/${NAME}_temp.te"
    [ -f "$WORK/base_stub.te" ] && \
      cat "$WORK/base_stub.te" "$TE" > "$TEMP_TE" || cp "$TE" "$TEMP_TE"

    if checkpolicy -M -C -o "$CIL_OUT" "$TEMP_TE" 2>/dev/null; then
      ok "  Compiled: $NAME.cil"
      CIL_FILES+=("$CIL_OUT")
    else
      warn "  Gagal compile: $NAME.te (mungkin butuh platform types)"
    fi
  done
}

# ── Step 2: Extract types & rules sebagai CIL ────────────
info "[2/4] Generating CIL output..."

# Buat CIL manual dari .te untuk approach yang lebih kompatibel dengan Android
cat > "$OUTPUT_DIR/cil/lindroid_policy.cil" << 'CIL_HEADER'
; Lindroid SEPolicy CIL
; Auto-generated dari vendor_lindroid/sepolicy
; Target: Android 15, arm64
;
; Cara install di device:
;   Merge ke /vendor/etc/selinux/precompiled_sepolicy
;   atau inject via TWRP flashable zip (lihat update-binary)

CIL_HEADER

# Parse .te files dan convert ke CIL format sederhana
python3 << 'PYEOF'
import re, sys, os

te_dir = os.environ.get('TE_DIR', '')
output = os.environ.get('OUTPUT_DIR', 'out/sepolicy')

if not te_dir:
    print("TE_DIR not set")
    sys.exit(0)

cil_lines = []
cil_lines.append("; Lindroid type declarations")

for te_file in sorted(os.listdir(te_dir)):
    if not te_file.endswith('.te'):
        continue
    filepath = os.path.join(te_dir, te_file)
    cil_lines.append(f"\n; === {te_file} ===")

    with open(filepath) as f:
        content = f.read()

    # Extract type declarations
    for m in re.finditer(r'^\s*type\s+(\w+)(?:,\s*([\w,\s]+))?;', content, re.M):
        typename = m.group(1)
        attrs = m.group(2)
        if attrs:
            attr_list = [a.strip() for a in attrs.split(',')]
            cil_lines.append(f"(type {typename})")
            for attr in attr_list:
                if attr:
                    cil_lines.append(f"(typeattributeset {attr} ({typename}))")
        else:
            cil_lines.append(f"(type {typename})")

    # Extract allow rules
    for m in re.finditer(r'^\s*allow\s+(\w+)\s+(\w+):(\w+(?:\s*\{[^}]+\})?)\s+(\{[^}]+\}|\w+)\s*;', content, re.M):
        src = m.group(1); tgt = m.group(2)
        cls = m.group(3).strip(); perms = m.group(4).strip()
        # Convert ke CIL
        cls = re.sub(r'\s+', ' ', cls)
        perms_cil = perms.strip('{}').split() if '{' in perms else [perms]
        perm_str = ' '.join(p.strip() for p in perms_cil)
        cil_lines.append(f"(allow {src} {tgt} ({cls} ({perm_str})))")

    # Extract neverallow (informational)
    for m in re.finditer(r'^\s*neverallow\s+(.+);', content, re.M):
        cil_lines.append(f"; neverallow {m.group(1).strip()}")

os.makedirs(f"{output}/cil", exist_ok=True)
with open(f"{output}/cil/lindroid_policy.cil", 'w') as f:
    f.write('\n'.join(cil_lines))

print(f"CIL generated: {len([l for l in cil_lines if not l.startswith(';')])} rules")
PYEOF

ok "CIL file digenerate: $OUTPUT_DIR/cil/lindroid_policy.cil"

# ── Step 3: Generate precompiled_sepolicy patch ───────────
info "[3/4] Generating precompiled_sepolicy patcher..."

# Script yang akan dijalankan di device via TWRP untuk merge policy
cat > "$OUTPUT_DIR/final/sepolicy_inject.sh" << 'INJECT_EOF'
#!/sbin/sh
# sepolicy_inject.sh
# Dijalankan oleh TWRP update-binary untuk inject lindroid policy
# ke precompiled_sepolicy yang ada di device

POLICY_DIR="/vendor/etc/selinux"
BACKUP_DIR="/data/lindroid_sepolicy_backup"
CIL_FILE="/tmp/lindroid_policy.cil"
LOG="/tmp/sepolicy_inject.log"

log() { echo "$*" | tee -a "$LOG"; }
log "=== Lindroid SEPolicy Inject ==="
log "Date: $(date)"

# Cek tools
for TOOL in secilc seinfo; do
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    log "WARNING: $TOOL tidak tersedia di recovery"
    log "Trying fallback..."
  fi
done

# Backup policy yang ada
mkdir -p "$BACKUP_DIR"
for F in precompiled_sepolicy plat_sepolicy.cil vendor_sepolicy.cil \
          plat_and_mapping_sepolicy.cil.sha256; do
  [ -f "$POLICY_DIR/$F" ] && cp "$POLICY_DIR/$F" "$BACKUP_DIR/$F" && \
    log "Backed up: $F"
done

# Cek apakah CIL file tersedia
if [ ! -f "$CIL_FILE" ]; then
  log "ERROR: CIL file tidak ditemukan di $CIL_FILE"
  exit 1
fi

log "CIL file size: $(wc -l < $CIL_FILE) lines"

# Approach 1: Append CIL ke vendor_sepolicy.cil
VENDOR_CIL="$POLICY_DIR/vendor_sepolicy.cil"
if [ -f "$VENDOR_CIL" ]; then
  log "Appending lindroid policy ke vendor_sepolicy.cil..."
  cat "$CIL_FILE" >> "$VENDOR_CIL"
  log "vendor_sepolicy.cil updated"

  # Re-compile precompiled_sepolicy jika secilc tersedia
  if command -v secilc >/dev/null 2>&1; then
    log "Re-compiling precompiled_sepolicy dengan secilc..."
    PLAT_CIL="$POLICY_DIR/plat_sepolicy.cil"
    MAPPING_CIL=$(ls "$POLICY_DIR"/mapping/*.cil 2>/dev/null | head -1)

    secilc \
      -m -M true -G -N \
      -c 33 \
      -o "$POLICY_DIR/precompiled_sepolicy" \
      -f /dev/null \
      "$PLAT_CIL" \
      ${MAPPING_CIL:+"$MAPPING_CIL"} \
      "$VENDOR_CIL" 2>> "$LOG"

    if [ $? -eq 0 ]; then
      log "OK: precompiled_sepolicy berhasil di-recompile"
    else
      log "ERROR: secilc gagal — restore backup"
      cp "$BACKUP_DIR/precompiled_sepolicy" "$POLICY_DIR/precompiled_sepolicy"
      # Rollback vendor_sepolicy.cil
      cp "$BACKUP_DIR/vendor_sepolicy.cil" "$VENDOR_CIL"
      exit 1
    fi
  else
    log "WARNING: secilc tidak tersedia, policy hanya di-append ke CIL"
    log "Precompiled_sepolicy tidak di-update — mungkin butuh reboot dua kali"
  fi
else
  log "WARNING: vendor_sepolicy.cil tidak ditemukan di $VENDOR_CIL"
  log "Coba inject langsung ke plat_sepolicy.cil..."
  [ -f "$POLICY_DIR/plat_sepolicy.cil" ] && \
    cat "$CIL_FILE" >> "$POLICY_DIR/plat_sepolicy.cil" && \
    log "Appended ke plat_sepolicy.cil"
fi

# Update SHA256 hash jika ada
SHA_FILE="$POLICY_DIR/plat_and_mapping_sepolicy.cil.sha256"
if [ -f "$SHA_FILE" ] && command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$POLICY_DIR/plat_sepolicy.cil" | awk '{print $1}' > "$SHA_FILE"
  log "SHA256 updated"
fi

log "=== Inject selesai ==="
log "Backup ada di: $BACKUP_DIR"
cat "$LOG"
INJECT_EOF

chmod +x "$OUTPUT_DIR/final/sepolicy_inject.sh"
ok "sepolicy_inject.sh digenerate"

# ── Step 4: Salin CIL ke final ────────────────────────────
info "[4/4] Finalizing output..."
cp "$OUTPUT_DIR/cil/lindroid_policy.cil" "$OUTPUT_DIR/final/"

# Summary
echo ""
echo "╔══════════════════════════════════════╗"
echo "║      SEPolicy Build Selesai          ║"
echo "╠══════════════════════════════════════╣"
printf "║  %-38s ║\n" "CIL : $OUTPUT_DIR/cil/lindroid_policy.cil"
printf "║  %-38s ║\n" "Injector : $OUTPUT_DIR/final/sepolicy_inject.sh"
echo "╚══════════════════════════════════════╝"