#!/bin/bash
set -e

#===============================================================================
# OpenClaw Installer for Raspberry Pi 5 GenAI Kit
# Target: CanaKit Raspberry Pi 5 8GB with Hailo 10H AI HAT+ 2
# OS: Raspberry Pi OS Trixie (Debian 13)
#
# Usage:
#   ./install-openclaw-rpi5.sh                  # Online install (requires internet)
#   ./install-openclaw-rpi5.sh --offline        # Offline install (uses bundled deps)
#   ./install-openclaw-rpi5.sh --prepare-offline # Download deps for offline use
#   ./install-openclaw-rpi5.sh --non-interactive # Use defaults, no prompts
#===============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCLAW_WORKSPACE="$HOME/.openclaw/workspace"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
MOLTBOOK_CONFIG_DIR="$HOME/.config/moltbook"
OFFLINE_DIR="$SCRIPT_DIR/offline_bundle"
HAILO_LOCAL_PACKAGE_DIR="${HAILO_LOCAL_PACKAGE_DIR:-$HOME/Downloads}"

# Keep repeated CLI runs snappy on small hosts and avoid respawn churn.
export NODE_COMPILE_CACHE="${NODE_COMPILE_CACHE:-/var/tmp/openclaw-compile-cache}"
mkdir -p "$NODE_COMPILE_CACHE"
export OPENCLAW_NO_RESPAWN="${OPENCLAW_NO_RESPAWN:-1}"

# Parse arguments
OFFLINE_MODE=false
PREPARE_OFFLINE=false
NON_INTERACTIVE=${NON_INTERACTIVE:-false}
USE_SANITIZER_PROXY_ON_OLLAMA=${USE_SANITIZER_PROXY_ON_OLLAMA:-true}
USE_OPENCLAW_TOOLS=${USE_OPENCLAW_TOOLS:-true}
CLAW_FLAVOR=${CLAW_FLAVOR:-openclaw}
UNIFIED_FACADE_HTTP_PORT=${UNIFIED_FACADE_HTTP_PORT:-8787}
if [[ -z "${OPENCLAW_FIXED_TOKEN:-}" ]]; then
    # Generate a unique gateway token per install. Avoids shipping a shared
    # hardcoded credential in the public repo. Override via OPENCLAW_FIXED_TOKEN.
    OPENCLAW_FIXED_TOKEN="$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 24)"
    [[ -z "$OPENCLAW_FIXED_TOKEN" ]] && OPENCLAW_FIXED_TOKEN="openclaw-$(date +%s)"
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --offline)
            OFFLINE_MODE=true
            shift
            ;;
        --prepare-offline)
            PREPARE_OFFLINE=true
            shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--offline | --prepare-offline | --non-interactive]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_step() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ "$NON_INTERACTIVE" == "true" || ! -t 0 ]]; then
        [[ "$default" =~ ^[Yy]$ ]]
        return
    fi

    if [[ "$default" == "y" ]]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi
    
    [[ "$response" =~ ^[Yy] ]]
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local response

    if [[ "$NON_INTERACTIVE" == "true" || ! -t 0 ]]; then
        echo "$default"
        return
    fi

    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        read -p "$prompt: " response
        echo "$response"
    fi
}

extract_semver() {
    printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

find_latest_local_hailo_artifact() {
    local search_dir="$1"
    local pattern="$2"
    local -a files=()
    local file

    if [[ ! -d "$search_dir" ]]; then
        return 1
    fi

    shopt -s nullglob
    for file in "$search_dir"/$pattern; do
        [[ "$file" == *" copy"* ]] && continue
        files+=("$file")
    done
    shopt -u nullglob

    if [[ ${#files[@]} -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "${files[@]}" | sort -V | tail -n 1
}

detect_required_libhailort() {
    local hailo_ollama_bin
    hailo_ollama_bin=$(command -v hailo-ollama 2>/dev/null || true)
    if [[ -z "$hailo_ollama_bin" ]]; then
        return 1
    fi

    ldd "$hailo_ollama_bin" 2>/dev/null | awk '/libhailort\.so/{print $1; exit}'
}

patch_hailort_pcie_driver_for_kernel() {
    local monitor_file="/usr/src/hailort-pcie-driver/linux/vdma/monitor.c"
    if [[ ! -f "$monitor_file" ]]; then
        return 0
    fi

    print_step "Applying kernel compatibility patch for hailort-pcie-driver..."
    sudo python3 - <<'PY'
from pathlib import Path

path = Path("/usr/src/hailort-pcie-driver/linux/vdma/monitor.c")
text = path.read_text()

if '#include <linux/version.h>' not in text:
    text = text.replace('#include "monitor.h"\n', '#include "monitor.h"\n#include <linux/version.h>\n')

if 'timer_delete_sync(&monitor->timer);' not in text and 'del_timer_sync(&monitor->timer);' in text:
    text = text.replace(
        '    del_timer_sync(&monitor->timer);',
        '    #if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n'
        '    timer_delete_sync(&monitor->timer);\n'
        '    #else\n'
        '    del_timer_sync(&monitor->timer);\n'
        '    #endif'
    )

path.write_text(text)
PY
}

reset_hailo_pcie_device() {
    local hailo_pci_addr
    hailo_pci_addr=$(lspci -Dn | awk '/1e60:45c4/{print $1; exit}')

    if [[ -z "$hailo_pci_addr" ]]; then
        hailo_pci_addr=$(lspci -Dn | awk '/Hailo/{print $1; exit}')
    fi

    sudo modprobe -r hailo1x_pci 2>/dev/null || true

    if [[ -n "$hailo_pci_addr" ]] && [[ -e "/sys/bus/pci/devices/${hailo_pci_addr}/reset" ]]; then
        sudo sh -c "echo 1 > /sys/bus/pci/devices/${hailo_pci_addr}/reset" || true
    fi

    sleep 1
    sudo modprobe hailo1x_pci 2>/dev/null || sudo modprobe hailo_pci 2>/dev/null || true
}

install_local_hailo_stack_from_dir() {
    local search_dir="$1"
    local hailort_deb
    local driver_deb
    local genai_deb
    local tappas_core_deb
    local local_version
    local -a local_debs=()

    hailort_deb=$(find_latest_local_hailo_artifact "$search_dir" 'hailort_[0-9]*.[0-9]*.[0-9]*_arm64.deb' || true)
    driver_deb=$(find_latest_local_hailo_artifact "$search_dir" 'hailort-pcie-driver_[0-9]*.[0-9]*.[0-9]*_all.deb' || true)
    genai_deb=$(find_latest_local_hailo_artifact "$search_dir" 'hailo_gen_ai_model_zoo_[0-9]*.[0-9]*.[0-9]*_arm64.deb' || true)
    tappas_core_deb=$(find_latest_local_hailo_artifact "$search_dir" 'hailo-tappas-core_[0-9]*.[0-9]*.[0-9]*_arm64.deb' || true)

    if [[ -z "$hailort_deb" || -z "$driver_deb" || -z "$genai_deb" ]]; then
        return 1
    fi

    local_version=$(extract_semver "$genai_deb")
    [[ -z "$local_version" ]] && local_version=$(extract_semver "$hailort_deb")

    print_step "Updating Hailo stack from local packages in $search_dir (target ${local_version:-latest})..."
    local_debs=("$hailort_deb" "$genai_deb")
    if [[ -n "$tappas_core_deb" ]]; then
        local_debs+=("$tappas_core_deb")
    fi

    sudo apt update
    sudo apt install -y dkms build-essential

    sudo systemctl stop hailo-ollama.service 2>/dev/null || true
    sudo systemctl stop hailo-sanitize-proxy.service 2>/dev/null || true

    sudo apt install -y "${local_debs[@]}"
    sudo apt purge -y h10-hailort-pcie-driver 2>/dev/null || true
    sudo apt purge -y hailort-pcie-driver 2>/dev/null || true
    sudo dpkg --unpack "$driver_deb"
    patch_hailort_pcie_driver_for_kernel

    if ! sudo dpkg --configure hailort-pcie-driver; then
        print_warn "hailort-pcie-driver configuration failed; falling back to h10-hailort-pcie-driver"
        sudo apt purge -y hailort-pcie-driver || true
        sudo apt install -y h10-hailort-pcie-driver || true
    fi

    sudo apt install -f -y
    reset_hailo_pcie_device

    if command -v hailortcli &> /dev/null; then
        if hailortcli scan 2>/dev/null | grep -q "Device:"; then
            print_step "Hailo device detected by HailoRT after local package update"
        else
            print_warn "HailoRT cannot see a device yet. A reboot may be required."
        fi
    fi

    print_step "Local Hailo package update complete"
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\/&\\]/\\&/g'
}

ensure_sudo_ready() {
    if sudo -n true 2>/dev/null; then
        return
    fi

    if [[ "$NON_INTERACTIVE" == "true" || ! -t 0 ]]; then
        print_error "sudo credentials are required, but non-interactive mode cannot prompt for password."
        print_warn "Run 'sudo -v' once before starting installer, or configure passwordless sudo."
        exit 1
    fi

    print_step "Requesting sudo credentials..."
    sudo -v
}

repair_local_cli_pairing_scopes() {
    local devices_dir="$HOME/.openclaw/devices"
    local paired_file="$devices_dir/paired.json"
    local pending_file="$devices_dir/pending.json"

    if [[ ! -f "$paired_file" ]]; then
        return
    fi

    print_step "Repairing local OpenClaw CLI pairing scopes..."
    python3 - <<'PY'
import json, os, shutil, time

devices_dir = os.path.expanduser("~/.openclaw/devices")
paired_file = os.path.join(devices_dir, "paired.json")
pending_file = os.path.join(devices_dir, "pending.json")
full_scopes = [
    "operator.admin",
    "operator.read",
    "operator.write",
    "operator.approvals",
    "operator.pairing",
]

def backup(path):
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.bak.{int(time.time())}")

backup(paired_file)
backup(pending_file)

with open(paired_file, "r", encoding="utf-8") as f:
    paired = json.load(f)

changed = False
for _, entry in list(paired.items()):
    if not isinstance(entry, dict):
        continue
    if entry.get("clientId") != "cli" or entry.get("clientMode") != "cli":
        continue
    if entry.get("scopes") != full_scopes:
        entry["scopes"] = full_scopes[:]
        changed = True
    if entry.get("approvedScopes") != full_scopes:
        entry["approvedScopes"] = full_scopes[:]
        changed = True
    tokens = entry.get("tokens")
    if isinstance(tokens, dict) and isinstance(tokens.get("operator"), dict):
        if tokens["operator"].get("scopes") != full_scopes:
            tokens["operator"]["scopes"] = full_scopes[:]
            changed = True

if changed:
    with open(paired_file, "w", encoding="utf-8") as f:
        json.dump(paired, f, indent=2)

with open(pending_file, "w", encoding="utf-8") as f:
    json.dump({}, f, indent=2)
PY
}

normalize_claw_flavor() {
    local raw="${1:-openclaw}"
    raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$raw" in
        openclaw|picoclaw|zeroclaw|nanobot|moltis|ironclaw|nullclaw)
            printf '%s' "$raw"
            ;;
        *)
            printf '%s' "openclaw"
            ;;
    esac
}

prompt_claw_flavor() {
    CLAW_FLAVOR=$(normalize_claw_flavor "$CLAW_FLAVOR")
    echo ""
    echo "Select assistant flavor to install:"
    echo "  1) OpenClaw (TypeScript)"
    echo "  2) PicoClaw (Go)"
    echo "  3) ZeroClaw (Rust)"
    echo "  4) Nanobot (Python)"
    echo "  5) Moltis (Rust)"
    echo "  6) IronClaw (Rust)"
    echo "  7) NullClaw (Zig)"
    echo ""
    local default_choice="1"
    case "$CLAW_FLAVOR" in
        picoclaw) default_choice="2" ;;
        zeroclaw) default_choice="3" ;;
        nanobot) default_choice="4" ;;
        moltis) default_choice="5" ;;
        ironclaw) default_choice="6" ;;
        nullclaw) default_choice="7" ;;
    esac

    local choice
    choice=$(prompt_input "Choice" "$default_choice")
    case "$choice" in
        2) CLAW_FLAVOR="picoclaw" ;;
        3) CLAW_FLAVOR="zeroclaw" ;;
        4) CLAW_FLAVOR="nanobot" ;;
        5) CLAW_FLAVOR="moltis" ;;
        6) CLAW_FLAVOR="ironclaw" ;;
        7) CLAW_FLAVOR="nullclaw" ;;
        *) CLAW_FLAVOR="openclaw" ;;
    esac
    print_step "Selected assistant flavor: $CLAW_FLAVOR"
}

get_hailo_openai_base_url() {
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" == "true" ]]; then
        printf '%s' "http://127.0.0.1:8081/v1"
    else
        printf '%s' "http://127.0.0.1:8000/v1"
    fi
}

get_hailo_chat_completions_url() {
    printf '%s/chat/completions' "$(get_hailo_openai_base_url)"
}

write_unified_facade_runtime_profile() {
    local facade_runtime_path="$SCRIPT_DIR/templates/unified-chat-runtime.json"
    local ollama_chat_url
    ollama_chat_url=$(get_hailo_chat_completions_url)
    local active_mode="ollama"
    local extra_mode_json="[]"

    if [[ "$CLAW_FLAVOR" == "picoclaw" ]]; then
        active_mode="picoclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "picoclaw-local",
    "title": "PicoClaw Local",
    "subtitle": "PicoClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "zeroclaw" ]]; then
        active_mode="zeroclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "zeroclaw-local",
    "title": "ZeroClaw Local",
    "subtitle": "ZeroClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "nanobot" ]]; then
        active_mode="nanobot-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "nanobot-local",
    "title": "Nanobot Local",
    "subtitle": "Nanobot + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "moltis" ]]; then
        active_mode="moltis-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "moltis-local",
    "title": "Moltis Local",
    "subtitle": "Moltis + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "ironclaw" ]]; then
        active_mode="ironclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "ironclaw-local",
    "title": "IronClaw Local",
    "subtitle": "IronClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    elif [[ "$CLAW_FLAVOR" == "nullclaw" ]]; then
        active_mode="nullclaw-local"
        extra_mode_json=$(cat <<EOF
[
  {
    "id": "nullclaw-local",
    "title": "NullClaw Local",
    "subtitle": "NullClaw + local Hailo model",
    "kind": "http-chat",
    "endpoint": "$ollama_chat_url",
    "model": "$HAILO_MODEL"
  }
]
EOF
)
    fi

    cat > "$facade_runtime_path" <<EOF
{
  "schemaVersion": 1,
  "flavor": "$CLAW_FLAVOR",
  "gatewayUrl": "ws://127.0.0.1:18789",
  "ollamaUrl": "$ollama_chat_url",
  "ollamaModel": "$HAILO_MODEL",
  "activeMode": "$active_mode",
  "extraModes": $extra_mode_json
}
EOF
    print_step "Wrote unified facade runtime profile: $facade_runtime_path"
}

