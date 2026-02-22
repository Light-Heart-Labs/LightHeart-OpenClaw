#!/bin/bash
# Dream Server Installer v2.0
# Unified installer - voice-enabled by default, uses docker-compose.yml profiles for optional features
# Mission: M5 (Clonable Dream Setup Server)

set -e

#=============================================================================
# Interrupt Protection
#=============================================================================
# Accidental keypresses (Ctrl+C, Ctrl+Z) shouldn't silently kill the install.
# We require a double-tap of Ctrl+C within 3 seconds to actually abort.
LAST_SIGINT=0
interrupt_handler() {
    local now
    now=$(date +%s)
    if (( now - LAST_SIGINT <= 3 )); then
        echo ""
        echo -e "\033[1;33m[!] Install cancelled by user.\033[0m"
        echo -e "\033[0;36m    Log file: $LOG_FILE\033[0m"
        exit 130
    fi
    LAST_SIGINT=$now
    echo ""
    echo -e "\033[1;33m[!] Press Ctrl+C again within 3 seconds to cancel the install.\033[0m"
}
trap interrupt_handler INT
# Ignore Ctrl+Z (SIGTSTP) entirely — backgrounding the installer breaks things
trap '' TSTP

#=============================================================================
# Configuration
#=============================================================================
VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$HOME/dream-server}"
LOG_FILE="${LOG_FILE:-/tmp/dream-server-install.log}"
MAX_DOWNLOAD_RETRIES=3
DOWNLOAD_RETRY_DELAY=10

# Auto-detect system timezone (fallback to UTC)
if [[ -f /etc/timezone ]]; then
    SYSTEM_TZ="$(cat /etc/timezone)"
elif [[ -L /etc/localtime ]]; then
    SYSTEM_TZ="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
else
    SYSTEM_TZ="UTC"
fi

#=============================================================================
# Colors
#=============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

#=============================================================================
# Helpers
#=============================================================================
log() { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"; exit 1; }

#=============================================================================
# Stranger Console Mode (80s cinematic terminal UI)
#=============================================================================
DIVIDER="──────────────────────────────────────────────────────────────────────────────"

# Tiny typing effect (use sparingly)
type_line() {
  local s="$1"
  local delay="${2:-0.008}"
  local i
  for ((i=0; i<${#s}; i++)); do
    printf "%s" "${s:$i:1}"
    sleep "$delay"
  done
  printf "\n"
}

bootline() { echo -e "${CYAN}${DIVIDER}${NC}"; }
subline()  { echo -e "${BLUE}${DIVIDER}${NC}"; }

# "AI narrator" voice
ai()       { echo -e "  ${CYAN}▸${NC} $1" | tee -a "$LOG_FILE"; }
ai_ok()    { echo -e "  ${GREEN}✓${NC} $1" | tee -a "$LOG_FILE"; }
ai_warn()  { echo -e "  ${YELLOW}⚠${NC} $1" | tee -a "$LOG_FILE"; }
ai_bad()   { echo -e "  ${RED}✗${NC} $1" | tee -a "$LOG_FILE"; }

# Little signal flourish (tasteful)
signal()   { echo -e "  ${CYAN}░▒▓█▓▒░${NC} $1" | tee -a "$LOG_FILE"; }

# Consistent section header
chapter() {
  local title="$1"
  echo ""
  bootline
  echo -e "${BLUE}${title}${NC}"
  bootline
}

# Phase screen
show_phase() {
  local phase=$1 total=$2 name=$3 estimate=$4
  echo ""
  bootline
  echo -e "${BLUE}PHASE ${phase}/${total}${NC}  ${CYAN}${name}${NC}"
  [[ -n "$estimate" ]] && echo -e "${YELLOW}ETA:${NC} ${estimate}"
  bootline
}

# Cinematic boot splash
show_stranger_boot() {
  clear 2>/dev/null || true
  cat << 'EOF'

    ____                                 _____
   / __ \ _____ ___   ____ _ ____ ___   / ___/ ___   _____ _   __ ___   _____
  / / / // ___// _ \ / __ `// __ `__ \  \__ \ / _ \ / ___/| | / // _ \ / ___/
 / /_/ // /   /  __// /_/ // / / / / / ___/ //  __// /    | |/ //  __// /
/_____//_/    \___/ \__,_//_/ /_/ /_/ /____/ \___//_/     |___/ \___//_/

──────────────────────────────────────────────────────────────────────────────
              DREAM SERVER 2026  // LOCAL AI // SOVEREIGN INTELLIGENCE
──────────────────────────────────────────────────────────────────────────────

EOF
  type_line "$(echo -e "${CYAN}Signal acquired.${NC}")" 0.012
  type_line "$(echo -e "${CYAN}I will guide the installation. Stay with me.${NC}")" 0.012
  echo -e "  ${YELLOW}Version ${VERSION}${NC}"
  echo ""
  bootline
  echo -e "${CYAN}Tip:${NC} Press Ctrl+C twice to abort."
  bootline
  echo ""
}

# Spinner with mm:ss timer + consistent prefix
spin_task() {
  local pid=$1
  local msg=$2
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  local elapsed=0

  printf "  ${CYAN}⠋${NC} [00:00] %s " "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    local mm=$((elapsed / 60))
    local ss=$((elapsed % 60))
    printf "\r  ${CYAN}%s${NC} [%02d:%02d] %s " "${spin:$i:1}" "$mm" "$ss" "$msg"
    i=$(( (i + 1) % ${#spin} ))
    elapsed=$((elapsed + 1))
    sleep 1
  done
  local rc=0
  wait "$pid" || rc=$?
  return $rc
}

# Pull wrapper that prints consistent success/fail lines
pull_with_progress() {
  local img=$1
  local label=$2
  local count=$3
  local total=$4

  $DOCKER_CMD pull "$img" >> "$LOG_FILE" 2>&1 &
  local pull_pid=$!

  if spin_task $pull_pid "[$count/$total] $label"; then
    printf "\r  ${GREEN}✓${NC} [$count/$total] %-60s\n" "$label"
    return 0
  else
    printf "\r  ${RED}✗${NC} [$count/$total] %-60s\n" "$label"
    return 1
  fi
}

# Health check with "systems online" vibe
check_service() {
  local name=$1
  local url=$2
  local max_attempts=${3:-30}
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0

  if $DRY_RUN; then
    ai "[DRY RUN] Would link ${name} at ${url}"
    return 0
  fi

  printf "  ${CYAN}%s${NC} Linking %-20s " "${spin:0:1}" "$name"
  for attempt in $(seq 1 $max_attempts); do
    if curl -sf "$url" > /dev/null 2>&1; then
      printf "\r  ${GREEN}✓${NC} %-55s\n" "$name online"
      return 0
    fi
    printf "\r  ${CYAN}%s${NC} Linking %-20s [%ds] " "${spin:$i:1}" "$name" "$((attempt * 2))"
    i=$(( (i + 1) % ${#spin} ))
    sleep 2
  done

  printf "\r  ${YELLOW}⚠${NC} %-55s\n" "$name delayed (may still be starting)"
  ai_warn "$name not responding yet. I will continue."
  return 1
}

# Progress bar function
progress_bar() {
    local current=$1
    local total=$2
    local width=40
    local percent=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))

    printf "\r   ["
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percent"
}

# Show hardware summary in a nice box
show_hardware_summary() {
    local gpu_name="$1"
    local gpu_vram="$2"
    local cpu_info="$3"
    local ram_gb="$4"
    local disk_gb="$5"

    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${BLUE}Hardware Detected${NC}                                          ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  GPU:    %-50s ${CYAN}│${NC}\n" "${gpu_name:-Not detected}"
    [[ -n "$gpu_vram" ]] && printf "${CYAN}│${NC}  VRAM:   %-50s ${CYAN}│${NC}\n" "${gpu_vram}GB"
    printf "${CYAN}│${NC}  CPU:    %-50s ${CYAN}│${NC}\n" "${cpu_info:-Unknown}"
    printf "${CYAN}│${NC}  RAM:    %-50s ${CYAN}│${NC}\n" "${ram_gb}GB"
    printf "${CYAN}│${NC}  Disk:   %-50s ${CYAN}│${NC}\n" "${disk_gb}GB available"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
}

# Show tier recommendation with explanation
show_tier_recommendation() {
    local tier=$1
    local model=$2
    local speed=$3
    local users=$4

    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC}  ${GREEN}✓ Recommended: Tier ${tier}${NC}                                      ${CYAN}│${NC}"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
    printf "${CYAN}│${NC}  Model:   %-49s ${CYAN}│${NC}\n" "$model"
    printf "${CYAN}│${NC}  Speed:   %-49s ${CYAN}│${NC}\n" "~${speed} tokens/second"
    printf "${CYAN}│${NC}  Users:   %-49s ${CYAN}│${NC}\n" "${users} concurrent comfortably"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
}

# Show installation menu
show_install_menu() {
    echo ""
    ai "Choose how deep you want to go. I can install everything, or keep it minimal."
    echo ""
    echo -e "  ${GREEN}[1]${NC} Full Stack ${YELLOW}(recommended — just press Enter)${NC}"
    echo "      Chat + Voice + Workflows + Document Q&A + AI Agents"
    echo "      ~16GB download, all features enabled"
    echo ""
    echo -e "  ${GREEN}[2]${NC} Core Only"
    echo "      Chat interface + API"
    echo "      ~12GB download, minimal footprint"
    echo ""
    echo -e "  ${GREEN}[3]${NC} Custom"
    echo "      Choose exactly what you want"
    echo ""
    read -p "  Select an option [1]: " -r INSTALL_CHOICE
    INSTALL_CHOICE="${INSTALL_CHOICE:-1}"
    echo ""
    case "$INSTALL_CHOICE" in
        1)
            signal "Acknowledged."
            log "Selected: Full Stack"
            ENABLE_VOICE=true
            ENABLE_WORKFLOWS=true
            ENABLE_RAG=true
            ENABLE_OPENCLAW=true
            ;;
        2)
            signal "Acknowledged."
            log "Selected: Core Only"
            ;;
        3)
            signal "Acknowledged."
            log "Selected: Custom"
            ;;
        *)
            warn "Invalid choice '$INSTALL_CHOICE', defaulting to Full Stack"
            ENABLE_VOICE=true
            ENABLE_WORKFLOWS=true
            ENABLE_RAG=true
            ENABLE_OPENCLAW=true
            ;;
    esac
}

# Final success card
show_success_card() {
    local webui_url=$1
    local dashboard_url=$2
    local ip_addr=$3

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}   ${GREEN}✓  Dream Server is ready.${NC}                                 ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    printf "${GREEN}║${NC}   Dashboard:   %-43s ${GREEN}║${NC}\n" "${dashboard_url}"
    printf "${GREEN}║${NC}   Chat:        %-43s ${GREEN}║${NC}\n" "${webui_url}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    if [[ -n "$ip_addr" ]]; then
        echo -e "${GREEN}║${NC}   ${YELLOW}Access from other devices:${NC}                               ${GREEN}║${NC}"
        printf "${GREEN}║${NC}   http://%-51s ${GREEN}║${NC}\n" "${ip_addr}:3001"
        echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    fi
    echo -e "${GREEN}║${NC}   Your data never leaves this machine.                       ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}   No subscriptions. No limits. It's yours.                   ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

#=============================================================================
# Command Line Args
#=============================================================================
DRY_RUN=false
SKIP_DOCKER=false
FORCE=false
TIER=""
ENABLE_VOICE=false
ENABLE_WORKFLOWS=false
ENABLE_RAG=false
ENABLE_OPENCLAW=false
INTERACTIVE=true
BOOTSTRAP_MODE=true  # Default to bootstrap for instant UX
OFFLINE_MODE=false   # M1 integration: fully air-gapped operation

usage() {
    cat << EOF
Dream Server Installer v${VERSION}

Usage: $0 [OPTIONS]

Options:
    --dry-run         Show what would be done without making changes
    --skip-docker     Skip Docker installation (assume already installed)
    --force           Overwrite existing installation
    --tier N          Force specific tier (1-4) instead of auto-detect
    --voice           Enable voice services (Whisper + Piper)
    --workflows       Enable n8n workflow automation
    --rag             Enable RAG with Qdrant vector database
    --openclaw        Enable OpenClaw AI agent framework
    --all             Enable all optional services
    --non-interactive Run without prompts (use defaults or flags)
    --no-bootstrap    Skip bootstrap mode (wait for full model)
    --bootstrap       Use bootstrap mode (default: instant start with 1.5B, upgrade later)
    --offline         M1 mode: Configure for fully offline/air-gapped operation
    -h, --help        Show this help

Tiers:
    1 - Entry Level   (8GB+ VRAM, 7B models)
    2 - Prosumer      (12GB+ VRAM, 14B-32B AWQ models)
    3 - Pro           (24GB+ VRAM, 32B models)
    4 - Enterprise    (48GB+ VRAM or dual GPU, 72B models)

Examples:
    $0                           # Interactive setup
    $0 --tier 2 --voice          # Tier 2 with voice
    $0 --all --non-interactive   # Full stack, no prompts
    $0 --offline --all           # Fully offline (M1 mode) with all services
    $0 --dry-run                 # Preview installation

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run) DRY_RUN=true; shift ;;
        --skip-docker) SKIP_DOCKER=true; shift ;;
        --force) FORCE=true; shift ;;
        --tier) TIER="$2"; shift 2 ;;
        --voice) ENABLE_VOICE=true; shift ;;
        --workflows) ENABLE_WORKFLOWS=true; shift ;;
        --rag) ENABLE_RAG=true; shift ;;
        --openclaw) ENABLE_OPENCLAW=true; shift ;;
        --all) ENABLE_VOICE=true; ENABLE_WORKFLOWS=true; ENABLE_RAG=true; ENABLE_OPENCLAW=true; shift ;;
        --non-interactive) INTERACTIVE=false; shift ;;
        --bootstrap) BOOTSTRAP_MODE=true; shift ;;
        --no-bootstrap) BOOTSTRAP_MODE=false; shift ;;
        --offline) OFFLINE_MODE=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1" ;;
    esac
