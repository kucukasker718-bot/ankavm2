#!/bin/bash
set -e

# CLICD Build Script
# Builds frontend and backend into a single deployable package

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
FRONTEND_DIR="$SCRIPT_DIR/frontend"
BACKEND_DIR="$SCRIPT_DIR/backend"
WEB_DIR="$SCRIPT_DIR/web"
EMBED_WEB_DIR="$BACKEND_DIR/internal/server/web"

echo "====================================="
echo "  CLICD Build Script"
echo "====================================="

# Clean previous build
rm -rf "$BUILD_DIR"
rm -rf "$WEB_DIR"
rm -rf "$EMBED_WEB_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$WEB_DIR"
mkdir -p "$EMBED_WEB_DIR"
touch "$EMBED_WEB_DIR/.gitkeep"

# Step 1: Build frontend
echo ""
echo "[1/3] Building frontend..."
cd "$FRONTEND_DIR"

if [ ! -d "node_modules" ]; then
    echo "Installing frontend dependencies..."
    npm install
fi

npm run build

# Copy frontend build to web directory (for Go embed)
cp -r dist/* "$WEB_DIR/"
# Keep the Go embed directory in sync with the frontend build.
cp -r dist/* "$EMBED_WEB_DIR/"
touch "$EMBED_WEB_DIR/.gitkeep"
echo "Frontend built successfully"

# Step 2: Build Go backend
echo ""
echo "[2/3] Building Go backend..."
cd "$BACKEND_DIR"

go mod tidy
go mod download

# Build for Linux amd64
BUILD_VERSION="${CLICD_VERSION:-dev}"
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -ldflags="-s -w -X clicd/internal/version.Version=${BUILD_VERSION}" -o "$BUILD_DIR/clicd" .

echo "Go backend built successfully"

# Step 3: Package
echo ""
echo "[3/3] Packaging..."
cp -r "$WEB_DIR" "$BUILD_DIR/web"
cp "$SCRIPT_DIR/install.sh" "$BUILD_DIR/install.sh" 2>/dev/null || true
chmod +x "$BUILD_DIR/clicd"

echo ""
echo "====================================="
echo "  Build Complete!"
echo "====================================="
echo "  Output: $BUILD_DIR/clicd"
echo "  Web:    $BUILD_DIR/web/"
echo ""
echo "  To deploy:"
echo "    1. Copy build/ directory to server"
echo "    2. Run: ./clicd server"
echo "====================================="