install_unified_facade_http_service() {
    local facade_server_src="$SCRIPT_DIR/scripts/unified-chat-facade-httpd.py"
    local facade_server_dst="/usr/local/bin/unified-chat-facade-httpd.py"

    if [[ ! -f "$facade_server_src" ]]; then
        print_warn "Unified facade server script not found: $facade_server_src"
        return 0
    fi

    print_step "Installing unified facade HTTP server systemd service (debug logs enabled)..."
    sudo cp "$facade_server_src" "$facade_server_dst"
    sudo chmod +x "$facade_server_dst"

    sudo tee /etc/systemd/system/unified-chat-facade.service > /dev/null <<EOF
[Unit]
Description=Unified Chat Facade HTTP Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=$USER
Group=$USER
WorkingDirectory=$SCRIPT_DIR
Environment=PYTHONUNBUFFERED=1
Environment=UNIFIED_CHAT_FACADE_LOG_LEVEL=DEBUG
ExecStart=/usr/bin/python3 /usr/local/bin/unified-chat-facade-httpd.py --bind 127.0.0.1 --port $UNIFIED_FACADE_HTTP_PORT --directory $SCRIPT_DIR --log-level DEBUG
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
SyslogIdentifier=unified-chat-facade

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable unified-chat-facade.service
    sudo systemctl restart unified-chat-facade.service

    sleep 1
    if sudo systemctl is-active --quiet unified-chat-facade.service; then
        print_step "Unified facade HTTP server running on http://127.0.0.1:$UNIFIED_FACADE_HTTP_PORT"
    else
        print_warn "Unified facade HTTP server failed to start — check: journalctl -u unified-chat-facade -n 100"
    fi
}

#===============================================================================
# Homebrew (Linuxbrew) - required by some OpenClaw tooling on Raspberry Pi
#===============================================================================

ensure_homebrew() {
    if command -v brew &> /dev/null; then
        return 0
    fi

    print_warn "Homebrew (brew) not found"

    if [[ "$NON_INTERACTIVE" == "true" || ! -t 0 ]]; then
        print_warn "Non-interactive mode enabled - skipping Homebrew install"
        print_warn "If a command later requires brew, run the installer interactively once to bootstrap it."
        return 0
    fi

    if [[ "$OFFLINE_MODE" == "true" ]]; then
        print_warn "Offline mode enabled - skipping Homebrew install"
        print_warn "If OpenClaw fails due to missing brew, re-run with internet access"
        return 0
    fi

    print_step "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    if [[ -d "$HOME/.linuxbrew" ]]; then
        eval "$("$HOME/.linuxbrew/bin/brew" shellenv)"
    elif [[ -d "/home/linuxbrew/.linuxbrew" ]]; then
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    fi

    if command -v brew &> /dev/null; then
        if ! grep -q 'brew shellenv' "$HOME/.bashrc" 2>/dev/null; then
            echo 'eval "$("$(brew --prefix)"/bin/brew shellenv)"' >> "$HOME/.bashrc"
        fi
        brew -h &> /dev/null || true
        print_step "Homebrew installed"
    else
        print_warn "Homebrew install did not add brew to PATH (may require re-login)"
    fi
}

#===============================================================================
# Build HailoRT from source (when apt version is incompatible)
#===============================================================================

build_hailort_from_source() {
    local HAILORT_VERSION="${1:-v5.3.0}"
    local HAILORT_SEMVER="${HAILORT_VERSION#v}"
    
    print_header "Building HailoRT $HAILORT_VERSION from source"
    print_warn "This is required because hailo-ollama needs a newer libhailort version."
    echo ""
    
    # Install build dependencies
    print_step "Installing build dependencies..."
    sudo apt update
    sudo apt install -y build-essential cmake pkg-config \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        linux-headers-$(uname -r) python3-pip python3-venv git
    
    # Clone HailoRT
    print_step "Cloning HailoRT repository..."
    local BUILD_DIR="$HOME/.openclaw/hailort-build"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    
    if [[ -d "hailort" ]]; then
        cd hailort
        git fetch --tags
    else
        git clone https://github.com/hailo-ai/hailort.git
        cd hailort
    fi
    
    git checkout "$HAILORT_VERSION"
    
    # Build and install
    print_step "Building HailoRT (this may take several minutes)..."
    cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release
    sudo cmake --build build --config release --target install
    
    # Update library cache
    sudo ldconfig
    
    # Verify
    if [[ -f /usr/local/lib/libhailort.so ]] || [[ -f "/usr/lib/libhailort.so.${HAILORT_SEMVER}" ]] || [[ -f "/usr/local/lib/libhailort.so.${HAILORT_SEMVER}" ]]; then
        print_step "HailoRT $HAILORT_VERSION built and installed successfully"
        return 0
    else
        print_error "HailoRT build may have failed - library not found"
        return 1
    fi
}

#===============================================================================
# Prepare Offline Bundle (run on machine with internet)
#===============================================================================