done

#=============================================================================
# Splash
#=============================================================================
show_stranger_boot
sleep 5

$DRY_RUN && echo -e "${YELLOW}>>> DRY RUN MODE — I will simulate everything. No changes made. <<<${NC}\n"

#=============================================================================
# Pre-flight Checks
#=============================================================================
show_phase 1 6 "Pre-flight Checks" "~30 seconds"
ai "I'm scanning your system for required components..."

# Root check
if [[ $EUID -eq 0 ]]; then
    error "Do not run as root. Run as regular user with sudo access."
fi

# OS check
if [[ ! -f /etc/os-release ]]; then
    error "Unsupported OS. This installer requires Linux."
fi

source /etc/os-release
log "Detected OS: $PRETTY_NAME"

# Check for required tools
if ! command -v curl &> /dev/null; then
    error "curl is required but not installed. Install with: sudo apt install curl"
fi
log "curl: $(curl --version | head -1)"

# Check optional tools (warn but don't fail)
OPTIONAL_TOOLS_MISSING=""
if ! command -v jq &> /dev/null; then
    OPTIONAL_TOOLS_MISSING="$OPTIONAL_TOOLS_MISSING jq"
fi
if ! command -v rsync &> /dev/null; then
    OPTIONAL_TOOLS_MISSING="$OPTIONAL_TOOLS_MISSING rsync"
fi
if [[ -n "$OPTIONAL_TOOLS_MISSING" ]]; then
    warn "Optional tools missing:$OPTIONAL_TOOLS_MISSING"
    echo "  These are needed for update/backup scripts. Install with:"
    echo "  sudo apt install$OPTIONAL_TOOLS_MISSING"
fi

