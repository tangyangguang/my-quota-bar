#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h}
output_dir="$project_dir/outputs"
app_dir="$output_dir/My Quota Bar.app"

cd "$project_dir"
# 编译 universal（arm64 + x86_64），使 Apple Silicon 与 Intel Mac 都能运行。
swift build -c release --arch arm64 --arch x86_64

# Recreate only this script's generated application bundle.
if [[ -d "$app_dir" ]]; then
    /bin/rm -rf "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS"
# --arch 双架构产物在 apple/ 子目录（而非 release/）
bin_src="$project_dir/.build/apple/Products/Release/MyQuotaBar"
if [[ ! -f "$bin_src" ]]; then
    bin_src="$project_dir/.build/release/MyQuotaBar"
fi
cp "$bin_src" "$app_dir/Contents/MacOS/MyQuotaBar"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
chmod 755 "$app_dir/Contents/MacOS/MyQuotaBar"

xattr -cr "$app_dir"
codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