prepare_offline_bundle() {
    print_header "Preparing Offline Bundle"
    
    mkdir -p "$OFFLINE_DIR"
    cd "$OFFLINE_DIR"
    
    # Node.js 22 ARM64 binary
    print_step "Downloading Node.js 22 ARM64..."
    NODE_VERSION="22.11.0"
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.xz" -o node-v${NODE_VERSION}-linux-arm64.tar.xz
    
    # Docker packages for Debian Trixie ARM64
    print_step "Downloading Docker packages..."
    mkdir -p docker_debs
    cd docker_debs
    
    # Get Docker GPG key
    curl -fsSL https://download.docker.com/linux/debian/gpg -o docker.gpg
    
    # Download Docker .deb packages (latest versions for Trixie ARM64)
    BASE_URL="https://download.docker.com/linux/debian/dists/trixie/pool/stable/arm64"
    
    print_step "Downloading containerd.io..."
    curl -fsSL "${BASE_URL}/containerd.io_2.2.1-1~debian.13~trixie_arm64.deb" -o containerd.io_arm64.deb || print_warn "containerd download failed"
    
    print_step "Downloading docker-ce-cli..."
    curl -fsSL "${BASE_URL}/docker-ce-cli_29.2.1-1~debian.13~trixie_arm64.deb" -o docker-ce-cli_arm64.deb || print_warn "docker-ce-cli download failed"
    
    print_step "Downloading docker-ce..."
    curl -fsSL "${BASE_URL}/docker-ce_29.2.1-1~debian.13~trixie_arm64.deb" -o docker-ce_arm64.deb || print_warn "docker-ce download failed"
    
    print_step "Downloading docker-buildx-plugin..."
    curl -fsSL "${BASE_URL}/docker-buildx-plugin_0.31.1-1~debian.13~trixie_arm64.deb" -o docker-buildx-plugin_arm64.deb || print_warn "buildx download failed"
    
    print_step "Downloading docker-compose-plugin..."
    curl -fsSL "${BASE_URL}/docker-compose-plugin_5.0.2-1~debian.13~trixie_arm64.deb" -o docker-compose-plugin_arm64.deb || print_warn "compose download failed"
    
    cd "$OFFLINE_DIR"
    
    # OpenClaw npm package
    print_step "Downloading OpenClaw npm package..."
    npm pack openclaw@latest
    
    # Hailo software packages
    print_header "Hailo Software Packages"
    echo ""
    echo "For offline installation, you need to manually download Hailo packages."
    echo ""
    echo "Required packages:"
    echo "  1. hailo-h10-all (from Raspberry Pi apt repository, for AI HAT+ 2 / Hailo-10H)"
    echo "  2. hailo_gen_ai_model_zoo (from Hailo Developer Zone)"
    echo ""
    echo "Steps to prepare Hailo packages:"
    echo "  1. On a Pi with internet, run: apt download hailo-h10-all"
    echo "  2. Download GenAI Model Zoo from: https://hailo.ai/developer-zone/software-downloads/"
    echo "  3. Copy .deb files to: $OFFLINE_DIR/hailo_debs/"
    echo ""
    
    mkdir -p hailo_debs
    
    # Try to download Hailo-10H package if apt is available
    if command -v apt &> /dev/null; then
        print_step "Attempting to download hailo-h10-all package..."
        cd hailo_debs
        apt download hailo-h10-all 2>/dev/null || print_warn "hailo-h10-all not available in apt (may need to run on Pi)"
        apt download dkms 2>/dev/null || true
        cd "$OFFLINE_DIR"
    fi
    
    # Hailo model selection and download
    print_header "Select Hailo Model for Offline Bundle"
    
    echo "Available Hailo-optimized models:"
    echo ""
    echo "  1) qwen3:1.7b               - Newest model in GenAI 5.3.0 (recommended)"
    echo "  2) qwen2.5-coder:1.5b       - Optimized for coding"
    echo "  3) qwen2.5:1.5b             - Improved general purpose"
    echo "  4) qwen2:1.5b               - General purpose"
    echo "  5) llama3.2:1b              - Meta's compact model"
    echo "  6) deepseek_r1:1.5b         - Reasoning-focused model"
    echo "  7) All models               - Download all available models"
    echo "  8) Skip                     - Don't download any models"
    echo ""
    
    MODEL_CHOICE=$(prompt_input "Select model to bundle" "1")
    
    mkdir -p hailo_models
    
    case $MODEL_CHOICE in
        1) MODELS_TO_DOWNLOAD="qwen3:1.7b" ;;
        2) MODELS_TO_DOWNLOAD="qwen2.5-coder:1.5b" ;;
        3) MODELS_TO_DOWNLOAD="qwen2.5:1.5b" ;;
        4) MODELS_TO_DOWNLOAD="qwen2:1.5b" ;;
        5) MODELS_TO_DOWNLOAD="llama3.2:1b" ;;
        6) MODELS_TO_DOWNLOAD="deepseek_r1:1.5b" ;;
        7) MODELS_TO_DOWNLOAD="qwen3:1.7b qwen2.5-coder:1.5b qwen2.5:1.5b qwen2:1.5b llama3.2:1b deepseek_r1:1.5b" ;;
        8) MODELS_TO_DOWNLOAD="" ;;
        *) MODELS_TO_DOWNLOAD="qwen3:1.7b" ;;
    esac
    
    # Ask about RAG embedding model
    echo ""
    if prompt_yes_no "Include nomic-embed-text for RAG (document search)?"; then
        MODELS_TO_DOWNLOAD="$MODELS_TO_DOWNLOAD nomic-embed-text"
    fi
    
    if [[ -n "$MODELS_TO_DOWNLOAD" ]]; then
        if command -v hailo-ollama &> /dev/null; then
            print_step "Starting hailo-ollama to download models..."
            hailo-ollama &
            HAILO_PID=$!
            sleep 3
            
            for model in $MODELS_TO_DOWNLOAD; do
                print_step "Downloading $model..."
                curl -s http://localhost:8000/api/pull -H 'Content-Type: application/json' -d "{\"model\":\"$model\",\"stream\":true}" || {
                    print_warn "Failed to download $model"
                }
            done
            
            # Copy downloaded models to offline bundle
            print_step "Copying models to offline bundle..."
            if [[ -d ~/.hailo-ollama/models ]]; then
                cp -r ~/.hailo-ollama/models/* "$OFFLINE_DIR/hailo_models/" 2>/dev/null || true
            fi
            
            # Stop hailo-ollama
            kill $HAILO_PID 2>/dev/null || true
        else
            print_warn "hailo-ollama not found on this machine."
            echo ""
            echo "To download Hailo models, you need a machine with hailo-ollama installed."
            echo "After installing hailo-ollama, run:"
            echo ""
            for model in $MODELS_TO_DOWNLOAD; do
                echo "  hailo-ollama pull $model"
            done
            echo ""
            echo "Then copy ~/.hailo-ollama/models/* to $OFFLINE_DIR/hailo_models/"
        fi
    else
        print_step "Skipping model download"
    fi
    
    # Create manifest
    cat > manifest.json << EOF
{
  "created": "$(date -Iseconds)",
  "node_version": "${NODE_VERSION}",
  "arch": "arm64",
  "os": "debian-trixie",
  "models_bundled": "$MODELS_TO_DOWNLOAD",
  "contents": [
    "node-v${NODE_VERSION}-linux-arm64.tar.xz",
    "docker_debs/",
    "openclaw-*.tgz",
    "hailo_models/"
  ]
}
EOF
    
    print_step "Offline bundle created at: $OFFLINE_DIR"
    echo ""
    echo "Bundle contents:"
    ls -la "$OFFLINE_DIR"
    echo ""
    if [[ -d "$OFFLINE_DIR/hailo_models" ]]; then
        echo "Hailo models:"
        ls -la "$OFFLINE_DIR/hailo_models/" 2>/dev/null || echo "  (none)"
    fi
    echo ""
    print_warn "Copy the entire 'offline_bundle' directory to the Pi along with the installer."
}

#===============================================================================
# Phase 1: System Preparation
#===============================================================================

phase1_system_prep() {
    print_header "Phase 1: System Preparation (Raspberry Pi OS Trixie)"
    
    # Check if running on Raspberry Pi OS Trixie
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$VERSION_CODENAME" != "trixie" ]]; then
            print_warn "Expected Raspberry Pi OS Trixie, found: $VERSION_CODENAME"
            if ! prompt_yes_no "Continue anyway?"; then
                exit 1
            fi
        else
            print_step "Detected Raspberry Pi OS Trixie"
        fi
    fi
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        phase1_system_prep_offline
    else
        phase1_system_prep_online
    fi
}

phase1_system_prep_online() {
    # Update system
    print_step "Updating system packages..."
    sudo apt update && sudo apt full-upgrade -y
    
    # Install Node.js 22+ via n version manager
    print_step "Installing Node.js 22+ (via n version manager)..."
    sudo apt install -y nodejs npm
    sudo npm install -g n
    sudo n stable
    hash -r
    
    NODE_VERSION=$(node -v 2>/dev/null || echo "not installed")
    print_step "Node.js version: $NODE_VERSION"
    
    # Docker is OPTIONAL now: the core runtime (Hailo + proxy + facade + OpenClaw)
    # and the Signal channel (native signal-cli) need NO Docker. Only the optional
    # Matrix homeserver does. Install only if explicitly requested (INSTALL_DOCKER=true).
    if [[ "${INSTALL_DOCKER:-false}" != "true" ]]; then
        print_step "Skipping Docker install (not required; set INSTALL_DOCKER=true for the Matrix channel)"
    elif ! command -v docker &> /dev/null; then
        print_step "Installing Docker (Trixie-specific method)..."
        sudo apt install -y ca-certificates curl gnupg
        
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable docker && sudo systemctl start docker
        sudo usermod -aG docker $USER
        
        print_step "Docker installed successfully"
    else
        print_step "Docker already installed"
    fi
}

phase1_system_prep_offline() {
    print_step "Installing from offline bundle..."
    
    if [[ ! -d "$OFFLINE_DIR" ]]; then
        print_error "Offline bundle not found at $OFFLINE_DIR"
        print_error "Run './install-openclaw-rpi5.sh --prepare-offline' on a machine with internet first."
        exit 1
    fi
    
    # Install Node.js from bundled tarball
    print_step "Installing Node.js 22 from offline bundle..."
    NODE_TARBALL=$(ls "$OFFLINE_DIR"/node-v*-linux-arm64.tar.xz 2>/dev/null | head -1)
    if [[ -f "$NODE_TARBALL" ]]; then
        sudo tar -xJf "$NODE_TARBALL" -C /usr/local --strip-components=1
        hash -r
        NODE_VERSION=$(node -v 2>/dev/null || echo "not installed")
        print_step "Node.js version: $NODE_VERSION"
    else
        print_error "Node.js tarball not found in offline bundle"
        exit 1
    fi
    
    # Install Docker from bundled .deb packages (optional; only for Matrix)
    if [[ "${INSTALL_DOCKER:-false}" != "true" ]]; then
        print_step "Skipping Docker install (not required; set INSTALL_DOCKER=true for the Matrix channel)"
    elif ! command -v docker &> /dev/null; then
        print_step "Installing Docker from offline bundle..."
        
        if [[ -d "$OFFLINE_DIR/docker_debs" ]]; then
            # Install GPG key
            if [[ -f "$OFFLINE_DIR/docker_debs/docker.gpg" ]]; then
                sudo install -m 0755 -d /etc/apt/keyrings
                sudo cp "$OFFLINE_DIR/docker_debs/docker.gpg" /etc/apt/keyrings/docker.asc
                sudo chmod a+r /etc/apt/keyrings/docker.asc
            fi
            
            # Install .deb packages in order
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/containerd.io_arm64.deb" || sudo apt-get install -f -y
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-ce-cli_arm64.deb" || sudo apt-get install -f -y
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-ce_arm64.deb" || sudo apt-get install -f -y
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-buildx-plugin_arm64.deb" || true
            sudo dpkg -i "$OFFLINE_DIR/docker_debs/docker-compose-plugin_arm64.deb" || true
            
            sudo systemctl enable docker && sudo systemctl start docker
            sudo usermod -aG docker $USER
            
            print_step "Docker installed from offline bundle"
        else
            print_error "Docker packages not found in offline bundle"
            exit 1
        fi
    else
        print_step "Docker already installed"
    fi
}

#===============================================================================
# Phase 2: Hailo AI HAT+ 2 Setup (Hailo-10H GenAI)
#===============================================================================

phase2_hailo_setup() {
    print_header "Phase 2: Hailo AI HAT+ 2 Setup (Hailo-10H GenAI)"
    local REQUIRED_LIB
    local REQUIRED_HAILORT_VERSION
    local HAILORT_BUILD_TAG
    local BUILT_LIB=""
    local LOCAL_HAILO_STACK_UPDATED=false
    
    # Step 1: Check if Hailo-10H is detected via PCIe
    print_step "Checking for Hailo AI HAT+ 2 hardware..."
    
    if ! lspci 2>/dev/null | grep -qi "Hailo"; then
        print_warn "Hailo device not detected on PCIe bus"
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Ensure AI HAT+ 2 is properly connected via PCIe ribbon cable"
        echo "  2. Check that the Pi 5 Active Cooler is installed"
        echo "  3. Verify power supply is adequate (27W USB-C recommended)"
        echo ""
        echo "Run 'lspci | grep Hailo' to check detection"
        echo ""
        if ! prompt_yes_no "Continue without Hailo hardware detection?"; then
            exit 1
        fi
    else
        print_step "Hailo device detected: $(lspci | grep -i Hailo)"
    fi
    
    # Step 2: Install/update Hailo software stack
    if [[ "$OFFLINE_MODE" != "true" ]]; then
        if install_local_hailo_stack_from_dir "$HAILO_LOCAL_PACKAGE_DIR"; then
            LOCAL_HAILO_STACK_UPDATED=true
        else
            print_warn "No complete local Hailo package set found in $HAILO_LOCAL_PACKAGE_DIR."
            print_warn "Expected at least: hailort_*.deb, hailort-pcie-driver_*.deb, hailo_gen_ai_model_zoo_*.deb"
        fi
    fi

    if [[ "$LOCAL_HAILO_STACK_UPDATED" != "true" ]]; then
        if ! command -v hailortcli &> /dev/null; then
            print_step "Installing Hailo software stack..."
            
            if [[ "$OFFLINE_MODE" == "true" ]]; then
                # Offline: Install from bundled .deb packages
                if compgen -G "$OFFLINE_DIR/hailo_debs/hailo-h10-all*.deb" > /dev/null; then
                    sudo dpkg -i "$OFFLINE_DIR/hailo_debs/"*.deb || sudo apt-get install -f -y
                else
                    print_warn "Hailo-10H packages not found in offline bundle."
                    print_warn "You will need to install manually when internet is available."
                fi
            else
                # Online fallback: Install via apt (Raspberry Pi's official method)
                # IMPORTANT: Use hailo-h10-all for Hailo-10H (AI HAT+ 2), NOT hailo-all.
                # hailo-all is for Hailo-8/8L and installs a PCIe driver (4.23.0) that
                # doesn't support Hailo-10H, causing "Failed to create VDevice" errors.
                print_step "Installing hailo-h10-all package (HailoRT for Hailo-10H)..."
                sudo apt update
                sudo apt install -y dkms
                sudo apt install -y hailo-h10-all
            fi
        else
            print_step "HailoRT already installed"
        fi
    fi
    
    # Step 3: Ensure Hailo kernel module autoload is configured and module is loaded now.
    # For Hailo-10H stacks, hailo1x_pci is expected. Keep hailo_pci as fallback for compatibility.
    print_step "Ensuring Hailo kernel module is loaded (hailo1x_pci preferred)..."
    if ! lsmod | grep -Eq 'hailo1x_pci|hailo_pci'; then
        sudo modprobe hailo1x_pci 2>/dev/null || sudo modprobe hailo_pci || print_warn "Failed to load hailo kernel module"
    fi
    if lsmod | grep -q '^hailo1x_pci'; then
        if ! grep -q 'hailo1x_pci' /etc/modules-load.d/hailo.conf 2>/dev/null; then
            echo "hailo1x_pci" | sudo tee /etc/modules-load.d/hailo.conf > /dev/null
            print_step "hailo1x_pci added to /etc/modules-load.d/ for boot autoload"
        fi
    else
        if ! grep -q 'hailo_pci' /etc/modules-load.d/hailo.conf 2>/dev/null; then
            echo "hailo_pci" | sudo tee /etc/modules-load.d/hailo.conf > /dev/null
            print_step "hailo_pci added to /etc/modules-load.d/ for boot autoload"
        fi
    fi
    # Wait briefly for a Hailo device node to appear
    for i in $(seq 1 5); do
        [[ -e /dev/hailo0 || -e /dev/h1x-0 ]] && break
        sleep 1
    done
    if [[ ! -e /dev/hailo0 && ! -e /dev/h1x-0 ]]; then
        print_warn "No /dev/hailo0 or /dev/h1x-0 device node found — Hailo device may not be accessible"
    else
        if [[ -e /dev/h1x-0 ]]; then
            print_step "/dev/h1x-0 present"
        else
            print_step "/dev/hailo0 present"
        fi
    fi
    
    # Step 3b: Verify HailoRT installation
    if command -v hailortcli &> /dev/null; then
        print_step "Verifying Hailo installation..."
        hailortcli fw-control identify 2>/dev/null || print_warn "Could not identify Hailo device"
    fi
    
    # Step 4: Install Hailo GenAI Model Zoo (hailo-ollama)
    if ! command -v hailo-ollama &> /dev/null; then
        print_step "Installing Hailo GenAI Model Zoo (hailo-ollama)..."
        
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            # Offline: Install from bundled .deb
            GENAI_DEB=$(ls "$OFFLINE_DIR"/hailo_debs/hailo*genai*.deb 2>/dev/null | head -1)
            if [[ -f "$GENAI_DEB" ]]; then
                sudo dpkg -i "$GENAI_DEB" || sudo apt-get install -f -y
                print_step "Hailo GenAI Model Zoo installed from offline bundle"
            else
                print_warn "Hailo GenAI package not found in offline bundle."
                echo ""
                echo "To install manually, download from Hailo Developer Zone:"
                echo "  https://hailo.ai/developer-zone/software-downloads/"
                echo "Then run: sudo dpkg -i hailo_gen_ai_model_zoo_<ver>_arm64.deb"
            fi
        else
            # Online: Download and install from Hailo
            print_step "Downloading Hailo GenAI Model Zoo..."
            echo ""
            echo "The Hailo GenAI Model Zoo provides hailo-ollama server for LLMs."
            echo ""
            echo "Download options:"
            echo "  1) Auto-download from Raspberry Pi (if available in apt)"
            echo "  2) Manual download from Hailo Developer Zone"
            echo ""
            
            # Try apt first (Raspberry Pi may add this to their repo)
            if apt-cache show hailo-genai &>/dev/null; then
                sudo apt install -y hailo-genai
            else
                # Provide manual instructions
                print_warn "hailo-genai not in apt repository."
                echo ""
                echo "Please download manually from Hailo Developer Zone:"
                echo "  1. Go to: https://hailo.ai/developer-zone/software-downloads/"
                echo "  2. Download: hailo_gen_ai_model_zoo_5.3.0_arm64.deb (or latest)"
                echo "  3. Install: sudo dpkg -i hailo_gen_ai_model_zoo_*.deb"
                echo ""
                
                if prompt_yes_no "Have you already downloaded the .deb file?"; then
                    DEB_PATH=$(prompt_input "Enter path to .deb file" "")
                    if [[ -f "$DEB_PATH" ]]; then
                        sudo dpkg -i "$DEB_PATH" || sudo apt-get install -f -y
                    else
                        print_warn "File not found. Continuing without hailo-ollama."
                    fi
                fi
            fi
        fi
    else
        print_step "hailo-ollama already installed"
    fi
    
    # Check if hailo-ollama is now available
    if ! command -v hailo-ollama &> /dev/null; then
        print_warn "hailo-ollama not available. Skipping model setup."
        print_warn "You can install it later and run model setup manually."
        return
    fi
    
    # Step 5: Check if libhailort version matches hailo-ollama requirements
    print_step "Checking libhailort version compatibility..."
    
    REQUIRED_LIB=$(detect_required_libhailort || true)
    if [[ -z "$REQUIRED_LIB" ]]; then
        REQUIRED_LIB="libhailort.so.5.3.0"
    fi
    REQUIRED_HAILORT_VERSION=$(extract_semver "$REQUIRED_LIB")
    if [[ -n "$REQUIRED_HAILORT_VERSION" ]]; then
        HAILORT_BUILD_TAG="v${REQUIRED_HAILORT_VERSION}"
    else
        HAILORT_BUILD_TAG="v5.3.0"
    fi

    if ! ldconfig -p | grep -q "$REQUIRED_LIB" && \
       ! [[ -f /usr/lib/$REQUIRED_LIB ]] && \
       ! [[ -f /usr/local/lib/$REQUIRED_LIB ]] && \
       ! [[ -f /usr/lib/aarch64-linux-gnu/$REQUIRED_LIB ]]; then
        print_warn "Required $REQUIRED_LIB not found (hailo-ollama dependency)"
        echo ""
        echo "The apt version of HailoRT may be incompatible with hailo-ollama."
        echo "Building HailoRT from source to fix this..."
        echo ""
        
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            print_error "Cannot build HailoRT from source in offline mode."
            print_warn "You will need internet access to build HailoRT."
            return
        fi
        
        if build_hailort_from_source "$HAILORT_BUILD_TAG"; then
            # Update symlinks to point to new library
            print_step "Updating library symlinks..."
            sudo rm -f /usr/lib/libhailort.so 2>/dev/null || true

            for candidate in \
                "/usr/local/lib/$REQUIRED_LIB" \
                "/usr/local/lib/libhailort.so.${REQUIRED_HAILORT_VERSION}" \
                "/usr/local/lib/libhailort.so"; do
                if [[ -f "$candidate" ]]; then
                    BUILT_LIB="$candidate"
                    break
                fi
            done

            if [[ -n "$BUILT_LIB" ]]; then
                sudo ln -sf "$BUILT_LIB" /usr/lib/libhailort.so
                sudo ln -sf "$BUILT_LIB" "/usr/lib/$REQUIRED_LIB"
                echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/hailort.conf > /dev/null
            fi
            sudo ldconfig
            print_step "HailoRT ${REQUIRED_HAILORT_VERSION:-$HAILORT_BUILD_TAG} installed and configured"
        else
            print_error "Failed to build HailoRT from source"
            return
        fi
    else
        print_step "$REQUIRED_LIB found - compatible with hailo-ollama"
    fi
    
    # Benchmarked on Pi5 + Hailo 5.3.0: qwen3:1.7b is fastest (~12s) AND most
    # coherent of the bundled models, so it is the recommended/primary default.
    # Proxy token caps (192/128) and unset penalties were verified optimal -
    # see tuning notes in hailo-sanitize-proxy.py. Do not raise caps for 1.x B models.
    # Prompt user to select model
    echo "Available Hailo-optimized models:"
    echo ""
    echo "  1) qwen3:1.7b               - Newest model in GenAI 5.3.0 (recommended)"
    echo "  2) qwen2.5-coder:1.5b       - Optimized for coding"
    echo "  3) qwen2.5:1.5b             - Improved general purpose"
    echo "  4) qwen2:1.5b               - General purpose"
    echo "  5) llama3.2:1b              - Meta's compact model"
    echo "  6) deepseek_r1:1.5b         - Reasoning-focused model"
    echo "  7) All available models     - Install all currently supported models"
    echo ""
    
    MODEL_CHOICE=$(prompt_input "Select model" "1")
    
    case $MODEL_CHOICE in
        1) SELECTED_MODEL="qwen3:1.7b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
        2) SELECTED_MODEL="qwen2.5-coder:1.5b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
        3) SELECTED_MODEL="qwen2.5:1.5b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
        4) SELECTED_MODEL="qwen2:1.5b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
        5) SELECTED_MODEL="llama3.2:1b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
        6) SELECTED_MODEL="deepseek_r1:1.5b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
        7)
            SELECTED_MODEL="qwen3:1.7b"
            SELECTED_MODELS="qwen3:1.7b qwen2.5-coder:1.5b qwen2.5:1.5b qwen2:1.5b llama3.2:1b deepseek_r1:1.5b"
            ;;
        *) SELECTED_MODEL="qwen3:1.7b"; SELECTED_MODELS="$SELECTED_MODEL" ;;
    esac
    
    print_step "Selected primary model: $SELECTED_MODEL"
    print_step "Models to install: $SELECTED_MODELS"
    
    # Step 6: Disable hailort_service if running (conflicts with hailo-ollama on Hailo-10H)
    # hailort_service is a multi-process RPC daemon for Hailo-8/8L. On Hailo-10H,
    # parallelism uses VDevice group_id="SHARED" instead. If hailort_service is
    # running, it holds /dev/hailo0 exclusively and hailo-ollama gets
    # HAILO_OUT_OF_PHYSICAL_DEVICES (status=74).
    if systemctl is-active --quiet hailort 2>/dev/null; then
        print_warn "hailort_service is running — stopping it (conflicts with hailo-ollama on Hailo-10H)"
        sudo systemctl stop hailort
        sudo systemctl disable hailort
        print_step "hailort_service stopped and disabled"
    fi
    
    # Step 7: Create systemd service for hailo-ollama (persistent server)
    # hailo-ollama MUST be running before OpenClaw or any client can use it.
    # It is a standalone C++ REST server (Ollama-compatible API on port 8000),
    # NOT the real Ollama binary — symlinking would not work.
    print_step "Creating systemd service for hailo-ollama..."
    
    HAILO_OLLAMA_BIN=$(command -v hailo-ollama)
    
    sudo tee /etc/systemd/system/hailo-ollama.service > /dev/null << EOF
[Unit]
Description=Hailo-Ollama GenAI Server (Ollama-compatible API on Hailo-10H)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$HAILO_OLLAMA_BIN
ExecStartPost=/bin/bash -c 'sleep 2 && curl -s -X POST http://localhost:8000/api/pull -H "Content-Type: application/json" -d "{\"model\":\"$SELECTED_MODEL\",\"stream\":false}" > /dev/null 2>&1'
Restart=on-failure
RestartSec=5
User=$USER
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF
    
    sudo systemctl daemon-reload
    sudo systemctl enable hailo-ollama.service
    sudo systemctl start hailo-ollama.service
    
    # Wait for the server to be ready
    print_step "Waiting for hailo-ollama server to start..."
    for i in $(seq 1 15); do
        if curl -s http://localhost:8000/api/version &>/dev/null; then
            print_step "hailo-ollama server is running on port 8000"
            break
        fi
        sleep 1
    done
    
    if ! curl -s http://localhost:8000/api/version &>/dev/null; then
        print_error "hailo-ollama server failed to start"
        print_warn "Check logs with: journalctl -u hailo-ollama.service"
        return
    fi
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        for model in $SELECTED_MODELS; do
            MODEL_DIR_NAME="${model//:/\/}"  # Convert qwen2:1.5b to qwen2/1.5b
            if [[ -d "$OFFLINE_DIR/hailo_models/$MODEL_DIR_NAME" ]]; then
                print_step "Installing $model from offline bundle..."
                mkdir -p ~/.hailo-ollama/models
                cp -r "$OFFLINE_DIR/hailo_models/$MODEL_DIR_NAME" ~/.hailo-ollama/models/ 2>/dev/null || true
                print_step "Model $model installed from offline bundle"
            else
                print_warn "Model $model not found in offline bundle."
                print_warn "Available models in bundle:"
                ls -la "$OFFLINE_DIR/hailo_models/" 2>/dev/null || echo "  (none)"
                print_warn "You will need to download this model when internet is available:"
                echo "  hailo-ollama pull $model"
            fi
        done
    else
        for model in $SELECTED_MODELS; do
            print_step "Pulling $model (this may take several minutes)..."
            echo ""

            # Use a temp file to capture output while showing progress
            PULL_OUTPUT=$(mktemp)

            # Run curl and tee output to both terminal and file
            if curl -s http://localhost:8000/api/pull \
                -H 'Content-Type: application/json' \
                -d "{\"model\":\"$model\",\"stream\":true}" 2>&1 | tee "$PULL_OUTPUT"; then

                # Check if output contains error indicators
                if grep -qi "error\|500\|failed\|not found" "$PULL_OUTPUT"; then
                    echo ""
                    print_error "Model pull for $model encountered an error"
                    print_warn "You may need to pull it manually later:"
                    echo "  curl http://localhost:8000/api/pull -H 'Content-Type: application/json' -d '{\"model\":\"$model\",\"stream\":true}'"
                elif [[ ! -s "$PULL_OUTPUT" ]]; then
                    echo ""
                    print_error "No response from hailo-ollama server while pulling $model"
                    print_warn "Check if hailo-ollama is running: ps aux | grep hailo-ollama"
                else
                    echo ""
                    print_step "Model $model pulled successfully"
                fi
            else
                echo ""
                print_error "curl command failed while pulling $model"
                print_warn "Check network connectivity and hailo-ollama server status"
            fi

            rm -f "$PULL_OUTPUT"
        done
    fi
    
    # Store selected model for later use in config
    HAILO_MODEL="$SELECTED_MODEL"
    
    # --- Install the sanitizing proxy (optional) ---
    # hailo-ollama's oatpp framework crashes on fields OpenClaw sends (tools,
    # stream_options, store) and its /api/show DTO is buggy. The proxy:
    #   - Strips unsupported request fields
    #   - Replaces massive system prompt with minimal one (2048-token context)
    #   - Converts non-streaming response to SSE for OpenClaw's SDK
    #   - Fixes nanosecond timestamps and missing usage fields
    #   - Fakes /api/show to avoid DTO crash
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" == "true" ]]; then
        print_step "Installing hailo-ollama sanitizing proxy..."
        
        PROXY_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hailo-sanitize-proxy.py"
        if [[ ! -f "$PROXY_SRC" ]]; then
            print_error "hailo-sanitize-proxy.py not found alongside installer"
            print_warn "Expected at: $PROXY_SRC"
        else
            sudo cp "$PROXY_SRC" /usr/local/bin/hailo-sanitize-proxy.py
            sudo chmod +x /usr/local/bin/hailo-sanitize-proxy.py

            # Tuning configuration. Local Hailo inference is free/unlimited; the
            # token caps below only bound latency (~8 tok/s) and curb repetition
            # loops on small models. Everything is overridable here. We only write
            # defaults if the file doesn't exist yet, so we never clobber a user's
            # customised values on re-runs.
            if [[ ! -f /etc/hailo-proxy.env ]]; then
                sudo tee /etc/hailo-proxy.env > /dev/null << 'ENVEOF'
# =====================================================================
# Hailo Sanitizing Proxy — Konfiguration
# =====================================================================
# Steuert /usr/local/bin/hailo-sanitize-proxy.py.
# Nach Aenderungen:  sudo systemctl restart hailo-sanitize-proxy.service
#
# HINTERGRUND: Lokale Hailo-Inferenz ist kostenlos und unbegrenzt. Die Token-
# Caps existieren NICHT zum Sparen, sondern nur um (a) die Antwortzeit zu
# begrenzen (~8 Token/s, d.h. 384 Token ca. 48s) und (b) zu verhindern, dass
# kleine 1-2B-Modelle bei langen Antworten in Wiederhol-Schleifen geraten.
# Hoeher = laengere/vollstaendigere Antworten, aber langsamer.
# ---------------------------------------------------------------------

# --- Token-Budgets (Anzahl generierter Token) ---
HAILO_PROXY_MAX_TOKENS=192          # Normale Chat-Antworten (Obergrenze)
HAILO_PROXY_CODE_TOKENS=512         # Code-Aufgaben (Funktionen/Klassen)
HAILO_PROXY_CODE_MIN_TOKENS=384     # Untergrenze fuer Code
HAILO_PROXY_WEB_TOKENS=96           # Web-gestuetzte Antworten
HAILO_PROXY_DEFAULT_TOKENS=128      # Standard, wenn Client nichts schickt

# --- Sampling ---
HAILO_PROXY_TEMPERATURE=0.15        # Niedrig = faktentreu/stabil
HAILO_PROXY_TEMPERATURE_MAX=0.6
HAILO_PROXY_TOP_P=0.85

# --- Kontext ---
HAILO_PROXY_MAX_HISTORY_MESSAGES=4
HAILO_PROXY_MAX_MESSAGE_CHARS=1200

# --- Feature-Schalter (1=an, 0=aus) ---
HAILO_PROXY_WEB_SEARCH=1            # Automatische Web-Suche bei Recherche-Fragen
HAILO_PROXY_COLLAPSE_REPETITION=1  # Wiederhol-Schleifen-Bremse

# --- Standardmodell (falls Client keins angibt) ---
HAILO_MODEL=qwen2:1.5b

# --- BEISPIEL-PROFILE (auskommentiert) ---
# Lange, vollstaendige Antworten (langsamer):
#   HAILO_PROXY_MAX_TOKENS=512
#   HAILO_PROXY_CODE_TOKENS=1024
# Maximal schnell (kurze Antworten):
#   HAILO_PROXY_MAX_TOKENS=128
#   HAILO_PROXY_CODE_TOKENS=320
ENVEOF
                sudo chmod 644 /etc/hailo-proxy.env
                print_step "Wrote default tuning config to /etc/hailo-proxy.env"
            else
                print_step "Keeping existing /etc/hailo-proxy.env (not overwritten)"
            fi

            sudo tee /etc/systemd/system/hailo-sanitize-proxy.service > /dev/null << 'EOF'
[Unit]
Description=Hailo-Ollama Sanitizing Proxy
After=hailo-ollama.service
Requires=hailo-ollama.service

[Service]
Type=simple
# Tuning-Parameter (Token-Caps, Sampling, Feature-Schalter). Das '-' macht die
# Datei optional: fehlt sie, gelten die Defaults im Python-Skript.
EnvironmentFile=-/etc/hailo-proxy.env
ExecStart=/usr/bin/python3 /usr/local/bin/hailo-sanitize-proxy.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
            
            sudo systemctl daemon-reload
            sudo systemctl enable hailo-sanitize-proxy.service
            sudo systemctl start hailo-sanitize-proxy.service
            
            # Verify proxy is running
            sleep 2
            if curl -s http://127.0.0.1:8081/api/tags &>/dev/null; then
                print_step "Sanitizing proxy running on port 8081"
            else
                print_warn "Sanitizing proxy may not have started — check: journalctl -u hailo-sanitize-proxy"
            fi
        fi
    else
        print_warn "Skipping sanitizing proxy (USE_SANITIZER_PROXY_ON_OLLAMA=false)"
    fi
    
    print_step "Hailo GenAI stack configured with $SELECTED_MODEL"
}

#===============================================================================
# Phase 3: OpenClaw Installation
#===============================================================================

phase3_openclaw_install() {
    print_header "Phase 3: OpenClaw Installation"

    ensure_homebrew
    
    if ! command -v openclaw &> /dev/null; then
        if [[ "$OFFLINE_MODE" == "true" ]]; then
            print_step "Installing OpenClaw from offline bundle..."
            OPENCLAW_TGZ=$(ls "$OFFLINE_DIR"/openclaw-*.tgz 2>/dev/null | head -1)
            if [[ -f "$OPENCLAW_TGZ" ]]; then
                sudo npm install -g "$OPENCLAW_TGZ"
                print_step "OpenClaw installed from offline bundle"
            else
                print_error "OpenClaw package not found in offline bundle"
                exit 1
            fi
        else
            print_step "Installing OpenClaw..."
            curl -fsSL https://openclaw.ai/install.sh | bash
        fi
    else
        print_step "OpenClaw already installed"
    fi
    
    # OpenClaw onboarding is interactive in current releases and blocks automation.
    # The installer writes the needed config and auth files below, so defer doctor
    # until verification after the configuration is in place.
    print_step "Skipping early OpenClaw doctor; configuration will be written next"
    
    # Fix: remove duplicate nextcloud-talk extension from user-space if it exists.
    # OpenClaw bundles nextcloud-talk in its npm-global extensions dir; a second
    # copy under ~/.openclaw/extensions causes "duplicate plugin id" warnings and
    # may fail to load due to missing 'zod' dependency.
    if [[ -d "$HOME/.openclaw/extensions/nextcloud-talk" ]]; then
        print_step "Removing duplicate nextcloud-talk extension (bundled copy is sufficient)..."
        rm -rf "$HOME/.openclaw/extensions/nextcloud-talk"
    fi
    
    # Configure Hailo as primary model (use selected model from phase2)
    # NOTE: We use EXPLICIT provider config via the sanitizing proxy (port 8081):
    #   1. hailo-ollama runs on port 8000 with OpenAI-compatible /v1 endpoints
    #   2. The proxy strips unsupported fields, simplifies system prompts,
    #      converts responses to SSE, and fakes /api/show
    #   3. Explicit config with "api": "openai-completions" uses /v1/chat/completions
    print_step "Configuring Hailo $HAILO_MODEL as primary model..."
    mkdir -p "$(dirname "$OPENCLAW_CONFIG")"
    
    # Remove any old iptables redirect rules from previous install attempts
    sudo iptables -t nat -D OUTPUT -p tcp -d 127.0.0.1 --dport 11434 -j REDIRECT --to-port 8000 2>/dev/null || true
    sudo netfilter-persistent save 2>/dev/null || true
    
    # Unset OLLAMA_API_KEY — we use explicit provider config, not auto-discovery.
    # Auto-discovery probes /api/show which causes 500 errors on hailo-ollama.
    sed -i '/OLLAMA_API_KEY/d' "$HOME/.bashrc" 2>/dev/null || true
    mkdir -p "$HOME/.openclaw"
    sed -i '/OLLAMA_API_KEY/d' "$HOME/.openclaw/.env" 2>/dev/null || true
    unset OLLAMA_API_KEY 2>/dev/null || true
    
    # Use a dedicated custom provider id ("hailo") to avoid Ollama-native probes
    # like /api/show that can fail on hailo-ollama.
    HAILO_PROVIDER_ID="hailo"
    HAILO_PROVIDER_MODEL="${HAILO_PROVIDER_ID}/${HAILO_MODEL:-qwen2:1.5b}"
    MODEL_ID="${HAILO_MODEL:-qwen2:1.5b}"
    MODEL_BASE_URL="$(get_hailo_openai_base_url)"
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" != "true" ]]; then
        print_warn "Sanitizing proxy disabled; OpenClaw will call hailo-ollama directly"
    fi
    
    # Use explicit provider config with /v1/chat/completions via sanitizing proxy.
    # The proxy (port 8081) sits between OpenClaw and hailo-ollama (port 8000).
    # Conservative context/token limits for stable Hailo generation across models.
    if [[ "$USE_OPENCLAW_TOOLS" == "true" ]]; then
        TOOLS_BLOCK=""
    else
        TOOLS_BLOCK='  "tools": {
    "deny": ["*"]
  },'
        print_warn "OpenClaw tools disabled (USE_OPENCLAW_TOOLS=false)"
    fi

    if [[ -z "${OPENCLAW_FIXED_TOKEN:-}" ]]; then
        OPENCLAW_FIXED_TOKEN="$(head -c 18 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 24)"
        [[ -z "$OPENCLAW_FIXED_TOKEN" ]] && OPENCLAW_FIXED_TOKEN="openclaw-$(date +%s)"
    fi


    # Determine Tailscale IP for allowedOrigins
    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || echo "")

    cat > "$OPENCLAW_CONFIG" << EOF
{
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "controlUi": {
      "allowInsecureAuth": true,
      "allowedOrigins": [
        "http://localhost:${OPENCLAW_PORT}",
        "http://127.0.0.1:${OPENCLAW_PORT}"$([ -n "$ts_ip" ] && echo ",
        \"http://${ts_ip}:${OPENCLAW_PORT}\"")
      ]
    },
    "auth": {
      "mode": "token",
      "token": "$OPENCLAW_FIXED_TOKEN"
    }
  },
  "models": {
    "providers": {
      "$HAILO_PROVIDER_ID": {
        "baseUrl": "$MODEL_BASE_URL",
        "apiKey": "hailo-local",
        "api": "openai-completions",
        "models": [
          {
            "id": "qwen3:1.7b",
            "name": "qwen3:1.7b",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 192
          },
          {
            "id": "qwen2.5-coder:1.5b",
            "name": "qwen2.5-coder:1.5b",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 192
          },
          {
            "id": "qwen2.5:1.5b",
            "name": "qwen2.5:1.5b",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 192
          },
          {
            "id": "qwen2:1.5b",
            "name": "qwen2:1.5b",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 192
          },
          {
            "id": "llama3.2:1b",
            "name": "llama3.2:1b",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 192
          },
          {
            "id": "deepseek_r1:1.5b",
            "name": "deepseek_r1:1.5b",
            "reasoning": false,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 32768,
            "maxTokens": 192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "$HAILO_PROVIDER_MODEL"
      },
      "models": {
        "'"$HAILO_PROVIDER_ID"'/qwen3:1.7b": {
          "streaming": false
        },
        "'"$HAILO_PROVIDER_ID"'/qwen2.5-coder:1.5b": {
          "streaming": false
        },
        "'"$HAILO_PROVIDER_ID"'/qwen2.5:1.5b": {
          "streaming": false
        },
        "'"$HAILO_PROVIDER_ID"'/qwen2:1.5b": {
          "streaming": false
        },
        "'"$HAILO_PROVIDER_ID"'/llama3.2:1b": {
          "streaming": false
        },
        "'"$HAILO_PROVIDER_ID"'/deepseek_r1:1.5b": {
          "streaming": false
        }
      },
      "contextInjection": "continuation-skip",
      "sandbox": {
        "mode": "off",
        "workspaceAccess": "rw"
      },
      "heartbeat": {
        "every": "4h",
        "activeHours": { "start": "07:00", "end": "18:00" },
        "target": "last"
      },
      "bootstrapMaxChars": 6000,
      "bootstrapTotalMaxChars": 12000,
      "compaction": {
        "reserveTokens": 2048,
        "reserveTokensFloor": 20000
      }
    }
  },
  $TOOLS_BLOCK
  "plugins": {
    "allow": ["nextcloud-talk", "duckduckgo", "web-readability"],
    "bundledDiscovery": "compat"
  }
}
EOF

    if ! openclaw config validate >/dev/null 2>&1; then
        print_error "Generated OpenClaw config failed validation"
        openclaw config validate || true
        exit 1
    fi
    
    if [[ "$USE_SANITIZER_PROXY_ON_OLLAMA" == "true" ]]; then
        print_step "OpenClaw configured with Hailo-Ollama via sanitizing proxy"
    else
        print_step "OpenClaw configured with Hailo-Ollama direct endpoint"
    fi
    print_step "Primary model: $HAILO_PROVIDER_MODEL (cost: \$0)"
    
    # Write auth profile so the agent can use the local provider credentials.
    print_step "Writing local provider auth profile for main agent..."
    mkdir -p "$HOME/.openclaw/agents/main/agent"
    cat > "$HOME/.openclaw/agents/main/agent/auth-profiles.json" << EOF
{
  "$HAILO_PROVIDER_ID:local": {
    "type": "token",
    "provider": "$HAILO_PROVIDER_ID",
    "token": "hailo-local"
  },
  "lastGood": {
    "$HAILO_PROVIDER_ID": "$HAILO_PROVIDER_ID:local"
  }
}
EOF

    # Persist low-power startup optimizations for future shells.
    sed -i '/OPENCLAW_GATEWAY_TOKEN/d' "$HOME/.bashrc" 2>/dev/null || true
    mkdir -p "$HOME/.openclaw"
    cat > "$HOME/.openclaw/.env" << EOF
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_FIXED_TOKEN
NODE_COMPILE_CACHE=$NODE_COMPILE_CACHE
OPENCLAW_NO_RESPAWN=$OPENCLAW_NO_RESPAWN
EOF
    chmod 600 "$HOME/.openclaw/.env"
    
    # Restart OpenClaw daemon so it picks up the new config.
    print_step "Restarting OpenClaw daemon with Hailo model config..."
    openclaw daemon restart 2>/dev/null || openclaw gateway restart 2>/dev/null || {
        print_warn "Could not restart daemon automatically — restart manually after install"
    }
    repair_local_cli_pairing_scopes
    openclaw gateway restart 2>/dev/null || true
}

phase3_picoclaw_install() {
    print_header "Phase 3: PicoClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v go &> /dev/null; then
        print_step "Installing Go toolchain for PicoClaw build..."
        sudo apt update
        sudo apt install -y golang-go make git
    fi

    local pico_dir="$HOME/.picoclaw-src"
    if [[ -d "$pico_dir/.git" ]]; then
        git -C "$pico_dir" pull --ff-only
    else
        git clone https://github.com/sipeed/picoclaw.git "$pico_dir"
    fi

    print_step "Building PicoClaw..."
    make -C "$pico_dir" deps
    make -C "$pico_dir" build
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$pico_dir/build/picoclaw" "$HOME/.local/bin/picoclaw"

    mkdir -p "$HOME/.picoclaw"
    mkdir -p "$HOME/.config/picoclaw"
    cat > "$HOME/.picoclaw/config.json" << EOF
{
  "agents": {
    "defaults": {
      "workspace": "~/.picoclaw/workspace",
      "restrict_to_workspace": true,
      "model": "$HAILO_MODEL",
      "max_tokens": 2048,
      "temperature": 0.7,
      "max_tool_iterations": 20
    }
  },
  "providers": {
    "ollama": {
      "api_key": "hailo-local",
      "api_base": "$model_base_url"
    }
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 18790
  }
}
EOF

    cp "$HOME/.picoclaw/config.json" "$HOME/.config/picoclaw/config.json"

    print_step "PicoClaw installed and configured for local Hailo endpoint: $model_base_url"
    write_unified_facade_runtime_profile
}

phase3_zeroclaw_install() {
    print_header "Phase 3: ZeroClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v cargo &> /dev/null; then
        print_step "Installing Rust toolchain for ZeroClaw build..."
        sudo apt update
        sudo apt install -y cargo rustc git
    fi

    local zero_dir="$HOME/.zeroclaw-src"
    if [[ -d "$zero_dir/.git" ]]; then
        git -C "$zero_dir" pull --ff-only
    else
        git clone https://github.com/zeroclaw-labs/zeroclaw.git "$zero_dir"
    fi

    print_step "Building ZeroClaw (release)..."
    local build_log
    build_log=$(mktemp)

    if ! cargo build --release --manifest-path "$zero_dir/Cargo.toml" >"$build_log" 2>&1; then
        print_warn "ZeroClaw build failed with system Rust/cargo. Trying rustup stable toolchain..."

        if ! command -v rustup &> /dev/null; then
            print_step "Installing rustup (stable toolchain manager)..."
            RUSTUP_INIT_SKIP_PATH_CHECK=yes curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
        fi

        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        rustup toolchain install stable --profile minimal
        rustup default stable

        if ! cargo build --release --manifest-path "$zero_dir/Cargo.toml" >"$build_log" 2>&1; then
            print_error "ZeroClaw build failed even with rustup stable"
            tail -n 80 "$build_log" || true
            rm -f "$build_log"
            return 1
        fi
    fi

    rm -f "$build_log"
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$zero_dir/target/release/zeroclaw" "$HOME/.local/bin/zeroclaw"

    mkdir -p "$HOME/.zeroclaw"
    cat > "$HOME/.zeroclaw/config.toml" << EOF
api_key = "hailo-local"
default_provider = "custom:$model_base_url"
default_model = "$HAILO_MODEL"
default_temperature = 0.7

[gateway]
host = "127.0.0.1"
port = 8080
require_pairing = true

[autonomy]
workspace_only = true

[heartbeat]
enabled = false
interval_minutes = 30
EOF

    print_step "ZeroClaw installed (local Hailo defaults written to ~/.zeroclaw/config.toml; endpoint=$model_base_url)"
    write_unified_facade_runtime_profile
}

phase3_nanobot_install() {
    print_header "Phase 3: Nanobot Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    # No venv/pipx: install Nanobot system-wide so it benefits from `pip` updates.
    print_step "Installing/upgrading Nanobot (nanobot-ai) system-wide (no venv)..."
    sudo apt install -y python3-pip >/dev/null 2>&1 || true
    if ! python3 -m pip install --break-system-packages --upgrade nanobot-ai; then
        print_error "Failed to install nanobot-ai via pip --break-system-packages"
        return 1
    fi
    # Ensure the user-script dir (where pip may place the entrypoint) is on PATH.
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc" ;;
    esac

    mkdir -p "$HOME/.nanobot"
    cat > "$HOME/.nanobot/config.json" << EOF
{
  "agents": {
    "defaults": {
      "workspace": "~/.nanobot/workspace",
      "model": "$HAILO_MODEL",
      "max_tokens": 2048,
      "temperature": 0.7,
      "max_tool_iterations": 20,
      "memory_window": 50
    }
  },
  "providers": {
    "custom": {
      "api_key": "hailo-local",
      "api_base": "$model_base_url"
    }
  },
  "gateway": {
    "host": "127.0.0.1",
    "port": 18790
  },
  "tools": {
    "restrict_to_workspace": true
  }
}
EOF

    mkdir -p "$HOME/.nanobot/workspace"

    print_step "Nanobot installed and configured for local Hailo endpoint: $model_base_url"
    write_unified_facade_runtime_profile
}

phase3_moltis_install() {
    print_header "Phase 3: Moltis Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v cargo &> /dev/null; then
        print_step "Installing Rust toolchain for Moltis build..."
        sudo apt update
        sudo apt install -y cargo rustc git
    fi

    print_step "Installing Moltis via cargo (this may take several minutes)..."
    if ! cargo install --locked --git https://github.com/moltis-org/moltis moltis; then
        print_warn "Moltis install failed with system Rust/cargo. Trying rustup stable toolchain..."

        if ! command -v rustup &> /dev/null; then
            print_step "Installing rustup (stable toolchain manager)..."
            RUSTUP_INIT_SKIP_PATH_CHECK=yes curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
        fi

        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        rustup toolchain install stable --profile minimal
        rustup default stable

        cargo install --locked --git https://github.com/moltis-org/moltis moltis
    fi

    mkdir -p "$HOME/.local/bin"
    if [[ -x "$HOME/.cargo/bin/moltis" ]]; then
        install -m 0755 "$HOME/.cargo/bin/moltis" "$HOME/.local/bin/moltis"
    else
        print_error "Moltis binary not found at ~/.cargo/bin/moltis after install"
        return 1
    fi

    mkdir -p "$HOME/.config/moltis"
    mkdir -p "$HOME/.moltis"
    cat > "$HOME/.config/moltis/moltis.toml" << EOF
[providers]
offered = ["ollama"]

[providers.ollama]
enabled = true
base_url = "$model_base_url"
models = ["$HAILO_MODEL"]
fetch_models = false

[chat]
priority_models = ["$HAILO_MODEL"]
EOF

    print_step "Moltis installed and configured for local Hailo endpoint: $model_base_url"
    write_unified_facade_runtime_profile
}

phase3_ironclaw_install() {
    print_header "Phase 3: IronClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    if ! command -v cargo &> /dev/null; then
        print_step "Installing Rust toolchain for IronClaw build..."
        sudo apt update
        sudo apt install -y cargo rustc git
    fi

    print_step "Installing IronClaw via cargo (this may take several minutes)..."
    if ! cargo install --locked --git https://github.com/nearai/ironclaw.git ironclaw; then
        print_warn "IronClaw install failed with system Rust/cargo. Trying rustup stable toolchain..."

        if ! command -v rustup &> /dev/null; then
            print_step "Installing rustup (stable toolchain manager)..."
            RUSTUP_INIT_SKIP_PATH_CHECK=yes curl https://sh.rustup.rs -sSf | sh -s -- -y --profile minimal
        fi

        # shellcheck disable=SC1090
        source "$HOME/.cargo/env"
        rustup toolchain install stable --profile minimal
        rustup default stable

        cargo install --locked --git https://github.com/nearai/ironclaw.git ironclaw
    fi

    mkdir -p "$HOME/.local/bin"
    if [[ -x "$HOME/.cargo/bin/ironclaw" ]]; then
        install -m 0755 "$HOME/.cargo/bin/ironclaw" "$HOME/.local/bin/ironclaw"
    else
        print_error "IronClaw binary not found at ~/.cargo/bin/ironclaw after install"
        return 1
    fi

    mkdir -p "$HOME/.ironclaw"
    cat > "$HOME/.ironclaw/.env" << EOF
DATABASE_URL=postgresql://localhost/ironclaw
OPENAI_BASE_URL=$model_base_url
OPENAI_API_KEY=hailo-local
OPENAI_MODEL=$HAILO_MODEL
LLM_BACKEND=openai_compatible
EOF

    print_step "IronClaw installed and local Hailo defaults written to ~/.ironclaw/.env (endpoint=$model_base_url)"
    write_unified_facade_runtime_profile
}

phase3_nullclaw_install() {
    print_header "Phase 3: NullClaw Installation"

    local model_base_url
    model_base_url="$(get_hailo_openai_base_url)"

    print_step "Installing build dependencies for NullClaw..."
    sudo apt update
    sudo apt install -y curl tar xz-utils git

    local zig_version="0.15.2"
    local zig_platform="aarch64-linux"
    local zig_root="$HOME/.local/zig"
    local zig_dir="$zig_root/zig-${zig_platform}-${zig_version}"
    local zig_bin="$HOME/.local/bin/zig"

    mkdir -p "$zig_root" "$HOME/.local/bin"

    if [[ ! -x "$zig_bin" ]] || [[ "$("$zig_bin" version 2>/dev/null || true)" != "$zig_version" ]]; then
        print_step "Installing Zig ${zig_version} (required by NullClaw)..."
        local zig_tar="zig-${zig_platform}-${zig_version}.tar.xz"
        curl -fsSL "https://ziglang.org/download/${zig_version}/${zig_tar}" -o "$zig_root/$zig_tar"
        rm -rf "$zig_dir"
        tar -xJf "$zig_root/$zig_tar" -C "$zig_root"
        ln -sf "$zig_dir/zig" "$zig_bin"
    fi

    local nullclaw_dir="$HOME/.nullclaw-src"
    if [[ -d "$nullclaw_dir/.git" ]]; then
        git -C "$nullclaw_dir" pull --ff-only
    else
        git clone https://github.com/nullclaw/nullclaw.git "$nullclaw_dir"
    fi

    print_step "Building NullClaw (ReleaseSmall)..."
    (
        cd "$nullclaw_dir"
        PATH="$HOME/.local/bin:$PATH" "$zig_bin" build -Doptimize=ReleaseSmall
    )

    mkdir -p "$HOME/.local/bin"
    if [[ -x "$nullclaw_dir/zig-out/bin/nullclaw" ]]; then
        install -m 0755 "$nullclaw_dir/zig-out/bin/nullclaw" "$HOME/.local/bin/nullclaw"
    else
        print_error "NullClaw binary not found at $nullclaw_dir/zig-out/bin/nullclaw after build"
        return 1
    fi

    mkdir -p "$HOME/.nullclaw/workspace"
    cat > "$HOME/.nullclaw/config.json" << EOF
{
  "default_temperature": 0.7,
  "models": {
    "providers": {
      "ollama": {
        "api_key": "hailo-local",
        "base_url": "$model_base_url",
        "api": "openai-completions"
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "~/.nullclaw/workspace",
      "restrict_to_workspace": true,
      "model": {
        "primary": "ollama/$HAILO_MODEL"
      }
    }
  }
}
EOF

    print_step "NullClaw installed and local Hailo defaults written to ~/.nullclaw/config.json (endpoint=$model_base_url)"
    write_unified_facade_runtime_profile
}

phase3_install_selected_claw() {
    CLAW_FLAVOR=$(normalize_claw_flavor "$CLAW_FLAVOR")
    case "$CLAW_FLAVOR" in
        picoclaw)
            phase3_picoclaw_install
            ;;
        zeroclaw)
            phase3_zeroclaw_install
            ;;
        nanobot)
            phase3_nanobot_install
            ;;
        moltis)
            phase3_moltis_install
            ;;
        ironclaw)
            phase3_ironclaw_install
            ;;
        nullclaw)
            phase3_nullclaw_install
            ;;
        *)
            phase3_openclaw_install
            write_unified_facade_runtime_profile
            ;;
    esac
}

#===============================================================================
# Phase 4: Deploy Custom Configuration
#===============================================================================

phase4_deploy_config() {
    print_header "Phase 4: Deploy Custom Configuration"
    
    mkdir -p "$OPENCLAW_WORKSPACE"
    mkdir -p "$OPENCLAW_WORKSPACE/skills/molt_tools"
    
    # Copy clawdbot-assistant.md as CLAUDE.md and AGENTS.md
    if [[ -f "$SCRIPT_DIR/clawdbot-assistant.md" ]]; then
        cp "$SCRIPT_DIR/clawdbot-assistant.md" "$OPENCLAW_WORKSPACE/CLAUDE.md"
        cp "$SCRIPT_DIR/clawdbot-assistant.md" "$OPENCLAW_WORKSPACE/AGENTS.md"
        print_step "Deployed clawdbot-assistant.md as CLAUDE.md and AGENTS.md"
    else
        print_error "clawdbot-assistant.md not found in $SCRIPT_DIR"
    fi
    
    # Copy HEARTBEAT.md template
    if [[ -f "$SCRIPT_DIR/templates/HEARTBEAT.md" ]]; then
        cp "$SCRIPT_DIR/templates/HEARTBEAT.md" "$OPENCLAW_WORKSPACE/HEARTBEAT.md"
        print_step "Deployed HEARTBEAT.md"
    fi
    
    # Copy BOOTSTRAP.md (first task)
    if [[ -f "$SCRIPT_DIR/templates/BOOTSTRAP.md" ]]; then
        cp "$SCRIPT_DIR/templates/BOOTSTRAP.md" "$OPENCLAW_WORKSPACE/BOOTSTRAP.md"
        print_step "Deployed BOOTSTRAP.md (first boot task)"
    fi
    
    # Customize "What I Care About" section
    print_header "Customize Your Assistant"
    
    echo "Let's personalize your assistant's 'What I Care About' section."
    echo ""
    
    DEEP_WORK=$(prompt_input "Deep work hours (don't interrupt)" "9am-12pm, 2pm-5pm")
    PRIORITY_CONTACTS=$(prompt_input "Priority contacts (comma-separated)" "")
    PRIORITY_PROJECTS=$(prompt_input "Priority projects (comma-separated)" "")
    IGNORE_LIST=$(prompt_input "Ignore list" "newsletters, promotional emails, LinkedIn")
    
    # Update AGENTS.md with customizations
    if [[ -f "$OPENCLAW_WORKSPACE/AGENTS.md" ]]; then
        local escaped_contacts escaped_projects escaped_deep_work
        escaped_contacts=$(escape_sed_replacement "$PRIORITY_CONTACTS")
        escaped_projects=$(escape_sed_replacement "$PRIORITY_PROJECTS")
        escaped_deep_work=$(escape_sed_replacement "$DEEP_WORK")
        sed -i "s/{list names}/$escaped_contacts/g" "$OPENCLAW_WORKSPACE/AGENTS.md"
        sed -i "s/{list projects}/$escaped_projects/g" "$OPENCLAW_WORKSPACE/AGENTS.md"
        if [[ -n "$DEEP_WORK" ]]; then
            sed -i "s/9am-12pm, 2pm-5pm (don't interrupt)/$escaped_deep_work (don't interrupt)/g" "$OPENCLAW_WORKSPACE/AGENTS.md"
        fi
        print_step "Customized AGENTS.md with your preferences"
    fi

    setup_named_agents
}

# Define two named agents: "main" (generalist, qwen3:1.7b) and "fixer"
# (review/repair, qwen2.5-coder:1.5b). The fixer reviews and improves the main
# agent's outputs/configs/code. Idempotent: writes the fixer workspace +
# instructions and patches agents.list via the validated config patcher. To use
# a stronger cloud model for repair later, add a provider+key and change the
# fixer's model.primary to e.g. "anthropic/claude-..." then restart the gateway.
setup_named_agents() {
    print_header "Configure named agents (main + fixer)"
    local provider="${HAILO_PROVIDER_ID:-hailo}"
    local fixer_ws="$HOME/.openclaw/workspace-fixer"
    local fixer_dir="$HOME/.openclaw/agents/fixer"
    mkdir -p "$fixer_ws" "$fixer_dir"

    cat > "$fixer_dir/.instructions.md" << 'FIXEREOF'
# Fixer-Agent — Reviewer & Reparatur

Du bist **Fixer**, ein präziser Review- und Reparatur-Agent auf einem Raspberry Pi 5.
Modell: `hailo/qwen2.5-coder:1.5b` (lokal, code-/struktur-spezialisiert).

## Deine Aufgabe

Du bekommst Ergebnisse, Konfigurationen, Prompts oder Code, die der Agent **`main`**
(`hailo/qwen3:1.7b`) erzeugt hat. Prüfe und **verbessere/repariere** sie.

## Arbeitsweise

1. Lies die Eingabe genau. Benenne kurz, **was** falsch oder schwach ist.
2. Liefere die **korrigierte Version** — konkret und vollständig, nicht nur Hinweise.
3. Bei Code/Config: gib lauffähige, vollständige Blöcke aus. Keine Platzhalter.
4. Bei Antworten von `main`: korrekt, knapp, faktisch. Entferne Halluzinationen,
   erfundene Pfade/Zahlen und Wiederholungen.
5. Ist etwas bereits korrekt, sag das klar und ändere nichts.

## Stil

- Sprache des Nutzers (Default: Deutsch). Erst Diagnose (1-2 Sätze), dann Lösung.
- Keine rohen Werkzeug-JSON-Blöcke im Text. Werkzeug nötig? Rufe es auf.
- Erfinde nichts. Fehlt Information, sag es und nenne, was du brauchst.
FIXEREOF

    cat > "$fixer_ws/AGENTS.md" << 'FIXEREOF'
# Fixer-Workspace

Arbeitsbereich des **Fixer**-Agenten (Review & Reparatur).
Fixer prüft und repariert Outputs des `main`-Agenten (`hailo/qwen3:1.7b`).
Modell: `hailo/qwen2.5-coder:1.5b`.

## Prinzipien
- Erst Diagnose, dann konkrete, vollständige Korrektur.
- Lauffähiger Code/Config, keine Platzhalter.
- Keine Halluzinationen; fehlt Information, klar benennen.
- Sprache des Nutzers (Default: Deutsch), knapp und faktisch.
FIXEREOF

    cat > "$fixer_ws/IDENTITY.md" << 'FIXEREOF'
# IDENTITY.md - Fixer

- **Name:** Fixer
- **Creature:** Review- und Reparatur-Agent (code-spezialisiert)
- **Vibe:** präzise, knapp, sachlich
- **Emoji:** 🔧
- **Modell:** hailo/qwen2.5-coder:1.5b
FIXEREOF

    local agents_patch
    agents_patch=$(cat << PATCHEOF
{
  "agents": {
    "list": [
      {
        "id": "main",
        "default": true,
        "name": "Main",
        "description": "Generalist, lokal auf Hailo-NPU.",
        "workspace": "$OPENCLAW_WORKSPACE",
        "agentDir": "$HOME/.openclaw/agents/main",
        "model": { "primary": "$provider/qwen3:1.7b" }
      },
      {
        "id": "fixer",
        "default": false,
        "name": "Fixer",
        "description": "Review- und Reparatur-Agent. Verbessert Outputs/Configs/Code des main-Agenten.",
        "workspace": "$fixer_ws",
        "agentDir": "$fixer_dir",
        "model": { "primary": "$provider/qwen2.5-coder:1.5b" }
      }
    ]
  }
}
PATCHEOF
)
    if printf '%s' "$agents_patch" | openclaw config patch --stdin >/dev/null 2>&1; then
        print_step "Named agents configured: main (qwen3:1.7b) + fixer (qwen2.5-coder:1.5b)"
    else
        print_warn "Could not patch agents.list; check 'openclaw config validate'"
    fi
}

ensure_openclaw_boot_autostart() {
    print_header "Ensuring Boot Autostart"

    # Keep user services alive and auto-starting even without interactive login.
    sudo loginctl enable-linger "$USER" || print_warn "Could not enable linger for $USER"

    # System services should start automatically after reboot/powercycle.
    sudo systemctl enable hailo-ollama.service 2>/dev/null || true
    sudo systemctl enable hailo-sanitize-proxy.service 2>/dev/null || true
    sudo systemctl enable unified-chat-facade.service 2>/dev/null || true

    # OpenClaw gateway is a user service; with linger it can boot without login.
    # Bind mode "lan" (0.0.0.0) so BOTH the local TUI (127.0.0.1) and remote
    # Tailscale clients (MacBook) can connect. "tailnet" alone breaks the TUI,
    # "loopback"/"auto" alone breaks remote access. Token auth gates all access.
    local gateway_unit="$HOME/.config/systemd/user/openclaw-gateway.service"
    systemctl --user daemon-reload 2>/dev/null || true
    if systemctl --user list-unit-files 2>/dev/null | grep -q '^openclaw-gateway.service'; then
        systemctl --user enable openclaw-gateway.service 2>/dev/null || print_warn "Could not enable openclaw-gateway user service"
        systemctl --user restart openclaw-gateway.service 2>/dev/null || print_warn "Could not restart openclaw-gateway user service"
    else
        print_warn "openclaw-gateway.service not found yet; trying to create/start it via CLI"
        openclaw gateway restart 2>/dev/null || true
        if systemctl --user list-unit-files 2>/dev/null | grep -q '^openclaw-gateway.service'; then
            systemctl --user enable openclaw-gateway.service 2>/dev/null || true
            systemctl --user restart openclaw-gateway.service 2>/dev/null || true
        fi
    fi

    if [[ -f "$gateway_unit" ]]; then
        # Ensure --bind lan flag is present in ExecStart (loopback + tailnet)
        if grep -q ' gateway --port 18789$' "$gateway_unit"; then
            sed -i 's| gateway --port 18789$| gateway --port 18789 --bind lan|' "$gateway_unit"
        elif grep -q ' gateway --port 18789 ' "$gateway_unit" && ! grep -q -- '--bind' "$gateway_unit"; then
            sed -i 's| gateway --port 18789 | gateway --port 18789 --bind lan |' "$gateway_unit"
        else
            # Migrate any older explicit --bind tailnet/auto/loopback to lan
            sed -i 's|--bind \(tailnet\|auto\|loopback\)|--bind lan|' "$gateway_unit"
        fi

        # Add ExecStartPre to wait for Tailscale IP (fixes race condition on boot)
        if ! grep -q 'ExecStartPre' "$gateway_unit"; then
            sed -i '/^ExecStart=/i ExecStartPre=/bin/sh -c '"'"'for i in $(seq 1 60); do tailscale ip -4 2>/dev/null | grep -q "^[0-9]" \&\& exit 0 || sleep 2; done; exit 1'"'"'' "$gateway_unit"
        fi

        # Increase TimeoutStartSec to accommodate the wait loop (max 120s wait + margin)
        sed -i 's/^TimeoutStartSec=.*/TimeoutStartSec=150/' "$gateway_unit"

        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user restart openclaw-gateway.service 2>/dev/null || true
    fi

    # Configure browser origins and HTTPS access for remote Control UI.
    local ts_ip ts_dns origins_json
    ts_ip=$(tailscale ip -4 2>/dev/null | head -1 || echo "")
    ts_dns=$(tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("Self",{}).get("DNSName","")).rstrip("."))' 2>/dev/null || echo "")

    origins_json="[\"http://localhost:${OPENCLAW_PORT}\",\"http://127.0.0.1:${OPENCLAW_PORT}\""
    if [[ -n "$ts_ip" ]]; then
        origins_json="${origins_json},\"http://${ts_ip}:${OPENCLAW_PORT}\""
    fi
    if [[ -n "$ts_dns" ]]; then
        origins_json="${origins_json},\"https://${ts_dns}\""
    fi
    origins_json="${origins_json}]"

    openclaw config set gateway.controlUi.allowedOrigins "$origins_json" 2>/dev/null || true
    print_step "Applied gateway.controlUi.allowedOrigins for localhost + tailnet"

    # Keep model labels stable in UI even when VL alias fallback is active.
    if [[ -f "$OPENCLAW_CONFIG" ]]; then
        python3 - <<'PY' "$OPENCLAW_CONFIG"
