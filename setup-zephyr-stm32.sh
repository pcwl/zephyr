#!/usr/bin/env bash
set -euo pipefail

# Zephyr STM32 environment setup script
# Usage: ./setup-zephyr-stm32.sh [--clone-repo]
# Run from the root of a local Zephyr repository, or use --clone-repo to clone it first.

show_help() {
  cat << EOF
Usage: $(basename "$0") [OPTIONS]

Setup Zephyr development environment for STM32.

OPTIONS:
  --clone-repo        Clone Zephyr repository if not found
  -h, --help          Show this help message

EXAMPLES:
  $(basename "$0") --clone-repo

EOF
}

# Parse arguments
CLONE_REPO=false
ZEHPHYR_REPO_DIR="."

while [[ $# -gt 0 ]]; do
  case $1 in
    --clone-repo)
      CLONE_REPO=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
  esac
done

TOOLCHAIN_DIR="$HOME/arm-gcc"
TOOLCHAIN_ARCHIVE="gcc-arm-none-eabi-10.3-2021.10-x86_64-linux.tar.bz2"
TOOLCHAIN_URL="https://developer.arm.com/-/media/Files/downloads/gnu-rm/10.3-2021.10/$TOOLCHAIN_ARCHIVE"
TOOLCHAIN_PATH="$TOOLCHAIN_DIR/gcc-arm-none-eabi-10.3-2021.10"
BASHRC="$HOME/.bashrc"
ZEPHYR_BOARD="nucleo_f446ze"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if repo exists, optionally clone if requested
check_repo() {
  if [[ ! -f "$ZEHPHYR_REPO_DIR/CMakeLists.txt" ]]; then
    if [[ "$CLONE_REPO" == true ]]; then
      log_info "Cloning Zephyr repository..."
      ZEHPHYR_REPO_DIR="$HOME/zephyr"
      if [[ -d "$ZEHPHYR_REPO_DIR" ]]; then
        log_warn "$ZEHPHYR_REPO_DIR already exists. Skipping clone."
      else
        git clone https://github.com/zephyrproject-rtos/zephyr.git "$ZEHPHYR_REPO_DIR"
      fi
    else
      log_error "Not in a Zephyr repository directory."
      echo "Usage: $0 [--clone-repo]"
      echo "  - Run from Zephyr root directory, or"
      echo "  - Use '$0 --clone-repo' to clone from GitHub and set up."
      exit 1
    fi
  fi
}

# Install system packages
install_packages() {
  log_info "Installing system packages..."

  # Check Python version (find any version >= 3.12)
  AVAILABLE_PYTHON=""
  for py in python3.15 python3.14 python3.13 python3.12; do
    if command -v "$py" >/dev/null 2>&1; then
      AVAILABLE_PYTHON="$py"
      break
    fi
  done
  CURRENT_PYTHON_VERSION=$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "0")

  if [[ -z "$AVAILABLE_PYTHON" && "$CURRENT_PYTHON_VERSION" -lt 12 ]]; then
    log_warn "Python 3.12+ required for Zephyr, current is 3.$CURRENT_PYTHON_VERSION"
    if command -v apt >/dev/null 2>&1; then
      log_info "Installing Python 3.12..."
      sudo apt install -y software-properties-common
      sudo add-apt-repository -y ppa:deadsnakes/ppa
      sudo apt update
      sudo apt install -y python3.12 python3.12-venv python3.12-dev python3.12-distutils python3.12-ensurepip
    fi
  elif [[ -n "$AVAILABLE_PYTHON" && "$CURRENT_PYTHON_VERSION" -lt 12 ]]; then
    log_info "Found $AVAILABLE_PYTHON, will use it for building"
  fi

  local packages="cmake ninja-build gperf ccache dfu-util device-tree-compiler python3-dev python3-pip python3-venv"

  if command -v apt >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y $packages
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y $packages
  elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y $packages
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y $packages
  else
    log_warn "No supported package manager found (apt/dnf/yum/zypper)."
    log_warn "Please install manually: $packages"
    return 1
  fi
}

# Install Python dependencies
install_python_deps() {
  log_info "Installing Python dependencies..."
  export PATH="$HOME/.local/bin:$PATH"

  # Find python3 >= 3.12 for pip
  PIP_PYTHON="/usr/bin/python3"
  for py in /usr/bin/python3.15 /usr/bin/python3.14 /usr/bin/python3.13 /usr/bin/python3.12; do
    if [[ -x "$py" ]]; then
      PIP_PYTHON="$py"
      break
    fi
  done

  log_info "Installing Python packages with $PIP_PYTHON..."
  "$PIP_PYTHON" -m ensurepip --upgrade 2>/dev/null || true
  "$PIP_PYTHON" -m pip install --user --upgrade pip setuptools wheel
  "$PIP_PYTHON" -m pip install --user west pyelftools
}