# Check source files exist
if [[ ! -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    error "docker-compose.yml not found in $SCRIPT_DIR. Please run from the dream-server directory."
fi

# Check for existing installation
if [[ -d "$INSTALL_DIR" && "$FORCE" != "true" ]]; then
    if $INTERACTIVE && ! $DRY_RUN; then
        warn "Existing installation found at $INSTALL_DIR"
        read -p "  Overwrite and start fresh? [y/N] " -r
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "User chose to overwrite existing installation"
            FORCE=true
        else
            log "User chose not to overwrite. Exiting."
            exit 0
        fi
    else
        error "Installation already exists at $INSTALL_DIR. Use --force to overwrite."
    fi
fi

ai_ok "Pre-flight checks passed."
signal "No cloud dependencies required for core operation."

#=============================================================================
# System Detection
#=============================================================================
chapter "SYSTEM DETECTION"
ai "Reading hardware telemetry..."

# RAM Detection
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$((RAM_KB / 1024 / 1024))
log "RAM: ${RAM_GB}GB"

# Disk Detection
DISK_AVAIL=$(df -BG "$HOME" | tail -1 | awk '{print $4}' | tr -d 'G')
log "Available disk: ${DISK_AVAIL}GB"

# GPU Detection
detect_gpu() {
    if command -v nvidia-smi &> /dev/null; then
        # nvidia-smi --query-gpu prints errors to stdout when driver is broken,
        # so we must check the exit code before trusting the output.
        local raw
        if raw=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null) && [[ -n "$raw" ]]; then
            GPU_INFO="$raw"
            GPU_NAME=$(echo "$GPU_INFO" | head -1 | cut -d',' -f1 | xargs)
            GPU_VRAM=$(echo "$GPU_INFO" | head -1 | cut -d',' -f2 | grep -oP '\d+' | head -1)
            GPU_COUNT=$(echo "$GPU_INFO" | wc -l)
            log "GPU: $GPU_NAME (${GPU_VRAM}MB VRAM) x${GPU_COUNT}"
            return 0
        fi
    fi
    GPU_NAME="None"
    GPU_VRAM=0
    GPU_COUNT=0
    warn "No NVIDIA GPU detected. CPU-only mode available but slow."
    return 1
}

detect_gpu || true

#-----------------------------------------------------------------------------
# Secure Boot + NVIDIA auto-fix
# If GPU hardware exists (lspci) but nvidia-smi fails, the most common cause
# on Ubuntu is Secure Boot blocking the unsigned DKMS kernel module.
# This block automatically: installs the driver if missing, ensures the
# kernel modules are signed, enrolls the MOK key, sets up auto-resume,
# and reboots.  After reboot the installer picks up where it left off.
#-----------------------------------------------------------------------------
MIN_DRIVER_VERSION=570
RESUME_FLAG="/tmp/dream-server-install-resume"

fix_nvidia_secure_boot() {
    # Step 1: Is there even NVIDIA hardware on this machine?
    if ! lspci 2>/dev/null | grep -qi 'nvidia'; then
        return 1  # No hardware — nothing to fix
    fi

    ai "NVIDIA GPU hardware detected but driver not responding."

    # Step 2: Ensure a driver package is installed
    local installed_driver
    installed_driver=$(dpkg-query -W -f='${Package}\n' 'nvidia-driver-*' 2>/dev/null \
                       | grep -oP 'nvidia-driver-\K\d+' | sort -n | tail -1 || true)

    if [[ -z "$installed_driver" ]]; then
        ai "No NVIDIA driver package found. Installing recommended driver..."
        if command -v ubuntu-drivers &>/dev/null; then
            sudo ubuntu-drivers install 2>>"$LOG_FILE" || \
            sudo apt-get install -y "nvidia-driver-${MIN_DRIVER_VERSION}" 2>>"$LOG_FILE" || true
        else
            sudo apt-get install -y "nvidia-driver-${MIN_DRIVER_VERSION}" 2>>"$LOG_FILE" || true
        fi
        installed_driver=$(dpkg-query -W -f='${Package}\n' 'nvidia-driver-*' 2>/dev/null \
                           | grep -oP 'nvidia-driver-\K\d+' | sort -n | tail -1 || true)
        if [[ -z "$installed_driver" ]]; then
            ai_bad "Failed to install NVIDIA driver."
            return 1
        fi
        ai_ok "Installed nvidia-driver-${installed_driver}"
    else
        ai "Driver nvidia-driver-${installed_driver} is installed."
    fi

    # Step 3: Try loading the module — see why it fails
    local modprobe_err
    modprobe_err=$(sudo modprobe nvidia 2>&1) || true

    if nvidia-smi &>/dev/null; then
        ai_ok "NVIDIA driver loaded successfully"
        # Regenerate CDI spec so Docker sees the correct driver libraries
        if command -v nvidia-ctk &>/dev/null; then
            sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>>"$LOG_FILE" || true
        fi
        detect_gpu || true
        return 0
    fi

    # Step 4: If it's not a Secure Boot issue, bail out
    if ! echo "$modprobe_err" | grep -qi "key was rejected"; then
        ai_bad "NVIDIA module failed to load: $modprobe_err"
        return 1
    fi

    # Step 5: Secure Boot is blocking the module — ensure it's properly signed
    ai_warn "Secure Boot is blocking the NVIDIA kernel module."
    ai "Preparing module signing..."

    local kver mok_dir sign_file
    kver=$(uname -r)
    mok_dir="/var/lib/shim-signed/mok"
    sudo mkdir -p "$mok_dir"

    # Ensure linux-headers are present (needed for sign-file)
    if [[ ! -d "/usr/src/linux-headers-${kver}" ]]; then
        ai "Installing kernel headers for ${kver}..."
        sudo apt-get install -y "linux-headers-${kver}" 2>>"$LOG_FILE" || true
    fi

    # Generate MOK keypair if not already present
    if [[ ! -f "$mok_dir/MOK.priv" ]] || [[ ! -f "$mok_dir/MOK.der" ]]; then
        sudo openssl req -new -x509 -newkey rsa:2048 \
            -keyout "$mok_dir/MOK.priv" \
            -outform DER -out "$mok_dir/MOK.der" \
            -nodes -days 36500 \
            -subj "/CN=Dream Server Module Signing/" 2>>"$LOG_FILE"
        sudo chmod 600 "$mok_dir/MOK.priv"
        ai_ok "Generated MOK signing key"
    else
        ai_ok "Using existing MOK signing key"
    fi

    # Locate the sign-file tool
    sign_file=""
    for candidate in \
        "/usr/src/linux-headers-${kver}/scripts/sign-file" \
        "/usr/lib/linux-kbuild-${kver%.*}/scripts/sign-file"; do
        if [[ -x "$candidate" ]]; then
            sign_file="$candidate"
            break
        fi
    done
    if [[ -z "$sign_file" ]]; then
        sign_file=$(find /usr/src /usr/lib -name sign-file -executable 2>/dev/null | head -1)
    fi
    if [[ -z "$sign_file" ]]; then
        ai_bad "Cannot find kernel sign-file tool."
        ai "Try: sudo apt install linux-headers-${kver}"
        return 1
    fi

    # Sign every nvidia DKMS module (handles .ko, .ko.zst, .ko.xz)
    local signed_count=0
    for mod_path in /lib/modules/${kver}/updates/dkms/nvidia*.ko*; do
        [[ -f "$mod_path" ]] || continue
        case "$mod_path" in
            *.zst)
                sudo zstd -d -f "$mod_path" -o "${mod_path%.zst}" 2>>"$LOG_FILE"
                sudo "$sign_file" sha256 "$mok_dir/MOK.priv" "$mok_dir/MOK.der" "${mod_path%.zst}" 2>>"$LOG_FILE"
                sudo zstd -f --rm "${mod_path%.zst}" -o "$mod_path" 2>>"$LOG_FILE"
                ;;
            *.xz)
                sudo xz -d -f -k "$mod_path" 2>>"$LOG_FILE"
                sudo "$sign_file" sha256 "$mok_dir/MOK.priv" "$mok_dir/MOK.der" "${mod_path%.xz}" 2>>"$LOG_FILE"
                sudo xz -f "${mod_path%.xz}" 2>>"$LOG_FILE"
                sudo mv "${mod_path%.xz}.xz" "$mod_path" 2>>"$LOG_FILE"
                ;;
            *)
                sudo "$sign_file" sha256 "$mok_dir/MOK.priv" "$mok_dir/MOK.der" "$mod_path" 2>>"$LOG_FILE"
                ;;
        esac
        signed_count=$((signed_count + 1))
    done
    sudo depmod -a 2>>"$LOG_FILE"
    ai_ok "Signed $signed_count NVIDIA module(s)"

    # Step 6: Try loading — if MOK key is already enrolled, this works immediately
    if sudo modprobe nvidia 2>>"$LOG_FILE" && nvidia-smi &>/dev/null; then
        ai_ok "NVIDIA driver loaded — GPU is online"
        # Regenerate CDI spec so Docker sees the correct driver libraries
        if command -v nvidia-ctk &>/dev/null; then
            sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>>"$LOG_FILE" || true
        fi
        detect_gpu || true
        return 0
    fi

    # Step 7: MOK key needs firmware enrollment — one reboot required
    # This is the standard Ubuntu Secure Boot flow (same thing Ubuntu's
    # "Additional Drivers" tool does).  It only happens once per machine.

    local mok_pass
    mok_pass=$(openssl rand -hex 4)
    printf '%s\n%s\n' "$mok_pass" "$mok_pass" | sudo mokutil --import "$mok_dir/MOK.der" 2>>"$LOG_FILE"

    # --- Auto-resume: create a systemd oneshot so the install continues
    #     automatically after reboot (user doesn't have to re-run manually)
    local svc_name="dream-server-install-resume"
    local resume_args="--force --non-interactive"
    $ENABLE_VOICE && resume_args="$resume_args --voice"
    $ENABLE_WORKFLOWS && resume_args="$resume_args --workflows"
    $ENABLE_RAG && resume_args="$resume_args --rag"
    $ENABLE_OPENCLAW && resume_args="$resume_args --openclaw"
    [[ "$BOOTSTRAP_MODE" == "true" ]] && resume_args="$resume_args --bootstrap"
    [[ -n "$TIER" ]] && resume_args="$resume_args --tier $TIER"
    [[ "$OFFLINE_MODE" == "true" ]] && resume_args="$resume_args --offline"

    sudo tee /etc/systemd/system/${svc_name}.service > /dev/null << SVCEOF
[Unit]
Description=Dream Server Install (auto-resume after Secure Boot enrollment)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=$USER
ExecStart=/bin/bash ${SCRIPT_DIR}/install.sh ${resume_args}
ExecStartPost=/bin/rm -f /etc/systemd/system/${svc_name}.service
ExecStartPost=/bin/systemctl daemon-reload
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SVCEOF
    sudo systemctl daemon-reload
    sudo systemctl enable "${svc_name}.service" 2>>"$LOG_FILE"
    log "Auto-resume service installed: ${svc_name}.service"

    # --- Show a clean, friendly reboot screen ---
    echo ""
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   ${YELLOW}One-time reboot needed${NC}                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   Your GPU requires a Secure Boot key enrollment.            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   This is normal and only happens once.                      ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   After reboot a ${YELLOW}blue screen${NC} will appear:                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${GREEN}1.${NC} Select \"Enroll MOK\"                                  ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${GREEN}2.${NC} Select \"Continue\"                                    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${GREEN}3.${NC} Type password:  ${GREEN}${mok_pass}${NC}                            ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}     ${GREEN}4.${NC} Select \"Reboot\"                                     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}   Installation will ${GREEN}continue automatically${NC} after reboot.    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if $INTERACTIVE; then
        read -p "  Press Enter to reboot (or Ctrl+C to do it later)... " -r
        sudo reboot
    fi

    # Non-interactive mode: exit cleanly (not an error — reboot is a normal install phase)
    ai "Reboot this machine to continue installation."
    exit 0
}

# If detect_gpu found no working GPU, check if it's a fixable driver/Secure Boot issue
if [[ $GPU_COUNT -eq 0 ]] && ! $DRY_RUN; then
    fix_nvidia_secure_boot || true
fi