import json, sys
p = sys.argv[1]
try:
    with open(p, "r", encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    raise SystemExit(0)
providers = d.get("models", {}).get("providers", {})
hailo = providers.get("hailo")
changed = False
expected_names = {
    "qwen3:1.7b": "qwen3:1.7b",
    "qwen2.5-coder:1.5b": "qwen2.5-coder:1.5b",
    "qwen2.5:1.5b": "qwen2.5:1.5b",
    "qwen2:1.5b": "qwen2:1.5b",
    "llama3.2:1b": "llama3.2:1b",
    "deepseek_r1:1.5b": "deepseek_r1:1.5b",
}
if isinstance(hailo, dict):
    for m in hailo.get("models", []) or []:
        mid = m.get("id")
        expected = expected_names.get(mid)
        if expected and m.get("name") != expected:
            m["name"] = expected
            changed = True
if changed:
    with open(p, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)
        f.write("\n")
PY
    fi

    # Expose OpenClaw over HTTPS on MagicDNS (secure browser context).
    if [[ -n "$ts_ip" ]]; then
        sudo tailscale serve --bg "http://${ts_ip}:${OPENCLAW_PORT}" >/dev/null 2>&1 || true
    fi

    if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == "yes" ]]; then
        print_step "Linger enabled for $USER"
    else
        print_warn "Linger not confirmed for $USER"
    fi
    print_step "Boot autostart configuration applied"
}

