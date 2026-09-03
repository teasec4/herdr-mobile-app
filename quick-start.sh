#!/usr/bin/env bash
# Quick start script for Herdr Mobile installation and setup
set -euo pipefail

REPO_URL="https://github.com/teasec4/herdr-mobile-app"
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║            Herdr Mobile Quick Start                ║${NC}"
echo -e "${BLUE}║     Control herdr from your phone                    ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v herdr &> /dev/null; then
    echo -e "${RED}✗ herdr not found${NC}"
    echo "  Please install herdr from https://herdr.dev first"
    exit 1
fi
echo -e "${GREEN}✓ herdr found${NC}"

if ! command -v go &> /dev/null; then
    echo -e "${RED}✗ Go not found${NC}"
    echo "  Please install Go 1.26+ from https://go.dev"
    exit 1
fi
echo -e "${GREEN}✓ Go found${NC}"

HERDR_VERSION=$(herdr --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unknown")
echo -e "${GREEN}✓ herdr version: $HERDR_VERSION${NC}"
echo ""

# Installation choice
echo "Choose installation method:"
echo "  1) Install from GitHub (recommended)"
echo "  2) Install from local repository (for development)"
read -p "Enter choice [1]: " CHOICE
CHOICE=${CHOICE:-1}

echo ""

if [ "$CHOICE" = "1" ]; then
    echo "Installing plugin from GitHub..."
    herdr plugin install teasec4/herdr-mobile-app/plugin

elif [ "$CHOICE" = "2" ]; then
    read -p "Enter path to herdr_relay repository: " REPO_PATH

    if [ ! -d "$REPO_PATH" ]; then
        echo -e "${RED}✗ Directory not found: $REPO_PATH${NC}"
        exit 1
    fi

    echo "Linking local plugin..."
    herdr plugin link "$REPO_PATH/plugin"

    echo "Building relay..."
    bash "$REPO_PATH/plugin/install.sh"
else
    echo -e "${RED}Invalid choice${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ Plugin installed${NC}"
echo ""

# Check relay status
sleep 2
if curl -s -m 2 "http://127.0.0.1:8375/healthz" &>/dev/null; then
    echo -e "${GREEN}✓ Relay is running on :8375${NC}"
else
    echo -e "${YELLOW}⚠ Relay not responding yet. Check logs:${NC}"
    echo "    tail -f ~/.local/state/herdrelay/relay.err.log"
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Installation complete!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Show QR code for phone pairing:"
echo -e "   ${YELLOW}herdr plugin action invoke show-pair-link --plugin herdrelay.events${NC}"
echo ""
echo "2. Download mobile app:"
echo -e "   Android: ${BLUE}${REPO_URL}/releases${NC}"
echo -e "   iOS: Coming soon"
echo ""
echo "3. Open the app and scan the QR code"
echo ""
echo "Connection modes:"
echo "  • LAN:       Both devices on same WiFi (automatic)"
echo "  • Tailscale: Install Tailscale on both devices (works anywhere)"
echo "  • Funnel:    Run 'tailscale funnel 8375' for public HTTPS"
echo ""
echo "Useful commands:"
echo "  • Check status:  curl http://127.0.0.1:8375/healthz"
echo "  • View logs:     tail -f ~/.local/state/herdrelay/relay.err.log"
echo "  • Change mode:   bash plugin/configure.sh [lan|tailscale|funnel]"
echo ""
echo "Documentation: ${BLUE}${REPO_URL}${NC}"
echo ""
