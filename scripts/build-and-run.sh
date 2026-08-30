#!/bin/bash

# MiddleClick - Build and Run Script
# Builds the project in Debug mode and runs it without opening Xcode

set -e  # Exit on error

# Build only if BUILD_SKIP is not set (allows Makefile to skip redundant builds)
if [ -z "$BUILD_SKIP" ]; then
  echo "🔨 Building MiddleClick (Debug)..."
  xcodebuild -project MiddleClick.xcodeproj \
    -scheme MiddleClick \
    -configuration Debug \
    build \
    | grep -E "BUILD (SUCCEEDED|FAILED)|error:" || true

  # Check if build succeeded
  if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
  fi
  echo "✅ Build succeeded!"
fi

# Kill any existing MiddleClick instance
echo "🔄 Stopping any running MiddleClick instances..."
pkill -x MiddleClick 2>/dev/null || true
sleep 0.5

# Run the newly built app
echo "🚀 Starting MiddleClick..."

# Ask Xcode where it put the .app (canonical — no find, no mtime guessing)
BUILT_PRODUCTS_DIR=$(xcodebuild -project MiddleClick.xcodeproj -scheme MiddleClick -configuration Debug -showBuildSettings 2>/dev/null | awk -F ' = ' '/ BUILT_PRODUCTS_DIR =/ {print $2}')
BUILD_PATH="$BUILT_PRODUCTS_DIR/MiddleClick.app"

# If the .app is missing at the canonical path, something's off.
if [ ! -d "$BUILD_PATH" ]; then
  if [ -n "$BUILD_RETRIED" ]; then
    echo "❌ Error: .app still missing at $BUILD_PATH after rebuild"
    exit 1
  fi

  if [ -n "$BUILD_SKIP" ]; then
    # Called from `make run`: the Make stamp is stale (e.g. Xcode cleared
    # DerivedData since the last build). Invalidate it and let make's
    # dependency chain rebuild via clean-build + run.
    echo "⚠️  .app missing at $BUILD_PATH — stale build stamp, re-running make..."
    export BUILD_RETRIED=1
    exec make clean-build run
  else
    # Direct invocation: we already ran xcodebuild at the top of this script.
    # If the .app is still missing, the build silently produced no output.
    echo "❌ Error: build reported success but no .app at $BUILD_PATH"
    exit 1
  fi
fi

open "$BUILD_PATH"
echo "✨ MiddleClick is running!"