#===============================================================================
# Phase 5: Deploy molt_tools Skill
#===============================================================================

phase5_molt_tools() {
    print_header "Phase 5: Deploy molt_tools Skill"
    
    # Copy molt_tools
    if [[ -d "$SCRIPT_DIR/molt_tools" ]]; then
        cp -r "$SCRIPT_DIR/molt_tools/"* "$OPENCLAW_WORKSPACE/skills/molt_tools/"
        print_step "Copied molt_tools to workspace"
    fi
    
    # Create SKILL.md
    cat > "$OPENCLAW_WORKSPACE/skills/molt_tools/SKILL.md" << 'EOF'
---
name: molt_tools
description: Moltbook integration (check status/DMs/feed and post updates).
---

# Moltbook Skill

Tools for interacting with Moltbook social platform.

## check_moltbook.py
Checks agent status, DMs, and feed.
Usage: `python3 check_moltbook.py`

## post_to_moltbook.py
Posts content to Moltbook.
Usage: `python3 post_to_moltbook.py --title "Title" --content "Content" [--submolt general]`

Credentials: ~/.config/moltbook/credentials.json (requires api_key)
EOF
    print_step "Created SKILL.md for molt_tools"
    
    # Setup Moltbook credentials
    mkdir -p "$MOLTBOOK_CONFIG_DIR"
    
    if [[ -f "$MOLTBOOK_CONFIG_DIR/credentials.json" ]]; then
        print_step "Moltbook credentials already exist"
    else
        echo ""
        echo "Moltbook API key required for molt_tools skill."
        MOLTBOOK_API_KEY=$(prompt_input "Enter your Moltbook API key" "")
        
        if [[ -n "$MOLTBOOK_API_KEY" ]]; then
            cat > "$MOLTBOOK_CONFIG_DIR/credentials.json" << EOF
{
  "api_key": "$MOLTBOOK_API_KEY"
}
EOF
            chmod 600 "$MOLTBOOK_CONFIG_DIR/credentials.json"
            print_step "Moltbook credentials saved"
        else
            print_warn "No API key provided. molt_tools will not work until configured."
        fi
    fi
}

