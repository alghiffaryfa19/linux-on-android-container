#!/bin/bash
# =============================================================================
# build_evdi_dlkm.sh
# Build lindroid-drm-loopback sebagai DLKM (.ko) untuk Android GKI 5.15 arm64
#
# Cara pakai:
#   chmod +x build_evdi_dlkm.sh
#   ./build_evdi_dlkm.sh --kernel-dir /path/to/kernel --output ./out
#
# Kebutuhan:
#   - Kernel source GKI 5.15 (sudah di-configure)
#   - Clang/LLVM toolchain (Android GKI pakai Clang, bukan GCC)
#   - aarch64-linux-gnu cross compiler (untuk beberapa tools)
# =============================================================================

set -e

# ── Defaults ─────────────────────────────────────────────
DRIVER_DIR="$(cd "$(dirname "$0")" && pwd)/lindroid-drm-loopback"
KERNEL_DIR=""
OUT_DIR="$(pwd)/out/evdi-dlkm"
CLANG_DIR=""
CROSS_COMPILE="aarch64-linux-gnu-"
ARCH="arm64"
JOBS=$(nproc)
VERBOSE=0
SIGN_MODULE=0
SKIP_KMI_CHECK=0

# ── Colors ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Usage ────────────────────────────────────────────────
usage() {
cat << EOF
Usage: $0 [OPTIONS]

Options:
  --kernel-dir  PATH    Path ke kernel source GKI 5.15 (wajib)
  --driver-dir  PATH    Path ke lindroid-drm-loopback source
                        (default: ./lindroid-drm-loopback)
  --output      PATH    Output directory (default: ./out/evdi-dlkm)
  --clang-dir   PATH    Path ke Clang toolchain
                        (default: auto-detect dari \$PATH atau AOSP prebuilts)
  --jobs        N       Jumlah parallel jobs (default: $(nproc))
  --sign                Sign module dengan kernel key (butuh kernel certs)
  --skip-kmi-check      Skip KMI symbol whitelist check (tidak dianjurkan)
  --verbose             Verbose build output
  --help                Tampilkan help ini

Contoh:
  # Build dengan kernel source lokal
  $0 --kernel-dir ~/android/kernel/msm-5.15 --output ./out

  # Build dengan AOSP Clang toolchain
  $0 --kernel-dir ~/android/kernel/msm-5.15 \\
     --clang-dir ~/android/prebuilts/clang/host/linux-x86/clang-r450784d

  # Skip KMI check (untuk development/testing)
  $0 --kernel-dir ~/android/kernel/msm-5.15 --skip-kmi-check
EOF
exit 0
}

# ── Parse args ───────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --kernel-dir)  KERNEL_DIR="$2";  shift 2 ;;
    --driver-dir)  DRIVER_DIR="$2";  shift 2 ;;
    --output)      OUT_DIR="$2";     shift 2 ;;
    --clang-dir)   CLANG_DIR="$2";   shift 2 ;;
    --jobs)        JOBS="$2";        shift 2 ;;
    --sign)        SIGN_MODULE=1;    shift ;;
    --skip-kmi-check) SKIP_KMI_CHECK=1; shift ;;
    --verbose)     VERBOSE=1;        shift ;;
    --help|-h)     usage ;;
    *) error "Unknown option: $1" ;;
  esac
done

# ── Validasi ─────────────────────────────────────────────
[ -z "$KERNEL_DIR" ] && error "--kernel-dir wajib diisi\nJalankan: $0 --help"
[ ! -d "$KERNEL_DIR" ] && error "Kernel dir tidak ditemukan: $KERNEL_DIR"
[ ! -f "$KERNEL_DIR/Makefile" ] && error "Bukan kernel source dir: $KERNEL_DIR"

# Clone driver jika belum ada
if [ ! -d "$DRIVER_DIR" ]; then
  info "Driver source tidak ditemukan, mengklone dari GitHub..."
  git clone --depth=1 \
    https://github.com/Linux-on-droid/lindroid-drm-loopback \
    "$DRIVER_DIR" || error "Gagal clone driver source"
fi
[ ! -f "$DRIVER_DIR/Makefile" ] && error "Driver Makefile tidak ditemukan: $DRIVER_DIR"

