#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ios-project/ZhaiwoNativeScan/ZhaiwoNativeScan.xcodeproj"
TARGET_NAME="ZhaiwoNativeScan"
BUILD_DIR="$ROOT_DIR/build/ios"
OUTPUT_DIR="$ROOT_DIR/ios"

HBUILDER_IOS_SDK="${HBUILDER_IOS_SDK:-}"

if [[ -z "$HBUILDER_IOS_SDK" ]]; then
  cat <<'MSG' >&2
Please set HBUILDER_IOS_SDK to the HBuilder iOS SDK root.
It must be the directory that contains SDK/inc/DCUni/DCUniModule.h.

Example:
  HBUILDER_IOS_SDK=/Users/you/IOS-SDK/SDK ./scripts/build-ios-framework.sh
MSG
  exit 1
fi

if [[ ! -f "$HBUILDER_IOS_SDK/SDK/inc/DCUni/DCUniModule.h" ]]; then
  echo "Cannot find $HBUILDER_IOS_SDK/SDK/inc/DCUni/DCUniModule.h" >&2
  echo "HBUILDER_IOS_SDK should point to the extracted HBuilder iOS SDK root." >&2
  exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$OUTPUT_DIR"

xcodebuild \
  -project "$PROJECT_PATH" \
  -target "$TARGET_NAME" \
  -configuration Release \
  -sdk iphoneos \
  BUILD_DIR="$BUILD_DIR" \
  HBUILDER_IOS_SDK="$HBUILDER_IOS_SDK" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  clean build

rm -rf "$OUTPUT_DIR/$TARGET_NAME.framework"
cp -R "$BUILD_DIR/Release-iphoneos/$TARGET_NAME.framework" "$OUTPUT_DIR/"

echo "Built $OUTPUT_DIR/$TARGET_NAME.framework"