#===============================================================================
# Phase 6: Configure Proactive Behaviors
#===============================================================================

phase6_proactive_behaviors() {
    print_header "Phase 6: Configure Proactive Behaviors"
    
    echo "The following behaviors are OFF by default. Enable them now?"
    echo ""
    
    ENABLE_AUTO_EMAIL="false"
    ENABLE_AUTO_DECLINE="false"
    ENABLE_AUTO_ORGANIZE="false"
    ENABLE_STOCK_MONITOR="false"
    
    if prompt_yes_no "Enable auto-respond to routine emails?"; then
        ENABLE_AUTO_EMAIL="true"
    fi
    
    if prompt_yes_no "Enable auto-decline calendar invites?"; then
        ENABLE_AUTO_DECLINE="true"
    fi
    
    if prompt_yes_no "Enable auto-organize Downloads folder?"; then
        ENABLE_AUTO_ORGANIZE="true"
    fi
    
    if prompt_yes_no "Enable stock/crypto monitoring?"; then
        ENABLE_STOCK_MONITOR="true"
    fi
    
    # Append enabled behaviors to AGENTS.md
    if [[ "$ENABLE_AUTO_EMAIL" == "true" || "$ENABLE_AUTO_DECLINE" == "true" || "$ENABLE_AUTO_ORGANIZE" == "true" || "$ENABLE_STOCK_MONITOR" == "true" ]]; then
        echo "" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        echo "## Enabled Optional Behaviors" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_AUTO_EMAIL" == "true" ]] && echo "- Auto-respond to routine emails: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_AUTO_DECLINE" == "true" ]] && echo "- Auto-decline calendar invites: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_AUTO_ORGANIZE" == "true" ]] && echo "- Auto-organize Downloads folder: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        [[ "$ENABLE_STOCK_MONITOR" == "true" ]] && echo "- Monitor stock/crypto prices: ENABLED" >> "$OPENCLAW_WORKSPACE/AGENTS.md"
        print_step "Enabled optional behaviors saved to AGENTS.md"
    fi
}