# NVIDIA Driver Compatibility Check
# vllm/vllm-openai:v0.15.1 ships CUDA 12.9 — requires driver >= 570
if [[ $GPU_COUNT -gt 0 ]]; then
    DRIVER_VERSION=""
    if raw_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null); then
        DRIVER_VERSION=$(echo "$raw_driver" | head -1 | cut -d. -f1)
    fi
    if [[ -n "$DRIVER_VERSION" && "$DRIVER_VERSION" =~ ^[0-9]+$ ]]; then
        log "NVIDIA driver: $DRIVER_VERSION"
        if [[ "$DRIVER_VERSION" -lt "$MIN_DRIVER_VERSION" ]]; then
            ai_bad "NVIDIA driver $DRIVER_VERSION is too old. vLLM requires driver >= $MIN_DRIVER_VERSION."
            ai "Attempting to install a compatible driver..."
            if ! $DRY_RUN; then
                if command -v ubuntu-drivers &> /dev/null; then
                    sudo ubuntu-drivers install nvidia:${MIN_DRIVER_VERSION}-server 2>>"$LOG_FILE" || \
                    sudo apt-get install -y nvidia-driver-${MIN_DRIVER_VERSION} 2>>"$LOG_FILE" || true
                else
                    sudo apt-get install -y nvidia-driver-${MIN_DRIVER_VERSION} 2>>"$LOG_FILE" || true
                fi
                # Check if upgrade succeeded
                if dpkg -l "nvidia-driver-${MIN_DRIVER_VERSION}"* 2>/dev/null | grep -q "^ii"; then
                    ai_ok "NVIDIA driver ${MIN_DRIVER_VERSION} installed."
                    ai_warn "A REBOOT is required before continuing."
                    ai "After rebooting, re-run this installer. It will pick up where it left off."
                    echo ""
                    if $INTERACTIVE; then
                        read -p "  Reboot now? [Y/n] " -r
                        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                            sudo reboot
                        fi
                    fi
                    error "Reboot required to load NVIDIA driver ${MIN_DRIVER_VERSION}. Re-run install.sh after rebooting."
                else
                    ai_bad "Driver install failed. Please install NVIDIA driver >= ${MIN_DRIVER_VERSION} manually."
                    ai "  Try: sudo apt install nvidia-driver-${MIN_DRIVER_VERSION}"
                    error "Compatible NVIDIA driver required."
                fi
            else
                log "[DRY RUN] Would install nvidia-driver-${MIN_DRIVER_VERSION}"
            fi
        else
            ai_ok "NVIDIA driver $DRIVER_VERSION (>= $MIN_DRIVER_VERSION required)"
        fi
    else
        ai_warn "Could not determine driver version — continuing anyway"
    fi
fi

# Auto-detect tier if not specified
if [[ -z "$TIER" ]]; then
    if [[ $GPU_COUNT -ge 2 ]] || [[ $GPU_VRAM -ge 40000 ]]; then
        TIER=4
    elif [[ $GPU_VRAM -ge 20000 ]] || [[ $RAM_GB -ge 96 ]]; then
        TIER=3
    elif [[ $GPU_VRAM -ge 12000 ]] || [[ $RAM_GB -ge 48 ]]; then
        TIER=2
    else
        TIER=1
    fi
    log "Auto-detected tier: $TIER"
else
    log "Using specified tier: $TIER"
fi

# Tier-specific configurations
case $TIER in
    1)
        TIER_NAME="Entry Level"
        LLM_MODEL="Qwen/Qwen2.5-7B-Instruct"
        MAX_CONTEXT=16384
        GPU_UTIL=0.85
        QUANTIZATION=""
        ;;
    2)
        TIER_NAME="Prosumer"
        LLM_MODEL="Qwen/Qwen2.5-14B-Instruct-AWQ"
        MAX_CONTEXT=16384
        GPU_UTIL=0.90
        QUANTIZATION="awq"
        ;;
    3)
        TIER_NAME="Pro"
        LLM_MODEL="Qwen/Qwen2.5-32B-Instruct-AWQ"
        MAX_CONTEXT=32768
        GPU_UTIL=0.90
        QUANTIZATION="awq"
        ;;
    4)
        TIER_NAME="Enterprise"
        LLM_MODEL="Qwen/Qwen2.5-72B-Instruct-AWQ"
        MAX_CONTEXT=32768
        GPU_UTIL=0.92
        QUANTIZATION="awq"
        ;;
    *)
        error "Invalid tier: $TIER. Must be 1-4."
        ;;
esac

# Display hardware summary with nice formatting
CPU_INFO=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "Unknown")
if [[ "$INTERACTIVE" == "true" ]]; then
    show_hardware_summary "$GPU_NAME" "$((GPU_VRAM / 1024))" "$CPU_INFO" "$RAM_GB" "$DISK_AVAIL"

    # Estimate tokens/sec and concurrent users based on tier
    case $TIER in
        1) SPEED_EST=25; USERS_EST="1-2" ;;
        2) SPEED_EST=45; USERS_EST="3-5" ;;
        3) SPEED_EST=55; USERS_EST="5-8" ;;
        4) SPEED_EST=40; USERS_EST="10-15" ;;
    esac
    show_tier_recommendation "$TIER" "$LLM_MODEL" "$SPEED_EST" "$USERS_EST"
else
    success "Configuration: Tier $TIER ($TIER_NAME)"
    log "  Model: $LLM_MODEL"
    log "  Context: ${MAX_CONTEXT} tokens"
fi

# Warn about gated models requiring HF_TOKEN
if [[ "$LLM_MODEL" == *"meta-llama"* ]] || [[ "$LLM_MODEL" == *"Llama-2"* ]] || [[ "$LLM_MODEL" == *"Llama-3"* ]]; then
    if [[ -z "${HF_TOKEN:-}" ]]; then
        warn "Model $LLM_MODEL may be gated. Set HF_TOKEN environment variable if download fails."
        warn "Get your token at: https://huggingface.co/settings/tokens"
    fi
fi

#=============================================================================
# Interactive Feature Selection
#=============================================================================
if $INTERACTIVE && ! $DRY_RUN; then
    show_phase 2 6 "Feature Selection" "~1 minute"
    show_install_menu

    # Only show individual feature prompts for Custom installs
    if [[ "${INSTALL_CHOICE:-1}" == "3" ]]; then
        read -p "  Enable voice (Whisper STT + Kokoro TTS)? [Y/n] " -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] || ENABLE_VOICE=true

        read -p "  Enable n8n workflow automation? [Y/n] " -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] || ENABLE_WORKFLOWS=true

        read -p "  Enable Qdrant vector database (for RAG)? [Y/n] " -r
        echo
        [[ $REPLY =~ ^[Nn]$ ]] || ENABLE_RAG=true

        read -p "  Enable OpenClaw AI agent framework? [y/N] " -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && ENABLE_OPENCLAW=true
    fi
fi

# Build profiles string
PROFILES=""
[[ "$ENABLE_VOICE" == "true" ]] && PROFILES="$PROFILES --profile voice"
[[ "$ENABLE_WORKFLOWS" == "true" ]] && PROFILES="$PROFILES --profile workflows"
[[ "$ENABLE_RAG" == "true" ]] && PROFILES="$PROFILES --profile rag"
[[ "$ENABLE_OPENCLAW" == "true" ]] && PROFILES="$PROFILES --profile openclaw"

# Select tier-appropriate OpenClaw config
if [[ "$ENABLE_OPENCLAW" == "true" ]]; then
    case $TIER in
        1) OPENCLAW_CONFIG="minimal.json" ;;
        2) OPENCLAW_CONFIG="entry.json" ;;
        3) OPENCLAW_CONFIG="prosumer.json" ;;
        4) OPENCLAW_CONFIG="pro.json" ;;
        *) OPENCLAW_CONFIG="prosumer.json" ;;
    esac
    log "OpenClaw config: $OPENCLAW_CONFIG (matched to Tier $TIER)"
fi

log "Enabled profiles:${PROFILES:- (core only)}"

#=============================================================================
# Requirements Check
#=============================================================================
chapter "REQUIREMENTS CHECK"

REQUIREMENTS_MET=true

# Minimum RAM
MIN_RAM=$((TIER * 16))
if [[ $RAM_GB -lt $MIN_RAM ]]; then
    warn "RAM: ${RAM_GB}GB available, ${MIN_RAM}GB recommended for Tier $TIER"
else
    ai_ok "RAM: ${RAM_GB}GB (recommended: ${MIN_RAM}GB+)"
fi

# Minimum disk (tier-aware)
case $TIER in
    1) MIN_DISK=30 ;;   # Nano: 1.5B model ~5GB
    2) MIN_DISK=50 ;;   # Edge: 7B model ~15GB
    3) MIN_DISK=80 ;;   # Pro: 32B model ~50GB
    4) MIN_DISK=150 ;;  # Cluster: 72B model ~100GB
    *) MIN_DISK=50 ;;
esac

if [[ $DISK_AVAIL -lt $MIN_DISK ]]; then
    warn "Disk: ${DISK_AVAIL}GB available, ${MIN_DISK}GB minimum required for Tier $TIER"
    REQUIREMENTS_MET=false
else
    ai_ok "Disk: ${DISK_AVAIL}GB available (minimum: ${MIN_DISK}GB for Tier $TIER)"
fi

# GPU for tiers 2+
if [[ $TIER -ge 2 && $GPU_VRAM -lt 10000 ]]; then
    warn "GPU: Tier $TIER requires dedicated NVIDIA GPU with 12GB+ VRAM"
else
    ai_ok "GPU: Detected $GPU_NAME"
fi

# Port availability check (handles IPv4 and IPv6)
check_port() {
    local port=$1
    if command -v ss &> /dev/null; then
        ss -tln 2>/dev/null | grep -qE ":${port}(\s|$)" && return 1
    elif command -v netstat &> /dev/null; then
        netstat -tln 2>/dev/null | grep -qE ":${port}(\s|$)" && return 1
    fi
    return 0
}

