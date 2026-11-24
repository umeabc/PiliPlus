#!/usr/bin/env bash
# Non-destructive equivalent of the Android patch list in lib/scripts/patch.ps1.
# Run pub get with the checked-in lockfile first. Use a dedicated Flutter SDK/cache.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  printf 'Usage: bash tool/apply_android_framework_patches.sh <Flutter SDK> <material_ui-1.11.0 package directory>\n' >&2
  exit 2
fi
repo="$(pwd -P)"
sdk="$1"
material="$2"
if [ ! -f "$repo/pubspec.yaml" ] || [ ! -d "$sdk/packages/flutter" ] || [ ! -f "$material/pubspec.yaml" ]; then
  printf 'Run at the PiliPlus repository root with the correct SDK and package paths.\n' >&2
  exit 2
fi
apply_one() {
  local root="$1" patch="$2"
  if git -C "$root" apply --check "$repo/$patch" 2>&1; then
    git -C "$root" apply "$repo/$patch"
    printf 'Applied %s\n' "$patch"
  elif git -C "$root" apply --reverse --check "$repo/$patch" 2>&1; then
    printf 'Already applied %s\n' "$patch"
  else
    printf 'Patch incompatible: %s. Stop; do not reset or delete existing SDK/package changes.\n' "$patch" >&2
    exit 1
  fi
}
for name in modal_barrier text_selection mouse_cursor image_anim layout_builder navigation_drawer popup_menu fab null_safety_for_selectable_region selectable_region editable_text text_field scroll_position scrollable scrollable_gesture draggable_scrollable_sheet scaffold text text_painter sliver refresh_indicator double_tap_gesture media_query bottom_sheet_android scroll_view navigator; do
  apply_one "$sdk" "lib/scripts/$name.patch"
done
for name in modal_barrier_material navigation_drawer popup_menu fab text_field scaffold refresh_indicator tabs bottom_sheet_android; do
  apply_one "$material" "lib/scripts/material/$name.patch"
done