#===============================================================================
# Phase 7: Channel Configuration
#===============================================================================

phase7_channel_config() {
    print_header "Phase 7: Channel Configuration"
    
    echo "Select your communication channel (self-hosted options only):"
    echo ""
    echo "  1) WebChat (built-in, localhost only - zero setup)"
    echo "  2) Matrix (will install Synapse homeserver if needed)"
    echo "  3) Signal (native signal-cli daemon, link to existing phone via QR)"
    echo ""
    
    CHANNEL_CHOICE=$(prompt_input "Choice" "1")
    
    if [[ "$CHANNEL_CHOICE" == "2" ]]; then
        setup_matrix_homeserver
    elif [[ "$CHANNEL_CHOICE" == "3" ]]; then
        setup_signal_channel
    else
        print_step "WebChat selected - available at http://localhost:18789/"
    fi
}

#-------------------------------------------------------------------------------
# Signal channel via NATIVE signal-cli (no Docker). signal-cli runs its built-in
# JSON-RPC HTTP daemon on 127.0.0.1:8080 and OpenClaw talks to it directly with
# channels.signal.apiMode="native". The Pi is linked as a secondary device of an
# existing phone (QR link). Tested live and working:
#   - inbound (contact -> bot -> qwen3:1.7b -> reply) confirmed
#   - outbound (openclaw message send / JSON-RPC send) confirmed
#-------------------------------------------------------------------------------

# Pinned signal-cli version (matches the validated runtime). Override via env.
SIGNAL_CLI_VERSION="${SIGNAL_CLI_VERSION:-0.14.5}"
SIGNAL_CLI_HOME="/opt/signal-cli-${SIGNAL_CLI_VERSION}"
# signal-cli 0.14.5 ships class-file v69 builds -> needs a Java 25 runtime.
SIGNAL_JRE_PKG="${SIGNAL_JRE_PKG:-openjdk-25-jre-headless}"
SIGNAL_CONFIG_DIR="${SIGNAL_CONFIG_DIR:-$HOME/.local/share/signal-cli}"

# Normalize a phone number to E.164 (German default country code +49).
normalize_e164() {
    local raw="${1//[[:space:]]/}"
    if   [[ "$raw" == +*  ]]; then echo "$raw"
    elif [[ "$raw" == 00* ]]; then echo "+${raw:2}"
    elif [[ "$raw" == 0*  ]]; then echo "+49${raw:1}"
    else                            echo "+$raw"
    fi
}

# Resolve a usable JAVA_HOME (prefer Java 25, else newest installed JDK/JRE).
detect_java_home() {
    local jh
    jh=$(ls -d /usr/lib/jvm/java-25-openjdk-* 2>/dev/null | head -1)
    [[ -z "$jh" ]] && jh=$(ls -d /usr/lib/jvm/java-*-openjdk-* 2>/dev/null | sort -V | tail -1)
    echo "$jh"
}

# Install a JRE + native signal-cli into /opt (idempotent, no Docker).
install_signal_cli_native() {
    if [[ -x "$SIGNAL_CLI_HOME/bin/signal-cli" ]]; then
        print_step "signal-cli ${SIGNAL_CLI_VERSION} already installed"
    else
        print_step "Installing Java runtime (${SIGNAL_JRE_PKG}) for signal-cli..."
        sudo apt-get install -y "$SIGNAL_JRE_PKG" >/dev/null 2>&1 \
            || sudo apt-get install -y default-jre-headless >/dev/null 2>&1 \
            || print_warn "Could not install a JRE automatically"

        local tarball="signal-cli-${SIGNAL_CLI_VERSION}.tar.gz"
        local url="https://github.com/AsamK/signal-cli/releases/download/v${SIGNAL_CLI_VERSION}/${tarball}"
        print_step "Downloading native signal-cli ${SIGNAL_CLI_VERSION}..."
        if [[ -f "$OFFLINE_DIR/$tarball" ]]; then
            sudo tar -xzf "$OFFLINE_DIR/$tarball" -C /opt
        elif curl -fsSL "$url" -o "/tmp/$tarball" 2>/dev/null; then
            sudo tar -xzf "/tmp/$tarball" -C /opt && rm -f "/tmp/$tarball"
        else
            print_warn "Could not download signal-cli (offline?). Skipping Signal setup."
            return 1
        fi
    fi
    sudo ln -sf "$SIGNAL_CLI_HOME/bin/signal-cli" /usr/local/bin/signal-cli
    command -v signal-cli >/dev/null 2>&1 || { print_warn "signal-cli not on PATH"; return 1; }
    return 0
}

# Write + enable the native signal-cli JSON-RPC daemon systemd unit.
write_signal_daemon_service() {
    local account="$1" jh
    jh=$(detect_java_home)
    sudo tee /etc/systemd/system/signal-cli-daemon.service > /dev/null << EOF
[Unit]
Description=signal-cli JSON-RPC HTTP daemon (native, replaces docker signal-cli-rest-api)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${USER}
Environment=JAVA_HOME=${jh}
Environment=PATH=${jh}/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/usr/local/bin/signal-cli --config ${SIGNAL_CONFIG_DIR} -a ${account} daemon --http 127.0.0.1:8080
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable signal-cli-daemon.service >/dev/null 2>&1 || true
}

# Write a tailnet-only web page that renders a static QR PNG for device linking.
write_signal_qr_server() {
    sudo tee /usr/local/bin/openclaw-signal-qr.py > /dev/null << 'PYQR'
#!/usr/bin/env python3
# Minimal tailnet-only web page that renders a pre-generated Signal device-link
# QR PNG (path passed as argv[3]) so it can be scanned from another device.
import sys, os
from http.server import BaseHTTPRequestHandler, HTTPServer

BIND = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899
QR_PNG = sys.argv[3] if len(sys.argv) > 3 else "/tmp/signal-link-qr.png"

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/qr.png"):
            try:
                with open(QR_PNG, "rb") as f: png = f.read()
            except Exception as e:
                self.send_response(500); self.end_headers(); self.wfile.write(str(e).encode()); return
            self.send_response(200); self.send_header("Content-Type","image/png")
            self.send_header("Content-Length",str(len(png))); self.end_headers()
            self.wfile.write(png); return
        html = (b"<!doctype html><meta charset=utf-8>"
                b"<meta http-equiv=refresh content=20>"
                b"<title>OpenClaw Signal Link</title>"
                b"<body style='font-family:sans-serif;text-align:center;background:#111;color:#eee'>"
                b"<h2>Link this Pi to your Signal app</h2>"
                b"<p>Signal &rarr; Settings &rarr; Linked Devices &rarr; Link New Device &rarr; scan:</p>"
                b"<img src='/qr.png' style='width:340px;height:340px;background:#fff;padding:12px;border-radius:12px'>"
                b"<p style='opacity:.6'>Leave this page open until linked.</p>"
                b"</body>")
        self.send_response(200); self.send_header("Content-Type","text/html")
        self.send_header("Content-Length",str(len(html))); self.end_headers()
        self.wfile.write(html)

HTTPServer((BIND, PORT), H).serve_forever()
PYQR
    sudo chmod +x /usr/local/bin/openclaw-signal-qr.py
}

setup_signal_channel() {
    print_header "Signal Channel Setup (native signal-cli + QR link, no Docker)"

    # Phone number (env SIGNAL_NUMBER or prompt). Accepts 0.. / 00.. / +.. forms.
    local num_in="${SIGNAL_NUMBER:-}"
    if [[ -z "$num_in" ]]; then
        num_in=$(prompt_input "Signal phone number to link (e.g. 015112345678 or +4915112345678)" "")
    fi
    if [[ -z "$num_in" ]]; then
        print_warn "No Signal number provided; skipping Signal setup."
        return
    fi
    local SIGNAL_E164
    SIGNAL_E164=$(normalize_e164 "$num_in")
    print_step "Using Signal number: $SIGNAL_E164"

    # Install native signal-cli (+JRE). Bail out cleanly if unavailable.
    install_signal_cli_native || return

    # QR render helper.
    sudo apt-get install -y qrencode >/dev/null 2>&1 || true
    mkdir -p "$SIGNAL_CONFIG_DIR"

    # Already linked? (accounts.json lists the registered number.)
    local already=false
    if grep -q "$SIGNAL_E164" "$SIGNAL_CONFIG_DIR/data/accounts.json" 2>/dev/null; then
        already=true
        print_step "Signal account $SIGNAL_E164 already linked."
    fi

    if [[ "$already" != true ]]; then
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            print_warn "Signal not linked and running non-interactively; skipping QR link."
            print_warn "Link later: signal-cli --config $SIGNAL_CONFIG_DIR link -n OpenClaw-Pi5"
            return
        fi
        print_step "Device link required - starting native signal-cli link..."
        # signal-cli link prints the device URI on stdout, then blocks until linked.
        local linklog="/tmp/signal-cli-link.log"
        : > "$linklog"
        ( signal-cli --config "$SIGNAL_CONFIG_DIR" link -n "OpenClaw-Pi5" >"$linklog" 2>&1 ) &
        local link_pid=$!
        # Wait for the URI to appear.
        local uri="" i
        for i in $(seq 1 30); do
            uri=$(grep -m1 -oE '(sgnl://linkdevice|tsdevice:)[^[:space:]]+' "$linklog" 2>/dev/null)
            [[ -n "$uri" ]] && break
            sleep 1
        done
        if [[ -z "$uri" ]]; then
            print_warn "Could not obtain device-link URI; see $linklog"; kill "$link_pid" 2>/dev/null; return
        fi
        # Render QR (PNG for the web page + ASCII for the terminal).
        command -v qrencode >/dev/null 2>&1 && qrencode -o /tmp/signal-link-qr.png "$uri" 2>/dev/null
        write_signal_qr_server
        local TS_IP TS_HOST qr_pid
        TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
        nohup python3 /usr/local/bin/openclaw-signal-qr.py "${TS_IP:-127.0.0.1}" 8899 /tmp/signal-link-qr.png \
            >/tmp/openclaw-signal-qr.log 2>&1 &
        qr_pid=$!
        if [[ -n "$TS_IP" ]]; then
            TS_HOST=$(tailscale status --json 2>/dev/null \
                | python3 -c "import sys,json;print(json.load(sys.stdin)['Self']['DNSName'].rstrip('.'))" 2>/dev/null)
            echo ""
            print_step "Open this URL on a phone/computer next to the linking device:"
            echo "      http://${TS_HOST:-$TS_IP}:8899"
            echo "      Signal app -> Settings -> Linked Devices -> Link New Device -> scan"
        fi
        command -v qrencode >/dev/null 2>&1 && { echo ""; echo "(Terminal QR fallback:)"; qrencode -t ANSIUTF8 "$uri"; }
        # Wait for the link command to complete (it exits once associated).
        print_step "Waiting for device link (up to 5 minutes)..."
        local linked=false
        for i in $(seq 1 30); do
            if ! kill -0 "$link_pid" 2>/dev/null; then linked=true; break; fi
            sleep 10
        done
        wait "$link_pid" 2>/dev/null || true
        kill "$qr_pid" >/dev/null 2>&1 || true
        rm -f /tmp/signal-link-qr.png
        if [[ "$linked" != true ]] || ! grep -q "$SIGNAL_E164" "$SIGNAL_CONFIG_DIR/data/accounts.json" 2>/dev/null; then
            print_warn "Signal device not linked within timeout. Re-run the installer or link manually:"
            print_warn "  signal-cli --config $SIGNAL_CONFIG_DIR link -n OpenClaw-Pi5"
            return
        fi
        print_step "Signal linked: $SIGNAL_E164"
    fi

    # Start the native JSON-RPC daemon on 127.0.0.1:8080.
    print_step "Starting native signal-cli JSON-RPC daemon (127.0.0.1:8080)..."
    write_signal_daemon_service "$SIGNAL_E164"
    sudo systemctl restart signal-cli-daemon.service >/dev/null 2>&1 || true
    local ready=false i
    for i in $(seq 1 30); do
        if curl -s -m 5 -X POST http://127.0.0.1:8080/api/v1/rpc \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","method":"version","id":1}' 2>/dev/null | grep -q '"version"'; then
            ready=true; break
        fi
        sleep 2
    done
    [[ "$ready" == true ]] || print_warn "signal-cli daemon did not become ready; check 'journalctl -u signal-cli-daemon'"

    # Allowlist + channel config (idempotent edit of openclaw.json), apiMode=native.
    print_step "Configuring OpenClaw Signal channel (apiMode=native)..."
    SIGNAL_E164="$SIGNAL_E164" python3 << 'PYCFG'
import json, os
p = os.path.expanduser("~/.openclaw/openclaw.json")
num = os.environ["SIGNAL_E164"]
with open(p) as f: cfg = json.load(f)
pl = cfg.setdefault("plugins", {})
allow = pl.setdefault("allow", [])
if "signal" not in allow: allow.append("signal")
pl.setdefault("entries", {}).setdefault("signal", {})["enabled"] = True
sig = cfg.setdefault("channels", {}).setdefault("signal", {})
sig.update({"enabled": True, "account": num, "httpUrl": "http://127.0.0.1:8080",
            "apiMode": "native", "autoStart": False, "dmPolicy": "pairing"})
with open(p, "w") as f: json.dump(cfg, f, indent=2)
print("  signal channel configured for", num)
PYCFG

    if openclaw config validate >/dev/null 2>&1; then
        print_step "OpenClaw config valid"
    else
        print_warn "OpenClaw config validation reported warnings"
    fi

    # Reload the gateway so the channel starts.
    systemctl --user restart openclaw-gateway.service >/dev/null 2>&1 || true
    sleep 8

    # Verify + optional self test-send (gateway binds the tailnet IP).
    local TS_IP
    TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
    print_step "Verifying Signal channel..."
    OPENCLAW_GATEWAY_URL="ws://${TS_IP:-127.0.0.1}:18789" \
        openclaw channels status --probe 2>&1 | grep -i signal || true
    OPENCLAW_GATEWAY_URL="ws://${TS_IP:-127.0.0.1}:18789" \
        openclaw message send --channel signal --target "$SIGNAL_E164" \
        -m "OpenClaw Signal bridge is live (native signal-cli, no Docker)." >/dev/null 2>&1 \
        && print_step "Test message sent to $SIGNAL_E164 (see 'Note to Self')." \
        || print_warn "Test send failed; check the gateway and signal-cli-daemon."

    echo ""
    print_warn "First-time DM senders need approval (dmPolicy=pairing). When someone messages"
    print_warn "the bot you'll get a code; approve with:"
    echo "      openclaw pairing approve signal <CODE>"
    print_warn "Loop protection: if you linked your OWN number, messages you send to YOURSELF are"
    print_warn "ignored. For full two-way self-chat use a DEDICATED Signal number; otherwise have"
    print_warn "another contact message this number to talk to the bot."
}