# Download and extract toolchain
install_toolchain() {
  log_info "Downloading ARM toolchain..."
  mkdir -p "$TOOLCHAIN_DIR"

  if [[ ! -d "$TOOLCHAIN_PATH" ]]; then
    if [[ ! -f "$TOOLCHAIN_DIR/$TOOLCHAIN_ARCHIVE" ]]; then
      log_info "Downloading $TOOLCHAIN_ARCHIVE..."
      wget --show-progress -O "$TOOLCHAIN_DIR/$TOOLCHAIN_ARCHIVE" "$TOOLCHAIN_URL" || {
        log_error "Failed to download toolchain. Check your internet connection."
        exit 1
      }
    fi
    tar -xf "$TOOLCHAIN_DIR/$TOOLCHAIN_ARCHIVE" -C "$TOOLCHAIN_DIR"
  else
    log_info "Toolchain already installed at $TOOLCHAIN_PATH"
  fi

  if [[ ! -d "$TOOLCHAIN_PATH" ]]; then
    log_error "Toolchain extraction failed."
    exit 1
  fi
}

# Configure shell environment
configure_environment() {
  log_info "Updating shell environment..."

  local env_vars="ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
GNUARMEMB_TOOLCHAIN_PATH=\"$TOOLCHAIN_DIR/gcc-arm-none-eabi-10.3-2021.10\""

  if ! grep -q "ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<EOF

# Zephyr ARM toolchain for STM32 (added by setup-zephyr-stm32.sh)
export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
export GNUARMEMB_TOOLCHAIN_PATH="$TOOLCHAIN_DIR/gcc-arm-none-eabi-10.3-2021.10"
EOF
    log_info "Appended environment variables to $BASHRC"
  else
    log_info "Environment variables already present in $BASHRC"
  fi

  export ZEPHYR_TOOLCHAIN_VARIANT=gnuarmemb
  export GNUARMEMB_TOOLCHAIN_PATH="$TOOLCHAIN_PATH"
}

# Initialize west workspace
init_west() {
  log_info "Initializing west workspace..."
  cd "$ZEHPHYR_REPO_DIR"
  if [[ ! -d "$HOME/.west" ]]; then
    west init -l .
    west config --local manifest.narrow true
    west update --narrow
  else
    log_info "West workspace already initialized at $HOME/.west"
  fi
}

# Verify build
verify_build() {
  log_info "Verifying build with samples/hello_world for $ZEPHYR_BOARD..."
  cd "$ZEHPHYR_REPO_DIR/samples/hello_world"

  # Find python3 >= 3.12
  PYTHON_PATH="/usr/bin/python3"
  for py in /usr/bin/python3.15 /usr/bin/python3.14 /usr/bin/python3.13 /usr/bin/python3.12 /usr/bin/python3; do
    if [[ -x "$py" ]]; then
      PYTHON_PATH="$py"
      break
    fi
  done
  export PYTHON_EXECUTABLE="$PYTHON_PATH"
  log_info "Using Python: $PYTHON_PATH"

  if west build -b "$ZEPHYR_BOARD" --pristine -- -DPython3_EXECUTABLE="$PYTHON_PATH"; then
    log_info "Build verification passed!"
  else
    log_error "Build verification failed."
    log_info "You can still use the environment. Try manually:"
    log_info "  cd $ZEHPHYR_REPO_DIR/samples/hello_world"
    log_info "  west build -b $ZEPHYR_BOARD"
  fi
}

# Main execution
main() {
  echo "=========================================="
  echo "  Zephyr STM32 Environment Setup"
  echo "=========================================="
  echo ""

  check_repo
  install_packages
  install_python_deps
  install_toolchain
  configure_environment
  init_west
  verify_build

  echo ""
  echo "=========================================="
  echo -e "${GREEN}Setup complete!${NC}"
  echo "=========================================="
  echo ""
  echo "To use in a new shell, run:"
  echo "  source \"$BASHRC\""
  echo ""
  echo "Build STM32 projects with:"
  echo "  cd $ZEHPHYR_REPO_DIR"
  echo "  west build -b $ZEPHYR_BOARD <app-dir>"
}

main