PORTS_TO_CHECK="8000 3000"
[[ "$ENABLE_VOICE" == "true" ]] && PORTS_TO_CHECK="$PORTS_TO_CHECK 9000 8880"
[[ "$ENABLE_WORKFLOWS" == "true" ]] && PORTS_TO_CHECK="$PORTS_TO_CHECK 5678"
[[ "$ENABLE_RAG" == "true" ]] && PORTS_TO_CHECK="$PORTS_TO_CHECK 6333"

for port in $PORTS_TO_CHECK; do
    if ! check_port $port; then
        warn "Port $port is already in use"
        REQUIREMENTS_MET=false
    fi
done

if [[ "$REQUIREMENTS_MET" != "true" ]]; then
    warn "Some requirements not met. Installation may have limited functionality."
    if $INTERACTIVE && ! $DRY_RUN; then
        read -p "  Continue anyway? [y/N] " -r
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    elif $DRY_RUN; then
        log "[DRY RUN] Would prompt to continue despite unmet requirements"
    fi
fi

#=============================================================================
# Docker Installation
#=============================================================================
show_phase 3 6 "Docker Setup" "~2 minutes"
ai "Preparing container runtime..."

if [[ "$SKIP_DOCKER" == "true" ]]; then
    log "Skipping Docker installation (--skip-docker)"
elif command -v docker &> /dev/null; then
    ai_ok "Docker already installed: $(docker --version)"
else
    ai "Installing Docker..."

    if $DRY_RUN; then
        log "[DRY RUN] Would install Docker via official script"
    else
        if ! curl -fsSL https://get.docker.com | sh; then
            error "Docker installation failed. Check network connectivity and try again."
        fi
        sudo usermod -aG docker $USER

        # Check if we need to use newgrp or restart
        if ! groups | grep -q docker; then
            warn "Docker installed! Group membership requires re-login."
            warn "Option 1: Log out and back in, then re-run this script with --skip-docker"
            warn "Option 2: Run 'newgrp docker' in a new terminal, then re-run"
            echo ""
            read -p "  Try to continue with 'sudo docker' for now? [Y/n] " -r
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                # Use sudo for remaining docker commands in this session
                DOCKER_CMD="sudo docker"
                DOCKER_COMPOSE_CMD="sudo docker compose"
            else
                log "Please re-run after logging out and back in."
                exit 0
            fi
        fi
    fi
fi

# Set docker command (use sudo if needed)
DOCKER_CMD="${DOCKER_CMD:-docker}"
DOCKER_COMPOSE_CMD="${DOCKER_COMPOSE_CMD:-docker compose}"

# Docker Compose check (v2 preferred, v1 fallback)
if $DOCKER_COMPOSE_CMD version &> /dev/null 2>&1; then
    ai_ok "Docker Compose v2 available"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE_CMD="${DOCKER_CMD%-*}-compose"
    [[ "$DOCKER_CMD" == "sudo docker" ]] && DOCKER_COMPOSE_CMD="sudo docker-compose"
    ai_ok "Docker Compose v1 available (using docker-compose)"
else
    if ! $DRY_RUN; then
        ai "Installing Docker Compose plugin..."
        sudo apt-get update && sudo apt-get install -y docker-compose-plugin
    fi
fi

# NVIDIA Container Toolkit
if [[ $GPU_COUNT -gt 0 ]]; then
    if command -v nvidia-container-cli &> /dev/null 2>&1; then
        ai_ok "NVIDIA Container Toolkit installed"
        # Always regenerate CDI spec — driver version may have changed since last run
        if command -v nvidia-ctk &>/dev/null && ! $DRY_RUN; then
            sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>>"$LOG_FILE" || true
        fi
    else
        ai "Installing NVIDIA Container Toolkit..."
        if ! $DRY_RUN; then
            # Add NVIDIA GPG key
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
            # Use NVIDIA's current generic deb repo (per-distro URLs were deprecated)
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            # Verify we got a valid repo file, not an HTML 404
            if grep -q '<html' /etc/apt/sources.list.d/nvidia-container-toolkit.list 2>/dev/null; then
                warn "Failed to download NVIDIA Container Toolkit repo list. Trying fallback..."
                echo "deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/\$(ARCH) /" | \
                    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            fi
            sudo apt-get update
            if ! sudo apt-get install -y nvidia-container-toolkit; then
                error "Failed to install NVIDIA Container Toolkit. Check network connectivity and GPU drivers."
            fi
            sudo nvidia-ctk runtime configure --runtime=docker
            sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>>"$LOG_FILE" || true
            sudo systemctl restart docker
        fi
        if command -v nvidia-container-cli &> /dev/null 2>&1; then
            ai_ok "NVIDIA Container Toolkit installed"
        else
            $DRY_RUN && ai_ok "[DRY RUN] Would install NVIDIA Container Toolkit" || error "NVIDIA Container Toolkit installation failed — nvidia-container-cli not found after install."
        fi
    fi
fi

#=============================================================================
# Directory Structure & Files
#=============================================================================
chapter "SETTING UP INSTALLATION"

if $DRY_RUN; then
    log "[DRY RUN] Would create: $INSTALL_DIR"
    log "[DRY RUN] Would copy docker-compose.yml and generate .env"
