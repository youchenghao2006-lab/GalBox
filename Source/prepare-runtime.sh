#!/bin/zsh
# Reproduce the tested runtime from pinned upstream assets on an Apple Silicon Mac.
set -euo pipefail

project_dir="${0:A:h:h}"
runtime="$project_dir/Runtime"
cache="${GALBOX_DOWNLOAD_CACHE:-$project_dir/work/downloads}"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  print -u2 "Run this script in a native Apple Silicon macOS terminal."
  exit 1
}

check_runtime() {
  local root="$1" arch dll
  local wine_bin="$root/Wine Staging.app/Contents/Resources/wine/bin"
  local gst="$root/Frameworks/GStreamer.framework/Versions/1.0"
  [[ -x "$wine_bin/wine" && -x "$wine_bin/wineserver" && -x "$root/7zip/7zz" &&
     -x "$gst/libexec/gstreamer-1.0/gst-plugin-scanner" &&
     -s "$gst/lib/libgstreamer-1.0.0.dylib" ]] || return 1
  for arch in x32 x64; do
    for dll in d3d11.dll d3d10core.dll; do
      [[ -s "$root/DXVK/$arch/$dll" ]] || return 1
    done
  done
}

if [[ -e "$runtime" || -L "$runtime" ]]; then
  if check_runtime "$runtime"; then
    print "Runtime already present."
    exit 0
  fi
  print -u2 "Existing Runtime is incomplete. Move it aside, then rerun to prepare a clean copy."
  exit 1
fi

mkdir -p "$project_dir/work" "$cache"
lock="$project_dir/work/.prepare-runtime.lock"
mkdir "$lock" || { print -u2 "Another setup may be running. Check $lock."; exit 1; }
stage=""
cleanup() {
  trap - ZERR EXIT
  if [[ -n "$stage" && "${stage:h}" == "$project_dir/work" && "${stage:t}" == runtime-build.* ]]; then
    /bin/rm -rf -- "$stage"
  fi
  /bin/rmdir -- "$lock"
}
trap cleanup ZERR EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stage="$(mktemp -d "$project_dir/work/runtime-build.XXXXXXXX")"
dest="$stage/Runtime"

fetch() {
  local name="$1" url="$2" expected="$3" actual
  local archive="$cache/$name"
  if [[ ! -f "$archive" ]]; then
    /usr/bin/curl --fail --location --show-error --retry 3 --proto '=https' \
      --proto-redir '=https' --output "$stage/$name" "$url"
    archive="$stage/$name"
  fi
  actual="$(/usr/bin/shasum -a 256 "$archive")"
  if [[ "${actual%% *}" != "$expected" ]]; then
    print -u2 "SHA-256 mismatch: $archive. Check its source and replace the file before retrying."
    return 1
  fi
  if [[ "$archive" != "$cache/$name" ]]; then
    /bin/mv "$archive" "$cache/$name"
  fi
}

fetch wine-staging-11.18-osx64.tar.xz \
  https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz \
  b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127
fetch 7zip.tar.xz \
  https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz \
  bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578
fetch dxvk-macos-native.tar.gz \
  https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz \
  acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477
fetch gstreamer.pkg \
  https://gstreamer.freedesktop.org/data/pkg/osx/1.28.5/gstreamer-1.0-1.28.5-universal.pkg \
  0a8fc7a1cf8d7bac833ca0ebe2fd196a199c2465e810cd5b1e4b4f720c258f43

mkdir -p "$dest/7zip" "$dest/DXVK" "$dest/Frameworks"
/usr/bin/tar -xf "$cache/wine-staging-11.18-osx64.tar.xz" -C "$dest"
/usr/bin/tar -xf "$cache/7zip.tar.xz" -C "$dest/7zip"
/usr/bin/tar -xf "$cache/dxvk-macos-native.tar.gz" --strip-components 1 -C "$dest/DXVK"

# Expand the signed installer as data and merge its relocatable framework payloads.
expanded="$stage/gstreamer-expanded"
framework="$dest/Frameworks/GStreamer.framework"
/usr/sbin/pkgutil --expand-full "$cache/gstreamer.pkg" "$expanded"
/usr/bin/ditto "$expanded/osx-framework-1.28.5-universal.pkg/Payload" "$framework"
for pkg in "$expanded"/*.pkg; do
  if [[ "${pkg:t}" != osx-framework-* ]]; then
    /usr/bin/ditto "$pkg/Payload" "$framework/Versions/1.0"
  fi
done

check_runtime "$dest" || { print -u2 "Unpacked runtime failed its file checks."; exit 1; }
[[ ! -e "$runtime" && ! -L "$runtime" ]] || { print -u2 "Runtime was created during setup. Rerun to check it."; exit 1; }
/bin/mv "$dest" "$runtime"
print "Runtime ready. Run zsh Source/build.sh to build GalBox.app."
