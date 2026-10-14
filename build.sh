#!/bin/zsh
# Собирает универсальное (Apple Silicon + Intel) приложение мусоровоз.app
# и, с флагом --dmg, установочный образ мусоровоз-<версия>.dmg.
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_name="мусоровоз"
app_path="$build_dir/$app_name.app"
iconset="$build_dir/AppIcon.iconset"
min_macos="15.0"
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$project_dir/Info.plist")

sources=(
  "$project_dir/Sources/Models/CleanupModels.swift"
  "$project_dir/Sources/Services/CleanerService.swift"
  "$project_dir/Sources/Models/DashboardViewModel.swift"
  "$project_dir/Sources/Views/BlobViews.swift"
  "$project_dir/Sources/Views/DashboardView.swift"
  "$project_dir/Sources/AppEntry.swift"
)

rm -rf "$build_dir"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$iconset"

for arch in arm64 x86_64; do
  xcrun swiftc \
    -swift-version 5 \
    -parse-as-library \
    -O \
    -target "$arch-apple-macos$min_macos" \
    -framework SwiftUI \
    -framework AppKit \
    "${sources[@]}" \
    -o "$build_dir/MacCare-$arch"
done
lipo -create "$build_dir/MacCare-arm64" "$build_dir/MacCare-x86_64" -output "$app_path/Contents/MacOS/MacCare"
rm "$build_dir/MacCare-arm64" "$build_dir/MacCare-x86_64"

cp "$project_dir/Info.plist" "$app_path/Contents/Info.plist"
cp "$project_dir/Resources/MacCare.command" "$app_path/Contents/Resources/MacCare.command"
cp "$project_dir/Resources/logo.svg" "$app_path/Contents/Resources/logo.svg"

cp "$project_dir/Resources/icons/mac-16.png" "$iconset/icon_16x16.png"
cp "$project_dir/Resources/icons/mac-32.png" "$iconset/icon_16x16@2x.png"
cp "$project_dir/Resources/icons/mac-32.png" "$iconset/icon_32x32.png"
cp "$project_dir/Resources/icons/mac-64.png" "$iconset/icon_32x32@2x.png"
cp "$project_dir/Resources/icons/mac-128.png" "$iconset/icon_128x128.png"
cp "$project_dir/Resources/icons/mac-256.png" "$iconset/icon_128x128@2x.png"
cp "$project_dir/Resources/icons/mac-256.png" "$iconset/icon_256x256.png"
cp "$project_dir/Resources/icons/mac-512.png" "$iconset/icon_256x256@2x.png"
cp "$project_dir/Resources/icons/mac-512.png" "$iconset/icon_512x512.png"
cp "$project_dir/Resources/icons/mac-1024.png" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

chmod +x "$app_path/Contents/MacOS/MacCare" "$app_path/Contents/Resources/MacCare.command"
xattr -cr "$app_path"
codesign --force --deep --sign - "$app_path"
print -r -- "$app_path"

if [[ "${1:-}" == "--dmg" ]]; then
  staging="$build_dir/dmg"
  dmg_path="$build_dir/$app_name-$version.dmg"
  mkdir -p "$staging"
  cp -R "$app_path" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "$app_name" -srcfolder "$staging" -ov -format UDZO "$dmg_path" >/dev/null
  rm -rf "$staging"
  print -r -- "$dmg_path"
fi
