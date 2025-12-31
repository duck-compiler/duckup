#!/usr/bin/env bash
set -e

REPO="duck-compiler/duckup"
INSTALL_DIR="$HOME/.duckup"
BIN_DIR="$INSTALL_DIR/bin"
EXE_NAME="duckup"

C_RESET='\033[0m'
C_WHITE='\033[97m'
BG_ERR='\033[41;97m'
BG_DARGO='\033[103;30m'
BG_ALERT='\033[103;30m'
BG_SETUP='\033[48;2;23;120;20;97m'
BG_CHECK='\033[42;97m'
BG_IO='\033[48;2;23;120;20;97m'

tag_dargo() { echo -en "${BG_DARGO} duckup ${C_RESET}"; }
tag_setup() { echo -e "$(tag_dargo)${BG_SETUP} setup ${C_RESET} $@"; }
tag_error() { echo -e "$(tag_dargo)${BG_ERR} error ${C_RESET} $@"; }
tag_check() { echo -e "$(tag_dargo)${BG_CHECK}  ✓  ${C_RESET} $@"; }
tag_io()    { echo -e "$(tag_dargo)${BG_IO}  IO   ${C_RESET} $@"; }
tag_alert() { echo -e "$(tag_dargo)${BG_ALERT}  !  ${C_RESET} $@"; }

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${OS}" in
    darwin)  OS_TAG="macos" ;;
    linux)   OS_TAG="linux" ;;
    *) tag_error "Unsupported OS: $OS"; exit 1 ;;
esac

case "${ARCH}" in
    x86_64)  ARCH_TAG="x86_64" ;;
    aarch64|arm64) ARCH_TAG="aarch64" ;;
    armv7*)  ARCH_TAG="armv7" ;;
    *) tag_error "Unsupported Architecture: $ARCH"; exit 1 ;;
esac

tag_setup "Detecting latest nightly for $OS_TAG-$ARCH_TAG..."

RELEASES_JSON=$(curl -sSf "https://api.github.com/repos/$REPO/releases" || echo "ERROR")

if [ "$RELEASES_JSON" = "ERROR" ]; then
    tag_error "Failed to fetch releases. Check if REPO='$REPO' is correct and public."
    exit 1
fi

LATEST_TAG=$(echo "$RELEASES_JSON" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | grep '^nightly-' | head -n 1 || true)

if [ -z "$LATEST_TAG" ]; then
    tag_error "Could not find a 'nightly-*' tag in $REPO. Please check your GitHub Releases."
    exit 1
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/duckup-$OS_TAG-$ARCH_TAG"

tag_io "Downloading $EXE_NAME from $LATEST_TAG..."
mkdir -p "$BIN_DIR"
curl -qLsSf "$DOWNLOAD_URL" -o "$BIN_DIR/$EXE_NAME"
chmod +x "$BIN_DIR/$EXE_NAME"

tag_check "Successfully installed $EXE_NAME to $BIN_DIR/$EXE_NAME"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    tag_setup "Adding $BIN_DIR to PATH..."

    SHELL_NAME=$(basename "$SHELL")
    case "$SHELL_NAME" in
        zsh)  CONF="$HOME/.zshrc"; EXPORT_CMD="export PATH=\"$BIN_DIR:\$PATH\"" ;;
        bash) CONF="$HOME/.bashrc"; EXPORT_CMD="export PATH=\"$BIN_DIR:\$PATH\"" ;;
        fish) CONF="$HOME/.config/fish/config.fish"; EXPORT_CMD="set -gx PATH $BIN_DIR \$PATH" ;;
        *)    CONF=""; EXPORT_CMD="export PATH=\"$BIN_DIR:\$PATH\"" ;;
    esac

    if [ -n "$CONF" ] && [ -w "$(dirname "$CONF")" ]; then
        if ! grep -q "$BIN_DIR" "$CONF" 2>/dev/null; then
            echo -e "\n# duckup\n$EXPORT_CMD" >> "$CONF"
            tag_check "Updated $CONF"
        fi
        echo ""
        tag_alert "To start using duckup, run:"
        echo -e "  ${C_WHITE}source $CONF${C_RESET}"
    else
        tag_error "Could not update shell config automatically."
        tag_alert "Manually add this to your path:"
        echo "  $EXPORT_CMD"
    fi
fi

echo -e "\n---"
"$BIN_DIR/$EXE_NAME" --help