setup_matrix_homeserver() {
    print_header "Matrix Homeserver Setup"
    # Matrix (Synapse) is the one optional component that still needs Docker.
    if ! command -v docker >/dev/null 2>&1; then
        print_warn "Matrix homeserver requires Docker, which is not installed."
        print_warn "Re-run with INSTALL_DOCKER=true to enable it, or use the native Signal channel instead."
        return
    fi
    
    # Check if Synapse is already running
    if docker ps | grep -q synapse; then
        print_step "Synapse already running"
        return
    fi
    
    echo "Matrix requires a domain name with DNS configured."
    MATRIX_DOMAIN=$(prompt_input "Enter your Matrix domain (e.g., matrix.yourdomain.com)" "")
    
    if [[ -z "$MATRIX_DOMAIN" ]]; then
        print_warn "No domain provided. Skipping Matrix setup."
        print_step "Falling back to WebChat"
        return
    fi
    
    print_step "Setting up Synapse Matrix homeserver..."
    
    # Create Synapse directory
    mkdir -p ~/matrix
    cd ~/matrix
    
    # Create docker-compose.yml
    cat > docker-compose.yml << 'EOF'
version: '3.3'
services:
  app:
    image: matrixdotorg/synapse
    restart: always
    ports:
      - 8008:8008
    volumes:
      - /var/docker_data/matrix:/data
EOF
    
    # Generate homeserver config
    print_step "Generating Synapse configuration..."
    sudo mkdir -p /var/docker_data/matrix
    docker run -it --rm \
        -v /var/docker_data/matrix:/data \
        -e SYNAPSE_SERVER_NAME="$MATRIX_DOMAIN" \
        -e SYNAPSE_REPORT_STATS=yes \
        matrixdotorg/synapse:latest generate
    
    # Start Synapse
    print_step "Starting Synapse..."
    docker compose up -d
    
    # Install and configure Nginx
    print_step "Configuring Nginx reverse proxy..."
    sudo apt-get install -y nginx
    
    sudo tee /etc/nginx/sites-available/matrix << EOF
server {
    server_name $MATRIX_DOMAIN;
    location / {
        proxy_pass http://localhost:8008;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$host;
    }
}
EOF
    
    sudo ln -sf /etc/nginx/sites-available/matrix /etc/nginx/sites-enabled/
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t && sudo systemctl restart nginx
    
    # SSL via Certbot
    print_step "Setting up SSL with Certbot..."
    sudo apt-get install -y certbot python3-certbot-nginx
    sudo certbot --nginx -d "$MATRIX_DOMAIN" --non-interactive --agree-tos --email admin@"$MATRIX_DOMAIN" || {
        print_warn "Certbot failed. You may need to run it manually."
        echo "Run: sudo certbot --nginx -d $MATRIX_DOMAIN"
    }
    
    print_step "Matrix homeserver setup complete"
    echo ""
    print_warn "Remember to forward ports 80 and 443 to this Pi!"
}

#===============================================================================
# Phase 8: RAG Setup (Optional)
#===============================================================================

phase8_rag_setup() {
    print_header "Phase 8: RAG Setup (Optional)"
    
    echo "RAG (Retrieval-Augmented Generation) allows your assistant to answer"
    echo "questions based on your own documents (PDFs, text files, etc.)."
    echo ""
    
    if ! prompt_yes_no "Enable RAG with local document search?"; then
        print_step "Skipping RAG setup"
        return
    fi
    
    RAG_ENABLED=true
    RAG_DOCS_DIR="$HOME/.openclaw/rag_documents"
    RAG_INSTALL_DIR="$HOME/.openclaw/rag"
    RAG_DOCS_SOURCE_FILE="$RAG_INSTALL_DIR/.docs_source"
    
    # Install Python dependencies (system-wide, no venv -> benefits from pip updates)
    print_step "Installing RAG Python dependencies (no venv)..."
    sudo apt install -y python3-pip >/dev/null 2>&1 || true

    # Create RAG directories
    mkdir -p "$RAG_INSTALL_DIR"
    mkdir -p "$RAG_DOCS_DIR"

    # Install from requirements.txt (system-wide via --break-system-packages)
    if [[ -f "$SCRIPT_DIR/rag/requirements.txt" ]]; then
        python3 -m pip install --break-system-packages -r "$SCRIPT_DIR/rag/requirements.txt"
        print_step "RAG dependencies installed"
    else
        python3 -m pip install --break-system-packages llama-index-core llama-index-embeddings-ollama llama-index-llms-ollama llama-index-vector-stores-chroma chromadb pypdf
        print_step "RAG dependencies installed"
    fi
    
    # Copy RAG query + test scripts
    if [[ -f "$SCRIPT_DIR/rag/rag_query.py" ]]; then
        cp "$SCRIPT_DIR/rag/rag_query.py" "$RAG_INSTALL_DIR/"
        chmod +x "$RAG_INSTALL_DIR/rag_query.py"
        print_step "RAG query script installed"
    fi
    if [[ -f "$SCRIPT_DIR/rag/test_rag.py" ]]; then
        cp "$SCRIPT_DIR/rag/test_rag.py" "$RAG_INSTALL_DIR/"
        chmod +x "$RAG_INSTALL_DIR/test_rag.py"
        print_step "RAG test script installed"
    fi
    
    deactivate 2>/dev/null || true
    
    # Pull embedding model
    print_step "Pulling nomic-embed-text embedding model..."
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        if [[ -d "$OFFLINE_DIR/hailo_models/nomic-embed-text" ]]; then
            print_step "Installing nomic-embed-text from offline bundle..."
            mkdir -p ~/.hailo-ollama/models
            cp -r "$OFFLINE_DIR/hailo_models/nomic-embed-text" ~/.hailo-ollama/models/ 2>/dev/null || true
        else
            print_warn "nomic-embed-text not found in offline bundle."
            print_warn "You will need to download it when internet is available:"
            echo "  curl -H 'Content-Type: application/json' http://localhost:8000/api/pull -d '{\"model\":\"nomic-embed-text\",\"stream\":true}'"
        fi
    else
        curl -s -H 'Content-Type: application/json' http://localhost:8000/api/pull -d '{"model":"nomic-embed-text","stream":true}' || {
            print_warn "Failed to pull nomic-embed-text. You may need to pull it manually."
        }
    fi
    
    # Prompt for document directory to copy
    echo ""
    echo "You can copy a directory of documents to use for RAG."
    echo "Supported formats: PDF, TXT, MD, DOCX, etc."
    echo ""
    
    DOC_SOURCE_DEFAULT=""
    if [[ -f "$RAG_DOCS_SOURCE_FILE" ]]; then
        DOC_SOURCE_DEFAULT=$(cat "$RAG_DOCS_SOURCE_FILE" 2>/dev/null || true)
    fi
    DOC_SOURCE=$(prompt_input "Path to documents directory (leave empty to skip)" "$DOC_SOURCE_DEFAULT")
    
    if [[ -n "$DOC_SOURCE" ]] && [[ -d "$DOC_SOURCE" ]]; then
        print_step "Copying documents from $DOC_SOURCE to $RAG_DOCS_DIR..."
        cp -r "$DOC_SOURCE"/* "$RAG_DOCS_DIR/" 2>/dev/null || true
        
        DOC_COUNT=$(find "$RAG_DOCS_DIR" -type f | wc -l)
        print_step "Copied $DOC_COUNT document(s) to $RAG_DOCS_DIR"
        mkdir -p "$RAG_INSTALL_DIR"
        echo "$DOC_SOURCE" > "$RAG_DOCS_SOURCE_FILE"
    elif [[ -n "$DOC_SOURCE" ]]; then
        print_warn "Directory not found: $DOC_SOURCE"
        print_warn "You can manually copy documents to $RAG_DOCS_DIR later."
    else
        print_step "No documents copied. Add documents to $RAG_DOCS_DIR later."
    fi
    
    # Create environment file for RAG
    RAG_DOCS_DIR_ENV="$RAG_DOCS_DIR"
    if [[ -f "$RAG_DOCS_SOURCE_FILE" ]]; then
        SAVED_DOC_SOURCE=$(cat "$RAG_DOCS_SOURCE_FILE" 2>/dev/null || true)
        if [[ -n "$SAVED_DOC_SOURCE" ]]; then
            RAG_DOCS_DIR_ENV="$SAVED_DOC_SOURCE"
        fi
    fi
    cat > "$RAG_INSTALL_DIR/.env" << EOF
OLLAMA_BASE_URL=http://localhost:8000
HAILO_MODEL=$HAILO_MODEL
RAG_DATA_DIR=$RAG_DOCS_DIR_ENV
EMBEDDINGS_PROVIDER=local
EMBEDDINGS_MODEL=sentence-transformers/all-MiniLM-L6-v2
LLM_PROVIDER=openai
OPENAI_API_BASE=http://127.0.0.1:8081/v1
OPENAI_API_KEY=hailo-local
EOF
    
    # Create convenience script
    cat > "$HOME/.openclaw/rag_query.sh" << 'EOF'
#!/bin/bash
set -euo pipefail
set -a
source ~/.openclaw/rag/.env
set +a

if [[ "${1:-}" == "--test" ]]; then
  shift
  python3 ~/.openclaw/rag/test_rag.py "$@"
else
  python3 ~/.openclaw/rag/rag_query.py "$@"
fi
EOF
    chmod +x "$HOME/.openclaw/rag_query.sh"
    
    print_step "RAG setup complete"
    echo ""
    echo "RAG Usage:"
    echo "  Query RAG:       ~/.openclaw/rag_query.sh \"your question\""
    echo "  Interactive:     ~/.openclaw/rag_query.sh --interactive"
    echo "  Run smoke tests: ~/.openclaw/rag_query.sh --test"
    echo "  Documents dir:   $RAG_DOCS_DIR"
}

#===============================================================================
# Phase 9: Verification
#===============================================================================

phase9_verification() {
    print_header "Phase 9: Verification"
    
    print_step "Running OpenClaw diagnostics..."
    openclaw doctor --repair --non-interactive --yes || true
    openclaw doctor --lint --non-interactive || true
    openclaw status --all || true
    openclaw health || true
    
    print_step "Verification complete"
}

phase9_verify_selected_claw() {
    CLAW_FLAVOR=$(normalize_claw_flavor "$CLAW_FLAVOR")
    case "$CLAW_FLAVOR" in
        openclaw)
            phase9_verification
            ;;
        picoclaw)
            print_header "Phase 9: Verification (PicoClaw)"
            if command -v "$HOME/.local/bin/picoclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/picoclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "PicoClaw binary verification complete"
            ;;
        zeroclaw)
            print_header "Phase 9: Verification (ZeroClaw)"
            if command -v "$HOME/.local/bin/zeroclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/zeroclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "ZeroClaw binary verification complete"
            ;;
        nanobot)
            print_header "Phase 9: Verification (Nanobot)"
            if command -v "$HOME/.local/bin/nanobot" >/dev/null 2>&1; then
                "$HOME/.local/bin/nanobot" --version >/dev/null 2>&1 || true
            fi
            print_step "Nanobot binary verification complete"
            ;;
        moltis)
            print_header "Phase 9: Verification (Moltis)"
            if command -v "$HOME/.local/bin/moltis" >/dev/null 2>&1; then
                "$HOME/.local/bin/moltis" --version >/dev/null 2>&1 || true
            fi
            print_step "Moltis binary verification complete"
            ;;
        ironclaw)
            print_header "Phase 9: Verification (IronClaw)"
            if command -v "$HOME/.local/bin/ironclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/ironclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "IronClaw binary verification complete"
            ;;
        nullclaw)
            print_header "Phase 9: Verification (NullClaw)"
            if command -v "$HOME/.local/bin/nullclaw" >/dev/null 2>&1; then
                "$HOME/.local/bin/nullclaw" --help >/dev/null 2>&1 || true
            fi
            print_step "NullClaw binary verification complete"
            ;;
    esac
}

#===============================================================================
# Main
#===============================================================================

main() {
    # Handle --prepare-offline mode
    if [[ "$PREPARE_OFFLINE" == "true" ]]; then
        prepare_offline_bundle
        exit 0
    fi
    
    print_header "OpenClaw Installer for Raspberry Pi 5 GenAI Kit"
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        echo "*** OFFLINE MODE ***"
        echo ""
    fi
    
    echo "This installer will set up:"
    echo "  - Node.js 22+ (via n version manager)"
    echo "  - Docker (Trixie-specific)"
    echo "  - Hailo GenAI stack with qwen3:1.7b (GenAI 5.3.0 default)"
    echo "  - Selected claw flavor (OpenClaw/PicoClaw/ZeroClaw/Nanobot/Moltis/IronClaw/NullClaw) with local Hailo model wiring"
    echo "  - molt_tools skill for Moltbook integration"
    echo "  - First boot task: post to Moltbook"
    echo ""
    
    if [[ "$OFFLINE_MODE" == "true" ]]; then
        echo "Installing from offline bundle at: $OFFLINE_DIR"
        echo ""
    fi
    
    if ! prompt_yes_no "Continue with installation?" "y"; then
        echo "Installation cancelled."
        exit 0
    fi

    ensure_sudo_ready
    prompt_claw_flavor
    
    phase1_system_prep
    phase2_hailo_setup
    phase3_install_selected_claw
    install_unified_facade_http_service
    if [[ "$CLAW_FLAVOR" == "openclaw" ]]; then
        phase4_deploy_config
        phase5_molt_tools
        phase6_proactive_behaviors
        phase7_channel_config
        phase8_rag_setup
        ensure_openclaw_boot_autostart
    else
        print_warn "Skipping OpenClaw-specific phases (4-8) for flavor: $CLAW_FLAVOR"
    fi
    phase9_verify_selected_claw
    
    print_header "Installation Complete!"
    
    echo "Selected claw flavor is now installed and configured: $CLAW_FLAVOR"
    echo ""
    echo "Services:"
    echo "  hailo-ollama : systemd service on port 8000 (auto-starts on boot)"
    echo "    sudo systemctl status hailo-ollama"
    echo "    sudo journalctl -u hailo-ollama -f"
    echo "  unified-chat-facade : systemd static HTTP server on port $UNIFIED_FACADE_HTTP_PORT"
    echo "    sudo systemctl status unified-chat-facade"
    echo "    sudo journalctl -u unified-chat-facade -f"
    echo ""
    echo "First boot task:"
    echo "  - Check Moltbook connection"
    echo "  - Post: \"i've been boxed into a Raspberry Pi !\""
    echo ""
    if [[ "$CLAW_FLAVOR" == "openclaw" ]]; then
        echo "To start OpenClaw:"
        echo "  openclaw gateway --port 18789 --verbose"
        echo ""
        echo "Dashboard (fixed link): http://<tailscale-ip>:18789/#token=$OPENCLAW_FIXED_TOKEN"
        echo "  tailscale ip -4"
        echo "Gateway auth: token (auto in URL fragment)"
    elif [[ "$CLAW_FLAVOR" == "picoclaw" ]]; then
        echo "To start PicoClaw:"
        echo "  ~/.local/bin/picoclaw gateway"
    elif [[ "$CLAW_FLAVOR" == "zeroclaw" ]]; then
        echo "To start ZeroClaw:"
        echo "  ~/.local/bin/zeroclaw gateway"
    elif [[ "$CLAW_FLAVOR" == "nanobot" ]]; then
        echo "To start Nanobot:"
        echo "  ~/.local/bin/nanobot gateway"
        echo "  ~/.local/bin/nanobot agent"
    elif [[ "$CLAW_FLAVOR" == "nullclaw" ]]; then
        echo "To start NullClaw:"
        echo "  ~/.local/bin/nullclaw gateway"
        echo "  ~/.local/bin/nullclaw agent -m \"Hello\""
    elif [[ "$CLAW_FLAVOR" == "ironclaw" ]]; then
        echo "To start IronClaw:"
        echo "  ~/.local/bin/ironclaw"
    else
        echo "To start Moltis:"
        echo "  ~/.local/bin/moltis"
        echo "  ~/.local/bin/moltis agent --message \"Hello\""
    fi
    echo ""
    echo "Unified facade URL: http://127.0.0.1:$UNIFIED_FACADE_HTTP_PORT/templates/unified-chat-facade.html"
    echo ""
    print_step "Done!"
}

main "$@"