mkdir -p "$OUT_DIR"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║   Lindroid EVDI DLKM Builder — GKI 5.15 arm64   ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
info "Kernel  : $KERNEL_DIR"
info "Driver  : $DRIVER_DIR"
info "Output  : $OUT_DIR"
info "Jobs    : $JOBS"
echo ""

# ── Cek kernel version ───────────────────────────────────
KVER=$(make -C "$KERNEL_DIR" kernelversion 2>/dev/null || echo "unknown")
info "Kernel version: $KVER"
if [[ "$KVER" != 5.15* ]]; then
  warn "Kernel version $KVER — bukan 5.15.x"
  warn "Script ini dioptimalkan untuk GKI 5.15"
  read -p "Lanjutkan? (y/N) " -n 1 -r; echo
  [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# ── Detect/setup Clang ───────────────────────────────────
setup_clang() {
  if [ -n "$CLANG_DIR" ]; then
    [ ! -d "$CLANG_DIR" ] && error "Clang dir tidak ditemukan: $CLANG_DIR"
    export PATH="$CLANG_DIR/bin:$PATH"
    ok "Clang dari: $CLANG_DIR"
    return
  fi

  # Coba detect dari AOSP prebuilts
  AOSP_CLANG_CANDIDATES=(
    "$HOME/android/prebuilts/clang/host/linux-x86/clang-r450784d"
    "$HOME/android/prebuilts/clang/host/linux-x86/clang-r445002"
    "/usr/lib/llvm-15/bin"
    "/usr/lib/llvm-14/bin"
  )
  for C in "${AOSP_CLANG_CANDIDATES[@]}"; do
    if [ -f "$C/bin/clang" ] || [ -f "$C/clang" ]; then
      export PATH="$C/bin:$C:$PATH"
      ok "Clang auto-detected: $C"
      return
    fi
  done

  # Fallback ke system clang
  if command -v clang &>/dev/null; then
    CLANG_VER=$(clang --version | head -1)
    warn "Menggunakan system clang: $CLANG_VER"
    warn "Untuk GKI, sangat dianjurkan memakai AOSP Clang r450784d"
    warn "Download: https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86"
  else
    error "Clang tidak ditemukan!\nInstall: sudo apt install clang\nAtau gunakan --clang-dir"
  fi
}
setup_clang

# Verifikasi clang ada
command -v clang &>/dev/null || error "clang tidak ada di PATH setelah setup"
CLANG_VER=$(clang --version | head -1)
info "Compiler: $CLANG_VER"

# ── KMI Symbol check ─────────────────────────────────────
check_kmi_symbols() {
  info "Mengecek KMI symbol compatibility..."

  # Symbol yang dipakai driver berdasarkan analisis source
  # Lihat: evdi_lindroid_drv.c, evdi_fb.c, evdi_gem.c, evdi_modeset.c
  DRIVER_SYMBOLS=(
    # DRM core — semua ada di GKI 5.15 KMI
    "drm_dev_alloc"
    "drm_dev_put"
    "drm_dev_register"
    "drm_dev_unregister"
    "drm_ioctl"
    "drm_open"
    "drm_release"
    "drm_read"
    "drm_poll"
    "drm_vblank_init"
    "drm_crtc_vblank_on"
    "drm_crtc_vblank_off"
    "drm_crtc_vblank_get"
    "drm_crtc_vblank_put"
    "drm_crtc_handle_vblank"
    "drm_crtc_arm_vblank_event"
    "drm_kms_helper_poll_init"
    "drm_kms_helper_poll_fini"
    "drm_kms_helper_hotplug_event"
    "drm_mode_config_init"
    "drm_mode_config_cleanup"
    "drm_mode_config_reset"
    "drm_connector_init"
    "drm_connector_cleanup"
    "drm_connector_helper_add"
    "drm_mode_probed_add"
    "drm_mode_set_name"
    "drm_mode_vrefresh"
    "drm_mode_create"
    "drm_framebuffer_init"
    "drm_framebuffer_cleanup"
    "drm_gem_object_init"
    "drm_gem_object_release"
    "drm_gem_object_put"
    "drm_gem_handle_create"
    "drm_gem_mmap"
    "drm_gem_get_pages"
    "drm_gem_put_pages"
    "drm_gem_prime_export"
    "drm_prime_pages_to_sg"
    "drm_atomic_helper_check"
    "drm_atomic_helper_commit"
    "drm_atomic_helper_shutdown"
    "drm_simple_display_pipe_init"
    "drm_helper_probe_single_connector_modes"
    # Platform driver
    "platform_driver_register"
    "platform_driver_unregister"
    "platform_device_register"
    "platform_device_unregister"
    # Linux core — pasti ada di KMI
    "kzalloc"
    "kfree"
    "vmalloc"
    "vfree"
    "mutex_init"
    "mutex_lock"
    "mutex_unlock"
    "mutex_destroy"
    "spin_lock_init"
    "copy_from_user"
    "copy_to_user"
  )

  # Cek apakah ada file KMI whitelist di kernel source
  KMI_FILE="$KERNEL_DIR/android/abi_gki_aarch64.xml"
  KMI_STABLELIST="$KERNEL_DIR/android/abi_gki_aarch64_mitigation"

  if [ ! -f "$KMI_FILE" ]; then
    warn "KMI whitelist tidak ditemukan di: $KMI_FILE"
    warn "Apakah kernel source ini GKI? Lewati KMI check..."
    return 0
  fi

  MISSING_SYMBOLS=()
  for SYM in "${DRIVER_SYMBOLS[@]}"; do
    if ! grep -q "$SYM" "$KMI_FILE" 2>/dev/null; then
      MISSING_SYMBOLS+=("$SYM")
    fi
  done

  if [ ${#MISSING_SYMBOLS[@]} -eq 0 ]; then
    ok "Semua symbol driver ada di KMI whitelist"
  else
    warn "${#MISSING_SYMBOLS[@]} symbol mungkin tidak ada di KMI:"
    for S in "${MISSING_SYMBOLS[@]}"; do
      warn "  - $S"
    done
    warn ""
    warn "Ini bisa menyebabkan build gagal atau modul tidak bisa diload."
    warn "Solusi:"
    warn "  1. Tambahkan symbol ke android/abi_gki_aarch64.xml (butuh rebuild kernel)"
    warn "  2. Gunakan --skip-kmi-check untuk development"
    if [ $SKIP_KMI_CHECK -eq 0 ]; then
      read -p "Lanjutkan build meski ada missing symbol? (y/N) " -n 1 -r; echo
      [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
  fi
}

[ $SKIP_KMI_CHECK -eq 0 ] && check_kmi_symbols || warn "KMI check dilewati (--skip-kmi-check)"

# ── Prepare Makefile untuk DLKM ──────────────────────────
info "Menyiapkan Makefile untuk DLKM build..."

# Buat Makefile wrapper yang kompatibel dengan Android DLKM build system
cat > "$OUT_DIR/Makefile" << 'MAKEFILE_EOF'
# Auto-generated Makefile untuk Lindroid EVDI DLKM
# Kompatibel dengan Android GKI DLKM build system

ccflags-y := -isystem include/uapi/drm
ccflags-y += -DCONFIG_DRM_LINDROID_EVDI=1

# Deteksi kernel 5.15 features
ccflags-y += -DEVDI_HAVE_XARRAY=1
ccflags-y += -DEVDI_HAVE_ATOMIC_HELPERS=1
ccflags-y += -DEVDI_HAVE_DRM_MANAGED=1
ccflags-y += -DEVDI_HAVE_KMS_HELPER=1
ccflags-y += -DEVDI_HAVE_DRM_OPEN_CLOSE=1

evdi-lindroid-y := \
    evdi_connector.o \
    evdi_event.o \
    evdi_fb.o \
    evdi_gem.o \
    evdi_ioctl.o \
    evdi_lindroid_drv.o \
    evdi_modeset.o \
    evdi_sysfs.o

obj-m := evdi-lindroid.o
MAKEFILE_EOF

# Symlink source files ke out dir
for F in "$DRIVER_DIR"/*.c "$DRIVER_DIR"/*.h; do
  [ -f "$F" ] && ln -sf "$F" "$OUT_DIR/$(basename $F)" 2>/dev/null || true
done
mkdir -p "$OUT_DIR/uapi"
[ -f "$DRIVER_DIR/uapi/evdi_drm.h" ] && \
  ln -sf "$DRIVER_DIR/uapi/evdi_drm.h" "$OUT_DIR/uapi/evdi_drm.h" 2>/dev/null || true

ok "Makefile disiapkan"

# ── Build ────────────────────────────────────────────────
info "Memulai build DLKM..."
echo ""

MAKE_OPTS=(
  -C "$KERNEL_DIR"
  M="$OUT_DIR"
  ARCH="$ARCH"
  CC=clang
  LD=ld.lld
  AR=llvm-ar
  NM=llvm-nm
  OBJCOPY=llvm-objcopy
  OBJDUMP=llvm-objdump
  READELF=llvm-readelf
  STRIP=llvm-strip
  CROSS_COMPILE="$CROSS_COMPILE"
  CLANG_TRIPLE="aarch64-linux-gnu-"
  CONFIG_MODULE_SIG=
  CONFIG_MODULE_SIG_ALL=
)

[ $VERBOSE -eq 1 ] && MAKE_OPTS+=(V=1) || MAKE_OPTS+=(V=0)

# Build module
make "${MAKE_OPTS[@]}" -j"$JOBS" modules 2>&1 | \
  if [ $VERBOSE -eq 0 ]; then
    grep -E "^(CC|LD|Building|WARNING|ERROR|error:|warning:)" || true
  else
    cat
  fi

# Cek hasil build
KO_FILE="$OUT_DIR/evdi-lindroid.ko"
if [ ! -f "$KO_FILE" ]; then
  error "Build gagal — evdi-lindroid.ko tidak ditemukan di $OUT_DIR"
fi

ok "Build sukses: $KO_FILE"
echo ""

# ── Module info ──────────────────────────────────────────
info "Module info:"
modinfo "$KO_FILE" 2>/dev/null | grep -E "^(filename|version|description|author|license|vermagic)"
echo ""

# ── Sign module (opsional) ───────────────────────────────
if [ $SIGN_MODULE -eq 1 ]; then
  info "Signing module..."
  SIGNING_KEY="$KERNEL_DIR/certs/signing_key.pem"
  SIGNING_CERT="$KERNEL_DIR/certs/signing_key.x509"
  SIGN_FILE="$KERNEL_DIR/scripts/sign-file"

  if [ ! -f "$SIGNING_KEY" ] || [ ! -f "$SIGNING_CERT" ]; then
    warn "Signing key tidak ditemukan di $KERNEL_DIR/certs/"
    warn "Module tidak di-sign. Boot mungkin perlu lockdown disabled."
  elif [ ! -f "$SIGN_FILE" ]; then
    warn "sign-file script tidak ditemukan"
  else
    "$SIGN_FILE" sha256 "$SIGNING_KEY" "$SIGNING_CERT" "$KO_FILE"
    ok "Module signed"
  fi
fi

# ── Strip debug symbols untuk production ─────────────────
info "Strip debug symbols..."
cp "$KO_FILE" "$OUT_DIR/evdi-lindroid-debug.ko"
llvm-strip --strip-debug "$KO_FILE" 2>/dev/null || \
  aarch64-linux-gnu-strip --strip-debug "$KO_FILE" 2>/dev/null || \
  warn "Strip gagal — modul masih mengandung debug symbols"

KO_SIZE=$(du -sh "$KO_FILE" | cut -f1)
ok "Final module: $KO_FILE ($KO_SIZE)"

# ── Generate Magisk module ────────────────────────────────
info "Membuat Magisk module installer..."

MAGISK_DIR="$OUT_DIR/magisk-module"
mkdir -p "$MAGISK_DIR/META-INF/com/google/android"

# module.prop
cat > "$MAGISK_DIR/module.prop" << EOF
id=lindroid_evdi_dlkm
name=Lindroid EVDI DLKM Driver
version=v1.0-$(date +%Y%m%d)
versionCode=$(date +%Y%m%d)
author=lindroid-port
description=EVDI virtual display driver untuk Lindroid (GKI 5.15 arm64 DLKM)
EOF

# Salin .ko ke module
mkdir -p "$MAGISK_DIR/system/lib/modules"
cp "$KO_FILE" "$MAGISK_DIR/system/lib/modules/evdi-lindroid.ko"

# service.sh — load modul saat boot
cat > "$MAGISK_DIR/service.sh" << 'SERVICE_EOF'
#!/system/bin/sh
# Load EVDI DLKM driver

MODDIR="${0%/*}"
KO="$MODDIR/system/lib/modules/evdi-lindroid.ko"
LOG="/data/lindroid/evdi.log"

mkdir -p /data/lindroid
echo "=== EVDI load: $(date) ===" >> "$LOG"

# Cek apakah sudah loaded
if lsmod 2>/dev/null | grep -q "evdi_lindroid"; then
  echo "[OK] evdi-lindroid sudah loaded" >> "$LOG"
  exit 0
fi

if [ ! -f "$KO" ]; then
  echo "[!!] $KO tidak ditemukan" >> "$LOG"
  exit 1
fi

# Cek DRM subsystem tersedia
if [ ! -d /sys/bus/platform/drivers ]; then
  echo "[!!] Platform bus tidak tersedia" >> "$LOG"
  exit 1
fi

# Load module
insmod "$KO" 2>> "$LOG"
if [ $? -eq 0 ]; then
  echo "[OK] evdi-lindroid loaded" >> "$LOG"
  # Register platform device untuk EVDI
  # Ini biasanya dilakukan via init.rc di ROM, tapi bisa manual:
  echo "evdi-lindroid" > /sys/bus/platform/drivers/evdi-lindroid/uevent 2>/dev/null || true
  setprop vendor.lindroid.evdi.loaded 1
  ls /dev/dri/ >> "$LOG" 2>&1
else
  echo "[!!] insmod gagal — cek kernel version dan KMI compatibility" >> "$LOG"
  setprop vendor.lindroid.evdi.loaded 0
fi
SERVICE_EOF

# customize.sh
cat > "$MAGISK_DIR/customize.sh" << 'CUST_EOF'
#!/system/bin/sh
SKIPUNZIP=1

ui_print "========================================"
ui_print "  Lindroid EVDI DLKM Driver"
ui_print "========================================"

# Cek arch
[ "$(uname -m)" != "aarch64" ] && ui_print "[!] Bukan arm64!" && abort

# Extract files
unzip -o "$ZIPFILE" 'system/*' -d "$MODPATH" >&2
unzip -o "$ZIPFILE" 'service.sh' -d "$MODPATH" >&2

# Set permissions
set_perm_recursive "$MODPATH/system/lib/modules" root root 0755 0644
set_perm "$MODPATH/service.sh" root root 0755

ui_print "[*] Driver akan diload saat boot"
ui_print "[*] Cek /data/lindroid/evdi.log setelah reboot"
ui_print ""
CUST_EOF

# META-INF
echo "# dummy" > "$MAGISK_DIR/META-INF/com/google/android/updater-script"
cat > "$MAGISK_DIR/META-INF/com/google/android/update-binary" << 'UEOF'
#!/system/bin/sh
SKIPUNZIP=1
. /data/adb/magisk/util_functions.sh
. /data/adb/magisk/module_installer.sh
UEOF

# Zip module
MAGISK_ZIP="$OUT_DIR/lindroid-evdi-dlkm-$(date +%Y%m%d).zip"
cd "$MAGISK_DIR"
zip -r "$MAGISK_ZIP" . -x "*.DS_Store" >/dev/null
ok "Magisk module: $MAGISK_ZIP"
cd - >/dev/null

# ── Summary ──────────────────────────────────────────────
echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║                 BUILD SUKSES!                      ║"
echo "╠════════════════════════════════════════════════════╣"
printf "║  %-50s ║\n" "Kernel module  : $KO_FILE"
printf "║  %-50s ║\n" "Size           : $KO_SIZE"
printf "║  %-50s ║\n" "Magisk module  : $(basename $MAGISK_ZIP)"
echo "╠════════════════════════════════════════════════════╣"
echo "║  Cara install:                                     ║"
echo "║  1. Flash lindroid-evdi-dlkm-*.zip via Magisk      ║"
echo "║  2. Reboot                                         ║"
echo "║  3. Cek: lsmod | grep evdi                        ║"
echo "║     atau: ls /dev/dri/                             ║"
echo "║  4. Log: cat /data/lindroid/evdi.log               ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