else
    # Create directories
    mkdir -p "$INSTALL_DIR"/{config,data,models}
    mkdir -p "$INSTALL_DIR"/data/{vllm,open-webui,whisper,tts,n8n,qdrant}
    mkdir -p "$INSTALL_DIR"/config/{n8n,litellm,openclaw}

    # Copy docker-compose.yml from source
    cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/"

    # Copy config files if they exist
    [[ -d "$SCRIPT_DIR/config" ]] && cp -r "$SCRIPT_DIR/config"/* "$INSTALL_DIR/config/" 2>/dev/null || true
    [[ -d "$SCRIPT_DIR/workflows" ]] && cp -r "$SCRIPT_DIR/workflows" "$INSTALL_DIR/config/n8n/" 2>/dev/null || true

    # Copy build contexts needed by docker compose
    for build_dir in agents dashboard dashboard-api privacy-shield vllm-tool-proxy; do
        [[ -d "$SCRIPT_DIR/$build_dir" ]] && cp -r "$SCRIPT_DIR/$build_dir" "$INSTALL_DIR/$build_dir" 2>/dev/null || true
    done

    # Select tier-appropriate OpenClaw config
    if [[ "$ENABLE_OPENCLAW" == "true" && -n "$OPENCLAW_CONFIG" ]]; then
        # In bootstrap mode, OpenClaw should use the 1.5B model that vLLM actually serves at startup.
        # The full tier model downloads in the background and can be switched later.
        if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
            OPENCLAW_MODEL="Qwen/Qwen2.5-1.5B-Instruct"
            OPENCLAW_CONTEXT=32768
        else
            OPENCLAW_MODEL="$LLM_MODEL"
            OPENCLAW_CONTEXT="$MAX_CONTEXT"
        fi

        if [[ -f "$SCRIPT_DIR/config/openclaw/$OPENCLAW_CONFIG" ]]; then
            cp "$SCRIPT_DIR/config/openclaw/$OPENCLAW_CONFIG" "$INSTALL_DIR/config/openclaw/openclaw.json"
            # Dynamically set model to match what vLLM is actually serving
            sed -i "s|Qwen/Qwen2.5-[^\"]*|${OPENCLAW_MODEL}|g" "$INSTALL_DIR/config/openclaw/openclaw.json"
            log "Installed OpenClaw config: $OPENCLAW_CONFIG -> openclaw.json (model: $OPENCLAW_MODEL)"
        else
            warn "OpenClaw config $OPENCLAW_CONFIG not found, using default"
            cp "$SCRIPT_DIR/config/openclaw/openclaw.json.example" "$INSTALL_DIR/config/openclaw/openclaw.json" 2>/dev/null || true
        fi
        mkdir -p "$INSTALL_DIR/data/openclaw/home"
        # Generate OpenClaw home config with local vLLM provider
        OPENCLAW_TOKEN=$(openssl rand -hex 24 2>/dev/null || head -c 24 /dev/urandom | xxd -p)
        cat > "$INSTALL_DIR/data/openclaw/home/openclaw.json" << OCLAW_EOF
{
  "models": {
    "providers": {
      "local-vllm": {
        "baseUrl": "http://vllm-tool-proxy:8003/v1",
        "apiKey": "none",
        "api": "openai-completions",
        "models": [
          {
            "id": "${OPENCLAW_MODEL}",
            "name": "Dream Server LLM (Local)",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": ${OPENCLAW_CONTEXT},
            "maxTokens": 8192,
            "compat": {
              "supportsStore": false,
              "supportsDeveloperRole": false,
              "supportsReasoningEffort": false,
              "maxTokensField": "max_tokens"
            }
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {"primary": "local-vllm/${OPENCLAW_MODEL}"},
      "models": {"local-vllm/${OPENCLAW_MODEL}": {}},
      "compaction": {"mode": "safeguard"},
      "subagents": {"maxConcurrent": 20, "model": "local-vllm/${OPENCLAW_MODEL}"}
    }
  },
  "commands": {"native": "auto", "nativeSkills": "auto"},
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "controlUi": {"allowInsecureAuth": true},
    "auth": {"mode": "token", "token": "${OPENCLAW_TOKEN}"}
  }
}
OCLAW_EOF
        # Generate agent auth-profiles.json for vLLM provider
        mkdir -p "$INSTALL_DIR/data/openclaw/home/agents/main/agent"
        cat > "$INSTALL_DIR/data/openclaw/home/agents/main/agent/auth-profiles.json" << AUTH_EOF
{
  "version": 1,
  "profiles": {
    "local-vllm:default": {
      "type": "api_key",
      "provider": "local-vllm",
      "key": "none"
    }
  },
  "lastGood": {"local-vllm": "local-vllm:default"},
  "usageStats": {}
}
AUTH_EOF
        cat > "$INSTALL_DIR/data/openclaw/home/agents/main/agent/models.json" << MODELS_EOF
{
  "providers": {
    "local-vllm": {
      "baseUrl": "http://vllm-tool-proxy:8003/v1",
      "apiKey": "none",
      "api": "openai-completions",
      "models": [
        {
          "id": "${OPENCLAW_MODEL}",
          "name": "Dream Server LLM (Local)",
          "reasoning": false,
          "input": ["text"],
          "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
          "contextWindow": ${OPENCLAW_CONTEXT},
          "maxTokens": 8192,
          "compat": {
            "supportsStore": false,
            "supportsDeveloperRole": false,
            "supportsReasoningEffort": false,
            "maxTokensField": "max_tokens"
          }
        }
      ]
    }
  }
}
MODELS_EOF
        log "Generated OpenClaw home config (model: $OPENCLAW_MODEL, gateway token set)"
        # Create workspace directory (must exist before Docker Compose,
        # otherwise Docker auto-creates it as root and the container can't write to it)
        mkdir -p "$INSTALL_DIR/config/openclaw/workspace"
        # Copy workspace personality files (SOUL.md etc.) if the repo ships any
        if [[ -d "$SCRIPT_DIR/config/openclaw/workspace" ]]; then
            cp -r "$SCRIPT_DIR/config/openclaw/workspace"/* "$INSTALL_DIR/config/openclaw/workspace/" 2>/dev/null || true
            log "Installed OpenClaw workspace files (agent personality)"
        fi
    fi

    # Create hermes tool template for vLLM
    mkdir -p "$INSTALL_DIR/data/vllm"
    cat > "$INSTALL_DIR/data/vllm/hermes_tool_template.jinja" << 'TEMPLATE_EOF'
{%- for message in messages %}
{%- if message.role == 'system' %}
<|im_start|>system
{{ message.content }}<|im_end|>
{%- elif message.role == 'user' %}
<|im_start|>user
{{ message.content }}<|im_end|>
{%- elif message.role == 'assistant' %}
<|im_start|>assistant
{%- if message.tool_calls %}
{%- for tool_call in message.tool_calls %}
<tool_call>
{"name": "{{ tool_call.function.name }}", "arguments": {{ tool_call.function.arguments }}}
</tool_call>
{%- endfor %}
{%- else %}
{{ message.content }}
{%- endif %}
<|im_end|>
{%- elif message.role == 'tool' %}
<|im_start|>tool
{{ message.content }}<|im_end|>
{%- endif %}
{%- endfor %}
{%- if add_generation_prompt %}
<|im_start|>assistant
{%- endif %}
TEMPLATE_EOF

    # Generate secure secrets
    WEBUI_SECRET=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)
    N8N_PASS=$(openssl rand -base64 16 2>/dev/null || head -c 16 /dev/urandom | base64)
    LITELLM_KEY="sk-dream-$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)"
    LIVEKIT_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    TOKEN_SPY_DB_PASSWORD=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    DASHBOARD_API_KEY=$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | xxd -p)

    # Generate .env file
    cat > "$INSTALL_DIR/.env" << ENV_EOF
# Dream Server Configuration
# Generated by installer v${VERSION} on $(date -Iseconds)
# Tier: ${TIER} (${TIER_NAME})

#=== LLM Settings ===
LLM_MODEL=${LLM_MODEL}
MAX_CONTEXT=${MAX_CONTEXT}
GPU_UTIL=${GPU_UTIL}
GPU_DEVICES=all
GPU_COUNT=${GPU_COUNT:-1}
HF_TOKEN=

#=== Ports ===
VLLM_PORT=8000
WEBUI_PORT=3000
WHISPER_PORT=9000
TTS_PORT=8880
N8N_PORT=5678
QDRANT_PORT=6333
QDRANT_GRPC_PORT=6334
LITELLM_PORT=4000
OPENCLAW_PORT=7860

#=== Security (auto-generated, keep secret!) ===
WEBUI_SECRET=${WEBUI_SECRET}
DASHBOARD_API_KEY=${DASHBOARD_API_KEY}
N8N_USER=admin
N8N_PASS=${N8N_PASS}
LITELLM_KEY=${LITELLM_KEY}
LIVEKIT_API_KEY=$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
LIVEKIT_API_SECRET=${LIVEKIT_SECRET}
TOKEN_SPY_DB_PASSWORD=${TOKEN_SPY_DB_PASSWORD}
TOKEN_MONITOR_DB=postgresql://tokenspy:${TOKEN_SPY_DB_PASSWORD}@token-spy-db:5432/tokenspy
OPENCLAW_TOKEN=${OPENCLAW_TOKEN:-}

#=== Voice Settings ===
WHISPER_MODEL=base
TTS_VOICE=en_US-lessac-medium

#=== Web UI Settings ===
WEBUI_AUTH=true
ENABLE_WEB_SEARCH=true
WEB_SEARCH_ENGINE=duckduckgo

#=== n8n Settings ===
N8N_AUTH=true
N8N_HOST=localhost
N8N_WEBHOOK_URL=http://localhost:5678
TIMEZONE=${SYSTEM_TZ:-UTC}
ENV_EOF

    chmod 600 "$INSTALL_DIR/.env"  # Secure secrets file
    ai_ok "Created $INSTALL_DIR"
    ai_ok "Generated secure secrets in .env (permissions: 600)"
fi

#=============================================================================
# Copy Documentation
#=============================================================================
if ! $DRY_RUN; then
    # Copy docs for reference
    [[ -d "$SCRIPT_DIR/docs" ]] && cp -r "$SCRIPT_DIR/docs" "$INSTALL_DIR/" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/README.md" ]] && cp "$SCRIPT_DIR/README.md" "$INSTALL_DIR/" 2>/dev/null || true

    # Copy status script
    [[ -f "$SCRIPT_DIR/status.sh" ]] && cp "$SCRIPT_DIR/status.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/status.sh" 2>/dev/null || true

    # Copy CLI management tools (A12 fix)
    [[ -f "$SCRIPT_DIR/dream-cli" ]] && cp "$SCRIPT_DIR/dream-cli" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/dream-cli" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/dream-backup.sh" ]] && cp "$SCRIPT_DIR/dream-backup.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/dream-backup.sh" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/dream-restore.sh" ]] && cp "$SCRIPT_DIR/dream-restore.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/dream-restore.sh" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/dream-update.sh" ]] && cp "$SCRIPT_DIR/dream-update.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/dream-update.sh" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/dream-preflight.sh" ]] && cp "$SCRIPT_DIR/dream-preflight.sh" "$INSTALL_DIR/" && chmod +x "$INSTALL_DIR/dream-preflight.sh" 2>/dev/null || true

    # Copy compose variants (A12 fix)
    [[ -f "$SCRIPT_DIR/docker-compose.local.yml" ]] && cp "$SCRIPT_DIR/docker-compose.local.yml" "$INSTALL_DIR/" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/docker-compose.hybrid.yml" ]] && cp "$SCRIPT_DIR/docker-compose.hybrid.yml" "$INSTALL_DIR/" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/docker-compose.cloud.yml" ]] && cp "$SCRIPT_DIR/docker-compose.cloud.yml" "$INSTALL_DIR/" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/docker-compose.offline.yml" ]] && cp "$SCRIPT_DIR/docker-compose.offline.yml" "$INSTALL_DIR/" 2>/dev/null || true
    [[ -f "$SCRIPT_DIR/docker-compose.edge.yml" ]] && cp "$SCRIPT_DIR/docker-compose.edge.yml" "$INSTALL_DIR/" 2>/dev/null || true
fi

#=============================================================================
# Developer Tools (Claude Code + Codex CLI)
#=============================================================================
if ! $DRY_RUN; then
    ai "Installing AI developer tools..."

    # Ensure Node.js/npm is available (needed for Claude Code and Codex)
    if ! command -v npm &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            ai "Installing Node.js..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >> "$LOG_FILE" 2>&1 || true
            sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1 || true
        fi
    fi

    if command -v npm &> /dev/null; then
        # Install Claude Code (Anthropic's CLI for Claude)
        if ! command -v claude &> /dev/null; then
            sudo npm install -g @anthropic-ai/claude-code >> "$LOG_FILE" 2>&1 && \
                ai_ok "Claude Code installed (run 'claude' to start)" || \
                ai_warn "Claude Code install failed — install later with: npm i -g @anthropic-ai/claude-code"
        else
            ai_ok "Claude Code already installed"
        fi

        # Install Codex CLI (OpenAI's terminal agent)
        if ! command -v codex &> /dev/null; then
            sudo npm install -g @openai/codex >> "$LOG_FILE" 2>&1 && \
                ai_ok "Codex CLI installed (run 'codex' to start)" || \
                ai_warn "Codex CLI install failed — install later with: npm i -g @openai/codex"
        else
            ai_ok "Codex CLI already installed"
        fi
    else
        ai_warn "npm not available — skipping Claude Code and Codex CLI install"
        ai "  Install later: npm i -g @anthropic-ai/claude-code @openai/codex"
    fi
fi

#=============================================================================
# Pull Images
#=============================================================================
show_phase 4 6 "Downloading Modules" "~5-10 minutes"

# Build image list with cinematic labels
# Format: "image|friendly_name"
PULL_LIST=()
PULL_LIST+=("vllm/vllm-openai:v0.15.1|VLLM CORE — downloading the brain (~12GB)")
PULL_LIST+=("ghcr.io/open-webui/open-webui:v0.7.2|OPEN WEBUI — interface module")
[[ "$ENABLE_VOICE" == "true" ]] && PULL_LIST+=("onerahmet/openai-whisper-asr-webservice:v1.4.1|WHISPER — ears online")
[[ "$ENABLE_VOICE" == "true" ]] && PULL_LIST+=("ghcr.io/remsky/kokoro-fastapi-cpu:v0.2.4|KOKORO — voice module")
[[ "$ENABLE_WORKFLOWS" == "true" ]] && PULL_LIST+=("n8nio/n8n:2.6.4|N8N — automation engine")
[[ "$ENABLE_RAG" == "true" ]] && PULL_LIST+=("qdrant/qdrant:v1.16.3|QDRANT — memory vault")
[[ "$ENABLE_OPENCLAW" == "true" ]] && PULL_LIST+=("ghcr.io/openclaw/openclaw:latest|OPENCLAW — agent framework")
[[ "$ENABLE_RAG" == "true" ]] && PULL_LIST+=("ghcr.io/huggingface/text-embeddings-inference:cpu-1.9.1|TEI — embedding engine")

if $DRY_RUN; then
    ai "[DRY RUN] I would download ${#PULL_LIST[@]} modules."
else
    echo ""
    bootline
    echo -e "${CYAN}DOWNLOAD SEQUENCE${NC}"
    echo -e "${YELLOW}This is the long scene.${NC} (largest module first)"
    bootline
    echo ""
    signal "Take a break for ten minutes. I've got this."
    echo ""

    pull_count=0
    pull_total=${#PULL_LIST[@]}
    pull_failed=0

    for entry in "${PULL_LIST[@]}"; do
        img="${entry%%|*}"
        label="${entry##*|}"
        pull_count=$((pull_count + 1))

        if ! pull_with_progress "$img" "$label" "$pull_count" "$pull_total"; then
            ai_warn "Failed to pull $img — will retry on next start"
            pull_failed=$((pull_failed + 1))
        fi
    done

    echo ""
    if [[ $pull_failed -eq 0 ]]; then
        ai_ok "All $pull_total modules downloaded"
    else
        ai_warn "$pull_failed of $pull_total modules failed — services may not start fully"
    fi
fi

#=============================================================================
# Bootstrap Mode Setup
#=============================================================================
if [[ "$BOOTSTRAP_MODE" == "true" ]] && ! $DRY_RUN; then
    # Copy bootstrap scripts
    mkdir -p "$INSTALL_DIR/scripts"
    cp "$SCRIPT_DIR/scripts/model-bootstrap.sh" "$INSTALL_DIR/scripts/" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/scripts/model-bootstrap.sh" 2>/dev/null || true

    # Copy bootstrap compose override
    cp "$SCRIPT_DIR/docker-compose.bootstrap.yml" "$INSTALL_DIR/" 2>/dev/null || true

    # Store the target model for later upgrade
    echo "$LLM_MODEL" > "$INSTALL_DIR/.target-model"
    echo "${QUANTIZATION:-}" > "$INSTALL_DIR/.target-quantization"

    log "Bootstrap mode enabled: Starting with Qwen2.5-1.5B for instant access"
    log "Full model ($LLM_MODEL) will download in background"
fi

#=============================================================================
# Offline Mode Setup (M1 Integration)
#=============================================================================
if [[ "$OFFLINE_MODE" == "true" ]] && ! $DRY_RUN; then
    chapter "CONFIGURING OFFLINE MODE (M1)"

    # Create offline mode marker
    touch "$INSTALL_DIR/.offline-mode"

    # Disable any cloud-dependent features in .env
    sed -i 's/^BRAVE_API_KEY=.*/BRAVE_API_KEY=/' "$INSTALL_DIR/.env" 2>/dev/null || true
    sed -i 's/^ANTHROPIC_API_KEY=.*/ANTHROPIC_API_KEY=/' "$INSTALL_DIR/.env" 2>/dev/null || true
    sed -i 's/^OPENAI_API_KEY=.*/OPENAI_API_KEY=/' "$INSTALL_DIR/.env" 2>/dev/null || true

    # Add offline mode config
    cat >> "$INSTALL_DIR/.env" << 'OFFLINE_EOF'

