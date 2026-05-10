#!/bin/bash
# Build sub2api Vue 3 frontend and copy to priv/static/
# Requires: node 18+, pnpm

set -e

FRONTEND_DIR="${1:-../sub2api/frontend}"
OUTPUT_DIR="priv/static"

if [ ! -d "$FRONTEND_DIR" ]; then
    echo "Frontend directory not found: $FRONTEND_DIR"
    echo "Usage: $0 [path-to-sub2api-frontend]"
    exit 1
fi

echo "Building frontend from $FRONTEND_DIR..."
cd "$FRONTEND_DIR"
pnpm install --frozen-lockfile
pnpm build

echo "Copying build output to $OUTPUT_DIR..."
cd -
rm -rf "$OUTPUT_DIR"/*
cp -r "$FRONTEND_DIR/dist/"* "$OUTPUT_DIR/"

echo "Frontend build complete. Files in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR/"