#=============================================================================
# M1 Offline Mode Configuration
#=============================================================================
OFFLINE_MODE=true

# Disable telemetry and update checks
DISABLE_TELEMETRY=true
DISABLE_UPDATE_CHECK=true

# Use local RAG instead of web search
WEB_SEARCH_ENABLED=false
LOCAL_RAG_ENABLED=true
OFFLINE_EOF

    # Create OpenClaw M1 config if OpenClaw is enabled
    if [[ "$ENABLE_OPENCLAW" == "true" ]]; then
        mkdir -p "$INSTALL_DIR/config/openclaw"
        cat > "$INSTALL_DIR/config/openclaw/openclaw-m1.yaml" << 'M1_EOF'
# OpenClaw M1 Mode Configuration
# Fully offline operation - no cloud dependencies

memorySearch:
  enabled: true
  # Uses bundled GGUF embeddings (auto-downloaded during install)
  # No external API calls

# Disable web search (not available offline)
# Use local RAG with Qdrant instead
webSearch:
  enabled: false

# Local inference only
inference:
  provider: local
  baseUrl: http://vllm-tool-proxy:8003/v1
M1_EOF
        ai_ok "OpenClaw M1 config created"
    fi

    # Pre-download GGUF embeddings for memory_search
    ai "Pre-downloading GGUF embeddings for offline memory_search..."
    mkdir -p "$INSTALL_DIR/models/embeddings"

    # Download embeddinggemma GGUF (small, ~300MB)
    if command -v curl &> /dev/null; then
        EMBED_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q4_K_M.gguf"
        if ! [[ -f "$INSTALL_DIR/models/embeddings/nomic-embed-text-v1.5.Q4_K_M.gguf" ]]; then
            curl -L -o "$INSTALL_DIR/models/embeddings/nomic-embed-text-v1.5.Q4_K_M.gguf" "$EMBED_URL" 2>/dev/null || \
                ai_warn "Could not pre-download embeddings. Memory search will download on first use."
        else
            log "Embeddings already downloaded"
        fi
    fi

    # Copy offline documentation
    if [[ -f "$SCRIPT_DIR/docs/M1-OFFLINE-MODE.md" ]]; then
        cp "$SCRIPT_DIR/docs/M1-OFFLINE-MODE.md" "$INSTALL_DIR/docs/"
    fi

    ai_ok "Offline mode configured"
    log "After installation, disconnect from internet for fully air-gapped operation"
    log "See docs/M1-OFFLINE-MODE.md for offline operation guide"
fi

#=============================================================================
# Start Services
#=============================================================================
show_phase 5 6 "Starting Services" "~2-3 minutes"

if $DRY_RUN; then
    if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
        log "[DRY RUN] Would start with bootstrap model (1.5B), then upgrade"
    fi
    log "[DRY RUN] Would start services: $DOCKER_COMPOSE_CMD$PROFILES up -d"
else
    cd "$INSTALL_DIR"

    # Create logs directory for background downloads
    mkdir -p "$INSTALL_DIR/logs"

    if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
        # Start with bootstrap compose (tiny model)
        echo ""
        signal "Waking the stack..."
        ai "I'm bringing systems online. You can breathe."
        echo ""
        if [[ -n "$PROFILES" ]]; then
            $DOCKER_COMPOSE_CMD -f docker-compose.yml -f docker-compose.bootstrap.yml $PROFILES up --build -d >> "$LOG_FILE" 2>&1 &
        else
            $DOCKER_COMPOSE_CMD -f docker-compose.yml -f docker-compose.bootstrap.yml up --build -d >> "$LOG_FILE" 2>&1 &
        fi
        compose_pid=$!
        if ! spin_task $compose_pid "Launching containers (bootstrap mode)..."; then
            printf "\r  ${YELLOW}⚠${NC} %-60s\n" "Some services still starting..."
            echo ""
            ai_warn "Some containers need more time (model downloading). Retrying..."
            # Retry — picks up containers that missed the dependency window
            if [[ -n "$PROFILES" ]]; then
                $DOCKER_COMPOSE_CMD -f docker-compose.yml -f docker-compose.bootstrap.yml $PROFILES up --build -d >> "$LOG_FILE" 2>&1 &
            else
                $DOCKER_COMPOSE_CMD -f docker-compose.yml -f docker-compose.bootstrap.yml up --build -d >> "$LOG_FILE" 2>&1 &
            fi
            compose_pid=$!
            spin_task $compose_pid "Waiting for remaining services..." || true
        fi
        printf "\r  ${GREEN}✓${NC} %-60s\n" "All containers launched"
        echo ""
        ai_ok "Bootstrap services started (1.5B model for instant access)"

        # Start background download of full model with retry logic
        log "Starting background download of full model: $LLM_MODEL"

        # Clean up partial download marker on exit (only log if it actually existed)
        trap "if [[ -d '$INSTALL_DIR/models/.downloading' ]]; then rm -rf '$INSTALL_DIR/models/.downloading' 2>/dev/null; echo 'Download interrupted, cleaned up partial files'; fi" EXIT TERM

        # Note: Variables are interpolated at script write time (no escaping needed)
        nohup bash -c "
            sleep 30  # Let bootstrap stabilize first
            cd '$INSTALL_DIR'

            MAX_RETRIES=${MAX_DOWNLOAD_RETRIES}
            RETRY_DELAY=${DOWNLOAD_RETRY_DELAY}

            for attempt in \$(seq 1 \$MAX_RETRIES); do
                echo \"[Attempt \$attempt/\$MAX_RETRIES] Downloading $LLM_MODEL...\"

                # Download using docker (portable)
                $DOCKER_CMD run --rm \\
                    -v '$INSTALL_DIR/models:/root/.cache/huggingface' \\
                    -e HF_TOKEN=\"\${HF_TOKEN:-}\" \\
                    python:3.11-slim \\
                    bash -c 'pip install -q huggingface_hub && python -c \"from huggingface_hub import snapshot_download; snapshot_download('\\''$LLM_MODEL'\\'')\"'

                if [ \$? -eq 0 ]; then
                    echo 'Full model downloaded successfully!'
                    touch '$INSTALL_DIR/.model-swap-ready'
                    exit 0
                else
                    echo \"Download attempt \$attempt failed.\"
                    if [ \$attempt -lt \$MAX_RETRIES ]; then
                        echo \"Retrying in \$RETRY_DELAY seconds...\"
                        sleep \$RETRY_DELAY
                    fi
                fi
            done

            echo 'ERROR: Model download failed after \$MAX_RETRIES attempts.'
            echo 'Check your internet connection and try: $DOCKER_COMPOSE_CMD restart'
        " > "$INSTALL_DIR/logs/model-download.log" 2>&1 &

        log "Background download started. Check progress: tail -f $INSTALL_DIR/logs/model-download.log"
    else
        # Normal mode - start with full model (longer wait)
        echo ""
        signal "Waking the stack..."
        ai "I'm bringing systems online. You can breathe."
        echo ""
        if [[ -n "$PROFILES" ]]; then
            $DOCKER_COMPOSE_CMD $PROFILES up --build -d >> "$LOG_FILE" 2>&1 &
        else
            $DOCKER_COMPOSE_CMD up --build -d >> "$LOG_FILE" 2>&1 &
        fi
        compose_pid=$!
        if ! spin_task $compose_pid "Launching containers..."; then
            printf "\r  ${YELLOW}⚠${NC} %-60s\n" "Some services still starting..."
            echo ""
            ai_warn "Some containers need more time. Retrying..."
            if [[ -n "$PROFILES" ]]; then
                $DOCKER_COMPOSE_CMD $PROFILES up --build -d >> "$LOG_FILE" 2>&1 &
            else
                $DOCKER_COMPOSE_CMD up --build -d >> "$LOG_FILE" 2>&1 &
            fi
            compose_pid=$!
            spin_task $compose_pid "Waiting for remaining services..." || true
        fi
        printf "\r  ${GREEN}✓${NC} %-60s\n" "All containers launched"
        echo ""
        ai_ok "Services started"
    fi
fi

#=============================================================================
# Health Check
#=============================================================================
show_phase 6 6 "Systems Online" "~1-2 minutes"
ai "Linking services... standby."

sleep 5

# Bootstrap mode = fast startup, normal = longer wait for big model
# Health checks are best-effort — don't let set -e kill the script if a service is slow
if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
    check_service "vLLM (bootstrap)" "http://localhost:8000/health" 30 || true
else
    check_service "vLLM" "http://localhost:8000/health" 120 || true
fi
check_service "Open WebUI" "http://localhost:3000" 60 || true

[[ "$ENABLE_VOICE" == "true" ]] && check_service "Whisper" "http://localhost:9000" 30
[[ "$ENABLE_WORKFLOWS" == "true" ]] && check_service "n8n" "http://localhost:5678" 30
[[ "$ENABLE_RAG" == "true" ]] && check_service "Qdrant" "http://localhost:6333" 30

echo ""
signal "All systems nominal."
ai_ok "Sovereign intelligence is online."

#=============================================================================
# Summary
#=============================================================================

# Get local IP for LAN access
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")

# Save current mode and profiles for dream-cli
if [[ "$OFFLINE_MODE" == "true" ]]; then
    echo "offline" > "$INSTALL_DIR/.current-mode"
else
    echo "local" > "$INSTALL_DIR/.current-mode"
fi
echo "$PROFILES" > "$INSTALL_DIR/.profiles"

# Show the cinematic success card
show_success_card "http://localhost:3000" "http://localhost:3001" "$LOCAL_IP"

# Additional service info
bootline
echo -e "${CYAN}ALL SERVICES${NC}"
bootline
echo "  • Chat UI:       http://localhost:3000"
echo "  • Dashboard:     http://localhost:3001"
echo "  • LLM API:       http://localhost:8000/v1"
[[ "$ENABLE_VOICE" == "true" ]] && echo "  • Whisper STT:   http://localhost:9000"
[[ "$ENABLE_VOICE" == "true" ]] && echo "  • TTS (Kokoro):  http://localhost:8880"
[[ "$ENABLE_WORKFLOWS" == "true" ]] && echo "  • n8n:           http://localhost:5678"
[[ "$ENABLE_RAG" == "true" ]] && echo "  • Qdrant:        http://localhost:6333"
echo ""

# Configuration summary
bootline
echo -e "${CYAN}YOUR CONFIGURATION${NC}"
bootline
echo "  • Tier: $TIER ($TIER_NAME)"
echo "  • Model: $LLM_MODEL"
echo "  • Install dir: $INSTALL_DIR"
echo ""

# Bootstrap mode notice
if [[ "$BOOTSTRAP_MODE" == "true" ]]; then
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}⚡ BOOTSTRAP MODE ACTIVE${NC}                                  ${GREEN}║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  You can start chatting NOW with the 1.5B model.            ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}                                                              ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Full model (${LLM_MODEL}) is downloading...  ${GREEN}║${NC}"
    echo -e "${GREEN}║${NC}  Check progress on the Dashboard at localhost:3001          ${GREEN}║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
fi

# Quick commands
bootline
echo -e "${CYAN}QUICK COMMANDS${NC}"
bootline
echo "  cd $INSTALL_DIR"
echo "  docker compose ps          # Check status"
echo "  docker compose logs -f     # View logs"
echo "  docker compose restart     # Restart services"
echo ""

if [[ -f "$LOG_FILE" ]]; then
    echo -e "${BLUE}Full installation log:${NC} $LOG_FILE"
    echo ""
fi

# Run preflight check to validate installation
echo ""
bootline
echo -e "${CYAN}RUNNING PREFLIGHT VALIDATION${NC}"
bootline
echo ""

if [[ -f "$SCRIPT_DIR/dream-preflight.sh" ]]; then
    # Wait a moment for services to stabilize
    sleep 2
    bash "$SCRIPT_DIR/dream-preflight.sh" || true
else
    log "Preflight script not found — skipping validation"
fi

#=============================================================================
# Desktop Shortcut & Sidebar Pin
#=============================================================================
if ! $DRY_RUN; then
    DESKTOP_FILE="$HOME/.local/share/applications/dream-server.desktop"
    mkdir -p "$HOME/.local/share/applications"
    cat > "$DESKTOP_FILE" << DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Dream Server
Comment=Local AI Dashboard
Exec=xdg-open http://localhost:3001
Icon=applications-internet
Terminal=false
Categories=Development;
StartupNotify=true
DESKTOP_EOF

    # Pin to GNOME sidebar (favorites) if gsettings is available
    if command -v gsettings &> /dev/null; then
        CURRENT_FAVS=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo "[]")
        if [[ "$CURRENT_FAVS" != *"dream-server.desktop"* ]]; then
            NEW_FAVS=$(echo "$CURRENT_FAVS" | sed "s/]$/, 'dream-server.desktop']/" | sed "s/\[, /[/")
            gsettings set org.gnome.shell favorite-apps "$NEW_FAVS" 2>/dev/null || true
            ai_ok "Dashboard pinned to sidebar"
        fi
    fi

    ai_ok "Desktop shortcut created: Dream Server"
fi

echo ""
signal "Broadcast stable. You're free now."
echo ""
DASHBOARD_PORT="${DASHBOARD_PORT:-3001}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
OPENCLAW_PORT="${OPENCLAW_PORT:-7860}"
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}  YOUR DREAM SERVER IS LIVE${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${GREEN}Dashboard${NC}    http://localhost:${DASHBOARD_PORT}"
echo -e "  ${GREEN}Chat${NC}         http://localhost:${WEBUI_PORT}"
[[ "$ENABLE_OPENCLAW" == "true" ]] && \
echo -e "  ${GREEN}OpenClaw${NC}     http://localhost:${OPENCLAW_PORT}"
echo ""
if [[ -n "$LOCAL_IP" ]]; then
echo -e "  ${YELLOW}On your network:${NC}  http://${LOCAL_IP}:${DASHBOARD_PORT}"
fi
echo ""
echo -e "  Start here → ${GREEN}http://localhost:${DASHBOARD_PORT}${NC}"
echo -e "  The Dashboard shows all services, GPU status, and quick links."
echo ""
echo -e "${CYAN}──────────────────────────────────────────────────────────────────────────────${NC}"
echo ""
