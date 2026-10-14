#!/bin/zsh

# MacCare — conservative cache cleaner for macOS.
# It never touches Documents, Downloads, projects, browser profiles,
# Telegram databases, Codex session history, or the Claude VM.

set -u
setopt NULL_GLOB

readonly SCRIPT_NAME="MacCare"
readonly INVOCATION_NAME="${0:t}"
readonly LOG_DIR="$HOME/Library/Logs"
readonly LOG_FILE="$LOG_DIR/MacCare-cleaner.log"

typeset -a SAFE_TARGETS
SAFE_TARGETS=(
  "npm package cache|$HOME/.npm/_cacache|"
  "temporary npx packages|$HOME/.npm/_npx|"
  "Codex app cache|$HOME/Library/Caches/Codex|ChatGPT|Codex"
  "Yandex browser cache|$HOME/Library/Caches/Yandex|Yandex"
  "pip download cache|$HOME/Library/Caches/pip|"
  "uv package cache|$HOME/.cache/uv|"
  "Bun install cache|$HOME/.bun/install/cache|"
)

typeset -a CLAUDE_TARGETS
CLAUDE_TARGETS=(
  "Claude Cache|$HOME/Library/Application Support/Claude/Cache|Claude"
  "Claude Code Cache|$HOME/Library/Application Support/Claude/Code Cache|Claude"
)

typeset -a VSCODE_TARGETS
VSCODE_TARGETS=(
  "VS Code update cache (ShipIt)|$HOME/Library/Caches/com.microsoft.VSCode.ShipIt|Visual Studio Code|Code Helper"
  "downloaded extension installers|$HOME/Library/Application Support/Code/CachedExtensionVSIXs|Visual Studio Code|Code Helper"
  "VS Code Cache|$HOME/Library/Application Support/Code/Cache|Visual Studio Code|Code Helper"
  "VS Code CachedData|$HOME/Library/Application Support/Code/CachedData|Visual Studio Code|Code Helper"
  "VS Code GPUCache|$HOME/Library/Application Support/Code/GPUCache|Visual Studio Code|Code Helper"
  "VS Code old logs|$HOME/Library/Application Support/Code/logs|Visual Studio Code|Code Helper"
  "VS Code completed crash reports|$HOME/Library/Application Support/Code/Crashpad/completed|Visual Studio Code|Code Helper"
)

typeset -a OPTIONAL_MODEL_TARGETS
OPTIONAL_MODEL_TARGETS=(
  "downloaded SigLIP model cache|$HOME/.cache/hub|"
  "Hugging Face model cache|$HOME/.cache/huggingface|"
)

mkdir -p "$LOG_DIR"

log() {
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG_FILE"
}

pause_if_interactive() {
  if [[ -t 0 && -z "${1:-}" ]]; then
    print
    read -r "?Нажмите Enter, чтобы закрыть окно…"
  fi
}

size_kb() {
  local target_path="$1"
  [[ -e "$target_path" ]] || { print 0; return; }
  du -sk "$target_path" 2>/dev/null | awk '{print $1+0}'
}

human_kb() {
  awk -v kb="${1:-0}" 'BEGIN {
    if (kb >= 1048576) printf "%.1f ГБ", kb / 1048576;
    else if (kb >= 1024) printf "%.0f МБ", kb / 1024;
    else printf "%d КБ", kb;
  }'
}

sum_array_kb() {
  local entry label target_path guard total=0
  for entry in "$@"; do
    IFS='|' read -r label target_path guard <<< "$entry"
    (( total += $(size_kb "$target_path") ))
  done
  print "$total"
}

sum_paths_kb() {
  local target_path total=0
  for target_path in "$@"; do
    (( total += $(size_kb "$target_path") ))
  done
  print "$total"
}

is_running() {
  local pattern="$1"
  [[ -n "$pattern" ]] || return 1
  pgrep -if "$pattern" >/dev/null 2>&1
}

validate_target() {
  local target_path="$1"
  [[ -n "$target_path" && "$target_path" != "/" && "$target_path" != "$HOME" ]] || return 1
  case "$target_path" in
    "$HOME/.npm/"*|"$HOME/.cache/"*|"$HOME/.bun/install/cache"|"$HOME/.bun/install/cache/"*|"$HOME/Library/Caches/"*|"$HOME/Library/Developer/Xcode/DerivedData"|"$HOME/Library/Developer/Xcode/DerivedData/"*|"$HOME/Library/Application Support/Claude/"*|"$HOME/Library/Application Support/Code/"*|"$HOME/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/"*|"$HOME/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches"|"$HOME/.codex/packages/app-server-daemon/releases/"*|"$HOME/.vscode/extensions/"*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_target() {
  local label="$1" target_path="$2" guard="${3:-}"
  local kb

  [[ -e "$target_path" ]] || return 0
  if [[ -n "$guard" ]] && is_running "$guard"; then
    print "  ↷ Пропущено: $label — приложение запущено ($guard)."
    log "SKIP running app: $label [$target_path]"
    return 0
  fi
  if ! validate_target "$target_path"; then
    print "  ! Заблокирован небезопасный путь: $target_path"
    log "BLOCK unsafe path: $target_path"
    return 1
  fi

  kb=$(size_kb "$target_path")
  rm -rf -- "$target_path"
  if [[ ! -e "$target_path" ]]; then
    print "  ✓ $label: освобождено $(human_kb "$kb")"
    log "REMOVE $label: ${kb} KiB [$target_path]"
  else
    print "  ! Не удалось очистить: $label"
    log "FAIL $label [$target_path]"
  fi
}

scan_array() {
  local title="$1"
  shift
  local entry label target_path guard kb total=0
  print "\n$title"
  for entry in "$@"; do
    IFS='|' read -r label target_path guard <<< "$entry"
    kb=$(size_kb "$target_path")
    (( total += kb ))
    printf "  %-34s %10s\n" "$label" "$(human_kb "$kb")"
  done
  printf "  %-34s %10s\n" "Итого" "$(human_kb "$total")"
}

scan_codex() {
  local releases="$HOME/.codex/packages/app-server-daemon/releases"
  local sessions="$HOME/.codex/sessions"
  local history="$HOME/.codex/thread_history_1.sqlite"
  local runtimes="$HOME/.cache/codex-runtimes"
  print "\nCodex (история в очистку не входит)"
  printf "  %-34s %10s\n" "версии app-server" "$(human_kb "$(size_kb "$releases")")"
  printf "  %-34s %10s\n" "runtime-кэши" "$(human_kb "$(size_kb "$runtimes")")"
  printf "  %-34s %10s\n" "сессии — сохраняются" "$(human_kb "$(size_kb "$sessions")")"
  printf "  %-34s %10s\n" "база истории — сохраняется" "$(human_kb "$(size_kb "$history")")"
}

telegram_targets() {
  local target_path account_name
  local telegram_root="$HOME/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore"
  while IFS= read -r target_path; do
    account_name="${target_path:h:h:t}"
    print -r -- "Telegram media ($account_name)|$target_path|Telegram"
  done < <(find "$telegram_root" -mindepth 3 -maxdepth 3 -type d -path "$telegram_root/account-*/postbox/media" -print 2>/dev/null)
  target_path="$HOME/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches"
  [[ -d "$target_path" ]] && print -r -- "Telegram application cache|$target_path|Telegram"
}

old_version_dirs_kb() {
  local root="$1" pattern="$2"
  local dir latest total=0 count=0
  [[ -d "$root" ]] || { print 0; return; }
  latest=$(find "$root" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -print 2>/dev/null | sort -V | tail -n 1)
  [[ -n "$latest" ]] || { print 0; return; }
  while IFS= read -r dir; do
    (( count += 1 ))
    [[ "$dir" == "$latest" ]] && continue
    (( total += $(size_kb "$dir") ))
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -name "$pattern" -print 2>/dev/null | sort -V)
  (( count > 1 )) || total=0
  print "$total"
}

old_vscode_extensions_kb() {
  local extension total=0
  local -a extension_ids
  extension_ids=("openai.chatgpt" "openai.codex-audio" "anthropic.claude-code" "google.geminicodeassist" "vue.volar")
  for extension in "${extension_ids[@]}"; do
    (( total += $(old_version_dirs_kb "$HOME/.vscode/extensions" "$extension-*") ))
  done
  print "$total"
}

scan_application_caches() {
  local -a telegram_entries
  telegram_entries=("${(@f)$(telegram_targets)}")
  scan_array "Claude: восстанавливаемые кэши" "${CLAUDE_TARGETS[@]}"
  print "  старые версии Claude Code: $(human_kb "$(old_version_dirs_kb "$HOME/Library/Application Support/Claude/claude-code" '*')")"
  scan_array "VS Code: восстанавливаемые кэши" "${VSCODE_TARGETS[@]}"
  print "  старые версии выбранных расширений: $(human_kb "$(old_vscode_extensions_kb)")"
  (( ${#telegram_entries[@]} )) && scan_array "Telegram: только media/cache, не базы" "${telegram_entries[@]}"
  print "\n  Claude VM (только отдельное подтверждение): $(human_kb "$(size_kb "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle")")"
}

scan_system() {
  clear 2>/dev/null || true
  print "────────────────────────────────────────────────────"
  print " $SCRIPT_NAME — анализ безопасно очищаемых данных"
  print "────────────────────────────────────────────────────"
  local free
  free=$(df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
  print "Свободно на SSD: ${free:-не определено}"
  scan_array "Безопасные кэши" "${SAFE_TARGETS[@]}"
  scan_array "Модели, которые можно скачать повторно" "${OPTIONAL_MODEL_TARGETS[@]}"
  scan_application_caches
  scan_codex
  print "\nНе затрагиваются: Documents, Downloads, проекты, Telegram postbox/db,"
  print "профили браузеров, история Codex и виртуальная машина Claude."
}

large_file_candidates() {
  local target_path actual_kb encoded counted
  mdfind -onlyin "$HOME" 'kMDItemFSSize >= 524288000' 2>/dev/null \
    | head -n 250 \
    | while IFS= read -r target_path; do
        [[ -f "$target_path" ]] || continue
        case "$target_path" in
          *.app/Contents/*) continue ;;
        esac
        actual_kb=$(size_kb "$target_path")
        (( actual_kb >= 512000 )) || continue
        encoded=$(printf '%s' "$target_path" | /usr/bin/base64 | tr -d '\n')
        counted=false
        case "$target_path" in
          "$HOME/.npm/_cacache"/*|"$HOME/.npm/_npx"/*|"$HOME/Library/Caches/pip"/*|"$HOME/.cache/uv"/*|"$HOME/Library/pnpm/store"/*|"$HOME/.pnpm-store"/*|"$HOME/.bun/install/cache"/*|\
          "$HOME/Library/Developer/Xcode/DerivedData"/*|\
          "$HOME/Library/Caches/Codex"/*|"$HOME/Library/Caches/Yandex"/*|\
          "$HOME/Library/Application Support/Claude/Cache"/*|"$HOME/Library/Application Support/Claude/Code Cache"/*|"$HOME/Library/Application Support/Claude/claude-code"/*|\
          "$HOME/Library/Caches/com.microsoft.VSCode.ShipIt"/*|"$HOME/Library/Application Support/Code/CachedExtensionVSIXs"/*|"$HOME/Library/Application Support/Code/Cache"/*|"$HOME/Library/Application Support/Code/CachedData"/*|"$HOME/Library/Application Support/Code/GPUCache"/*|"$HOME/Library/Application Support/Code/logs"/*|"$HOME/Library/Application Support/Code/Crashpad/completed"/*|\
          "$HOME/Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram/appstore/"*/postbox/media/*|"$HOME/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches"/*|\
          "$HOME/.cache/hub"/*|"$HOME/.cache/huggingface"/*|\
          "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"/*) counted=true ;;
        esac
        printf '%020d|%s|%s\n' "$actual_kb" "$encoded" "$counted"
      done \
    | sort -t'|' -k1,1nr \
    | head -n 20
}

installer_file_candidates() {
  local target_path actual_kb encoded
  [[ -d "$HOME/Downloads" ]] || return 0
  find "$HOME/Downloads" -maxdepth 2 -type f \( \
      -iname '*.dmg' -o -iname '*.pkg' -o -iname '*.xip' -o \
      -iname '*.zip' -o -iname '*.tgz' -o -iname '*.tar.gz' -o \
      -iname '*.rar' -o -iname '*.7z' \
    \) -print0 2>/dev/null \
    | while IFS= read -r -d '' target_path; do
        actual_kb=$(size_kb "$target_path")
        (( actual_kb > 0 )) || continue
        encoded=$(printf '%s' "$target_path" | /usr/bin/base64 | tr -d '\n')
        printf '%020d|%s\n' "$actual_kb" "$encoded"
      done \
    | sort -t'|' -k1,1nr \
    | head -n 40
}

# The pnpm store holds hundreds of thousands of tiny files, so `du` on it
# takes many seconds. Its size is cached and reused while the store's
# top-level layout (names, mtimes and sizes up to depth 2) is unchanged:
# pnpm adds and prunes files inside files/XX, which updates those mtimes.
cached_store_kb() {
  local root="$1"
  [[ -d "$root" ]] || { print 0; return; }
  local cache_dir="$HOME/Library/Caches/MacCare"
  local cache_file="$cache_dir/size-$(print -rn -- "$root" | /sbin/md5 -q)"
  local fingerprint cached_fingerprint cached_kb kb
  fingerprint=$(find "$root" -mindepth 1 -maxdepth 2 -print0 2>/dev/null \
    | xargs -0 stat -f '%N %m %z' 2>/dev/null | /sbin/md5 -q)
  if [[ -r "$cache_file" ]]; then
    IFS='|' read -r cached_fingerprint cached_kb < "$cache_file"
    if [[ "$cached_fingerprint" == "$fingerprint" && "$cached_kb" == <-> ]] && \
       [[ -n "$(find "$cache_file" -mtime -1 -print 2>/dev/null)" ]]; then
      print "$cached_kb"
      return
    fi
  fi
  kb=$(size_kb "$root")
  mkdir -p "$cache_dir" && print -r -- "$fingerprint|$kb" > "$cache_file"
  print "$kb"
}

# Runs a size calculation in the background, storing the result in $scan_tmp.
bg_kb() {
  local key="$1"
  shift
  ( "$@" > "$scan_tmp/$key" 2>/dev/null ) &
}

read_kb() {
  local value
  value=$(<"$scan_tmp/$1") 2>/dev/null
  [[ "$value" == <-> ]] && print "$value" || print 0
}

scan_json() {
  local development_kb application_kb telegram_kb models_kb vm_kb xcode_kb free_kb
  local npm_kb npx_kb pip_kb uv_kb pnpm_kb bun_kb codex_kb yandex_kb claude_kb vscode_kb
  local siglip_kb huggingface_kb rootfs_kb vm_other_kb
  local -a telegram_entries
  local entry label target_path guard item_kb item_index=0 rootfs_path
  local large_kb installer_kb encoded counted first_large=1 first_installer=1

  local scan_tmp
  scan_tmp=$(mktemp -d "${TMPDIR:-/tmp}/maccare-scan.XXXXXX") || return 1
  trap "rm -rf ${(q)scan_tmp}" EXIT

  telegram_entries=("${(@f)$(telegram_targets)}")

  # Every directory is measured in parallel; the slowest one sets the pace.
  bg_kb npm size_kb "$HOME/.npm/_cacache"
  bg_kb npx size_kb "$HOME/.npm/_npx"
  bg_kb pip size_kb "$HOME/Library/Caches/pip"
  bg_kb uv size_kb "$HOME/.cache/uv"
  bg_kb pnpm1 cached_store_kb "$HOME/Library/pnpm/store"
  bg_kb pnpm2 cached_store_kb "$HOME/.pnpm-store"
  bg_kb bun size_kb "$HOME/.bun/install/cache"
  bg_kb xcode size_kb "$HOME/Library/Developer/Xcode/DerivedData"
  bg_kb codex size_kb "$HOME/Library/Caches/Codex"
  bg_kb yandex size_kb "$HOME/Library/Caches/Yandex"
  bg_kb claude sum_array_kb "${CLAUDE_TARGETS[@]}"
  bg_kb claude_old old_version_dirs_kb "$HOME/Library/Application Support/Claude/claude-code" '*'
  bg_kb vscode sum_array_kb "${VSCODE_TARGETS[@]}"
  bg_kb vscode_old old_vscode_extensions_kb
  bg_kb siglip size_kb "$HOME/.cache/hub"
  bg_kb huggingface size_kb "$HOME/.cache/huggingface"
  bg_kb vm size_kb "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
  item_index=0
  for entry in "${telegram_entries[@]}"; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r label target_path guard <<< "$entry"
    bg_kb "telegram.$item_index" size_kb "$target_path"
    (( item_index += 1 ))
  done
  ( large_file_candidates > "$scan_tmp/large" 2>/dev/null ) &
  ( installer_file_candidates > "$scan_tmp/installers" 2>/dev/null ) &
  ( find "$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle" -type f -name 'rootfs.img' -print 2>/dev/null \
      | while IFS= read -r rootfs_path; do size_kb "$rootfs_path"; done \
      | awk '{s+=$1} END {print s+0}' > "$scan_tmp/rootfs" ) &
  wait

  npm_kb=$(read_kb npm)
  npx_kb=$(read_kb npx)
  pip_kb=$(read_kb pip)
  uv_kb=$(read_kb uv)
  (( pnpm_kb = $(read_kb pnpm1) + $(read_kb pnpm2) ))
  bun_kb=$(read_kb bun)
  (( development_kb = npm_kb + npx_kb + pip_kb + uv_kb + pnpm_kb + bun_kb ))
  xcode_kb=$(read_kb xcode)

  codex_kb=$(read_kb codex)
  yandex_kb=$(read_kb yandex)
  (( claude_kb = $(read_kb claude) + $(read_kb claude_old) ))
  (( vscode_kb = $(read_kb vscode) + $(read_kb vscode_old) ))
  (( application_kb = codex_kb + yandex_kb + claude_kb + vscode_kb ))

  telegram_kb=0
  for (( item_index = 0; item_index < ${#telegram_entries[@]}; item_index++ )); do
    [[ -e "$scan_tmp/telegram.$item_index" ]] || continue
    (( telegram_kb += $(read_kb "telegram.$item_index") ))
  done

  siglip_kb=$(read_kb siglip)
  huggingface_kb=$(read_kb huggingface)
  (( models_kb = siglip_kb + huggingface_kb ))
  vm_kb=$(read_kb vm)
  rootfs_kb=$(read_kb rootfs)
  (( vm_other_kb = vm_kb > rootfs_kb ? vm_kb - rootfs_kb : 0 ))
  free_kb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4+0}')

  printf '{"schemaVersion":4,"freeBytes":%d,"categories":[' "$(( free_kb * 1024 ))"
  printf '{"id":"applications","title":"Кэши приложений","subtitle":"Codex, Yandex, Claude и VS Code","systemImage":"square.stack.3d.up.fill","bytes":%d,"defaultSelected":true,"items":[' "$(( application_kb * 1024 ))"
  printf '{"id":"applications.codex","title":"Codex","subtitle":"Кэш приложения","systemImage":"sparkles","bytes":%d},' "$(( codex_kb * 1024 ))"
  printf '{"id":"applications.yandex","title":"Yandex","subtitle":"Кэш браузера","systemImage":"globe","bytes":%d},' "$(( yandex_kb * 1024 ))"
  printf '{"id":"applications.claude","title":"Claude","subtitle":"Cache, Code Cache и старые версии","systemImage":"brain.head.profile","bytes":%d},' "$(( claude_kb * 1024 ))"
  printf '{"id":"applications.vscode","title":"VS Code","subtitle":"Кэши и старые расширения","systemImage":"chevron.left.forwardslash.chevron.right","bytes":%d}]},' "$(( vscode_kb * 1024 ))"

  printf '{"id":"telegram","title":"Telegram","subtitle":"Только media и cache, не сообщения","systemImage":"paperplane.fill","bytes":%d,"defaultSelected":true,"items":[' "$(( telegram_kb * 1024 ))"
  item_index=0
  for entry in "${telegram_entries[@]}"; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r label target_path guard <<< "$entry"
    item_kb=$(read_kb "telegram.$item_index")
    (( item_index > 0 )) && printf ','
    if [[ "$label" == Telegram\ media* ]]; then
      printf '{"id":"telegram.media.%d","title":"Telegram media","subtitle":"Фото, видео и загруженные файлы","systemImage":"photo.on.rectangle.angled","bytes":%d}' "$item_index" "$(( item_kb * 1024 ))"
    else
      printf '{"id":"telegram.cache.%d","title":"Кэш Telegram","subtitle":"Временные данные приложения","systemImage":"archivebox.fill","bytes":%d}' "$item_index" "$(( item_kb * 1024 ))"
    fi
    (( item_index += 1 ))
  done
  printf ']},'

  printf '{"id":"development","title":"Файлы разработки","subtitle":"npm, pnpm, Bun, pip и uv","systemImage":"chevron.left.forwardslash.chevron.right","bytes":%d,"defaultSelected":true,"items":[' "$(( development_kb * 1024 ))"
  printf '{"id":"development.npm","title":"npm cache","subtitle":"Кэш скачанных пакетов","systemImage":"shippingbox","bytes":%d},' "$(( npm_kb * 1024 ))"
  printf '{"id":"development.npx","title":"npx packages","subtitle":"Временные пакеты npx","systemImage":"terminal.fill","bytes":%d},' "$(( npx_kb * 1024 ))"
  printf '{"id":"development.pip","title":"pip cache","subtitle":"Кэш пакетов Python","systemImage":"chevron.left.forwardslash.chevron.right","bytes":%d},' "$(( pip_kb * 1024 ))"
  printf '{"id":"development.uv","title":"uv cache","subtitle":"Кэш менеджера uv","systemImage":"bolt.fill","bytes":%d},' "$(( uv_kb * 1024 ))"
  printf '{"id":"development.pnpm","title":"pnpm Store","subtitle":"Неиспользуемые пакеты удаляются через pnpm prune","systemImage":"shippingbox.fill","bytes":%d},' "$(( pnpm_kb * 1024 ))"
  printf '{"id":"development.bun","title":"Bun Cache","subtitle":"Кэш загруженных пакетов Bun","systemImage":"archivebox.fill","bytes":%d}]},' "$(( bun_kb * 1024 ))"

  printf '{"id":"xcode","title":"Xcode","subtitle":"Производные данные сборок","systemImage":"hammer.fill","bytes":%d,"defaultSelected":false,"items":[' "$(( xcode_kb * 1024 ))"
  printf '{"id":"xcode.derivedData","title":"DerivedData","subtitle":"Будет создана заново при следующей сборке","systemImage":"hammer.circle.fill","bytes":%d}]},' "$(( xcode_kb * 1024 ))"

  printf '{"id":"models","title":"Модели ИИ","subtitle":"Потребуется повторная загрузка","systemImage":"shippingbox.fill","bytes":%d,"defaultSelected":false,"items":[' "$(( models_kb * 1024 ))"
  printf '{"id":"models.siglip","title":"SigLIP","subtitle":"Локальная модель","systemImage":"viewfinder","bytes":%d},' "$(( siglip_kb * 1024 ))"
  printf '{"id":"models.huggingface","title":"Hugging Face","subtitle":"Кэш моделей","systemImage":"face.smiling","bytes":%d}]},' "$(( huggingface_kb * 1024 ))"

  printf '{"id":"claudeVM","title":"Claude VM","subtitle":"Состояние Cowork и инструменты VM","systemImage":"externaldrive.fill","bytes":%d,"defaultSelected":false,"items":[' "$(( vm_kb * 1024 ))"
  printf '{"id":"claudeVM.rootfs","title":"rootfs.img","subtitle":"Диск виртуальной машины","systemImage":"internaldrive.fill","bytes":%d},' "$(( rootfs_kb * 1024 ))"
  printf '{"id":"claudeVM.other","title":"Остальные данные","subtitle":"Конфигурация и служебные файлы VM","systemImage":"doc.on.doc.fill","bytes":%d}]}' "$(( vm_other_kb * 1024 ))"
  printf '],"largeFiles":['
  while IFS='|' read -r large_kb encoded counted; do
    [[ -n "$large_kb" && -n "$encoded" ]] || continue
    (( first_large == 0 )) && printf ','
    printf '{"pathBase64":"%s","bytes":%d,"countedInCategories":%s}' "$encoded" "$(( large_kb * 1024 ))" "$counted"
    first_large=0
  done < "$scan_tmp/large"
  printf '],"installerFiles":['
  while IFS='|' read -r installer_kb encoded; do
    [[ -n "$installer_kb" && -n "$encoded" ]] || continue
    (( first_installer == 0 )) && printf ','
    printf '{"pathBase64":"%s","bytes":%d,"semanticGroup":"Установщики и архивы","countedInCategories":false}' "$encoded" "$(( installer_kb * 1024 ))"
    first_installer=0
  done < "$scan_tmp/installers"
  printf ']}\n'
}

confirm_clean() {
  local phrase="$1"
  print
  print "Для продолжения напишите: $phrase"
  read -r "?Подтверждение: " answer
  [[ "$answer" == "$phrase" ]]
}

clean_safe() {
  local assume_yes="${1:-no}"
  scan_array "Будут очищены эти кэши" "${SAFE_TARGETS[@]}"
  if [[ "$assume_yes" != "yes" ]] && ! confirm_clean "ОЧИСТИТЬ"; then
    print "Очистка отменена."
    return 0
  fi

  print "\nОчистка…"
  local entry label target_path guard
  for entry in "${SAFE_TARGETS[@]}"; do
    IFS='|' read -r label target_path guard <<< "$entry"
    remove_target "$label" "$target_path" "$guard"
  done

  # Remove only installer leftovers older than seven days. The active primary
  # runtime is preserved, and nothing is removed while Codex is running.
  local stale
  if ! is_running "$HOME/.codex/packages/app-server-daemon"; then
    for stale in "$HOME/.cache/codex-runtimes"/codex-runtime-install-*; do
      [[ -d "$stale" ]] || continue
      if [[ -n "$(find "$stale" -maxdepth 0 -mtime +7 -print 2>/dev/null)" ]]; then
        remove_target "старая незавершённая установка Codex runtime" "$stale" ""
      fi
    done
  else
    print "  ↷ Остатки установки Codex runtime пропущены: Codex запущен."
  fi

  log "SAFE CLEAN completed"
  print "\nГотово. Журнал: $LOG_FILE"
  df -h /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print "Свободно на SSD теперь: "$4}'
}

clean_old_codex_releases() {
  local root="$HOME/.codex/packages/app-server-daemon/releases"
  [[ -d "$root" ]] || { print "Версии Codex не найдены."; return 0; }
  if is_running "$HOME/.codex/packages/app-server-daemon"; then
    print "Codex сейчас запущен. Закройте его полностью и повторите расширенную очистку."
    return 0
  fi

  local latest
  latest=$(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -V | tail -1)
  [[ -n "$latest" ]] || return 0
  print "Сохраняется последняя версия: ${latest:t}"

  local dir
  for dir in "$root"/*; do
    [[ -d "$dir" && "$dir" != "$latest" ]] || continue
    remove_target "старая версия Codex ${dir:t}" "$dir" ""
  done
}

clean_pnpm() {
  local pnpm_bin candidate
  pnpm_bin=$(command -v pnpm 2>/dev/null || true)
  if [[ -z "$pnpm_bin" ]]; then
    for candidate in "$HOME/Library/pnpm/pnpm" "/opt/homebrew/bin/pnpm" "/usr/local/bin/pnpm"; do
      if [[ -x "$candidate" ]]; then pnpm_bin="$candidate"; break; fi
    done
  fi
  if [[ -n "$pnpm_bin" ]]; then
    print "\nОчистка неиспользуемых пакетов pnpm штатной командой…"
    if ! "$pnpm_bin" store prune; then
      print "  ! pnpm store prune завершился с ошибкой. Хранилище не удалялось вручную."
      return 1
    fi
    log "RUN pnpm store prune"
  else
    print "  ↷ pnpm не найден — хранилище не изменено."
  fi
}

clean_old_claude_versions() {
  local root="$HOME/Library/Application Support/Claude/claude-code"
  [[ -d "$root" ]] || return 0
  if is_running "Claude.app|/Claude/claude-code/"; then
    print "  ↷ Старые версии Claude Code пропущены: Claude запущен."
    return 0
  fi
  local latest dir
  latest=$(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -V | tail -1)
  [[ -n "$latest" ]] || return 0
  print "Сохраняется последняя версия Claude Code: ${latest:t}"
  for dir in "$root"/*; do
    [[ -d "$dir" && "$dir" != "$latest" ]] || continue
    remove_target "старая версия Claude Code ${dir:t}" "$dir" ""
  done
}

clean_old_vscode_extensions() {
  local root="$HOME/.vscode/extensions"
  [[ -d "$root" ]] || return 0
  if is_running "Visual Studio Code|Code Helper"; then
    print "  ↷ Старые расширения VS Code пропущены: VS Code запущен."
    return 0
  fi
  local extension latest dir
  local -a extension_ids
  extension_ids=("openai.chatgpt" "openai.codex-audio" "anthropic.claude-code" "google.geminicodeassist" "vue.volar")
  for extension in "${extension_ids[@]}"; do
    latest=$(find "$root" -mindepth 1 -maxdepth 1 -type d -name "$extension-*" -print 2>/dev/null | sort -V | tail -1)
    [[ -n "$latest" ]] || continue
    for dir in "$root"/$extension-*; do
      [[ -d "$dir" && "$dir" != "$latest" ]] || continue
      remove_target "старая версия расширения ${dir:t}" "$dir" ""
    done
  done
}

clean_application_caches() {
  local assume_yes="${1:-no}"
  local -a telegram_entries
  local entry label target_path guard
  telegram_entries=("${(@f)$(telegram_targets)}")
  scan_application_caches
  print "\nWebStorage, User, workspaceStorage, History, globalStorage, Backups,"
  print "agent-host и Telegram postbox/db сохраняются."
  if [[ "$assume_yes" != "yes" ]] && ! confirm_clean "ОЧИСТИТЬ КЭШИ ПРИЛОЖЕНИЙ"; then
    print "Очистка приложений отменена."
    return 0
  fi
  for entry in "${CLAUDE_TARGETS[@]}" "${VSCODE_TARGETS[@]}" "${telegram_entries[@]}"; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r label target_path guard <<< "$entry"
    remove_target "$label" "$target_path" "$guard"
  done
  clean_old_claude_versions
  clean_old_vscode_extensions
  print "\nОчистка кэшей приложений завершена. Запущенные приложения были пропущены."
}

clean_claude_vm() {
  local assume_yes="${1:-no}"
  local vm="$HOME/Library/Application Support/Claude/vm_bundles/claudevm.bundle"
  [[ -d "$vm" ]] || { print "Claude VM не найдена."; return 0; }
  if is_running "Claude.app|/Claude/claude-code/"; then
    print "Claude запущен. Полностью закройте Claude перед удалением VM."
    return 0
  fi
  print "Claude VM занимает $(human_kb "$(size_kb "$vm")")."
  print "Будут потеряны установленные внутри VM инструменты и локальное состояние Cowork."
  print "Claude создаст или скачает VM заново при следующем использовании этой функции."
  if [[ "$assume_yes" != "yes" ]] && ! confirm_clean "УДАЛИТЬ CLAUDE VM"; then
    print "Claude VM сохранена."
    return 0
  fi
  remove_target "Claude VM" "$vm" ""
}

clean_optional_models() {
  local assume_yes="${1:-no}"
  scan_array "Будут удалены локальные копии моделей" "${OPTIONAL_MODEL_TARGETS[@]}"
  print "После этого приложения при необходимости скачают модели повторно."
  if [[ "$assume_yes" != "yes" ]] && ! confirm_clean "УДАЛИТЬ МОДЕЛИ"; then
    print "Модели оставлены."
    return 0
  fi
  local entry label target_path guard
  for entry in "${OPTIONAL_MODEL_TARGETS[@]}"; do
    IFS='|' read -r label target_path guard <<< "$entry"
    remove_target "$label" "$target_path" "$guard"
  done
}

clean_developer() {
  local assume_yes="${1:-no}"
  clean_safe "$assume_yes"
  print "\nРасширенная очистка удаляет старые версии Codex и запускает pnpm prune."
  print "История Codex и проектные node_modules сохраняются."
  if [[ "$assume_yes" != "yes" ]] && ! confirm_clean "РАСШИРЕННАЯ ОЧИСТКА"; then
    print "Расширенная часть отменена."
    return 0
  fi
  clean_old_codex_releases
  clean_pnpm || return $?
  print "\nРасширенная очистка завершена."
}

clean_all() {
  local assume_yes="${1:-no}"
  scan_system
  print "\nБудут очищены безопасные кэши, Telegram media/cache, Claude и VS Code."
  print "Модели ИИ и Claude VM в обычную очистку не входят."
  if [[ "$assume_yes" != "yes" ]] && ! confirm_clean "ОЧИСТИТЬ ВСЁ"; then
    print "Очистка отменена."
    return 0
  fi
  clean_safe yes
  clean_pnpm || return $?
  clean_application_caches yes
  print "\nПолная безопасная очистка завершена."
}

remove_entries() {
  local entry label target_path guard
  for entry in "$@"; do
    [[ -n "$entry" ]] || continue
    IFS='|' read -r label target_path guard <<< "$entry"
    remove_target "$label" "$target_path" "$guard"
  done
}

clean_blob_node() {
  local node_id="${1:-}"
  local -a telegram_entries
  local entry label target_path guard item_index

  case "$node_id" in
    applications)
      remove_target "Codex app cache" "$HOME/Library/Caches/Codex" "ChatGPT|Codex"
      remove_target "Yandex browser cache" "$HOME/Library/Caches/Yandex" "Yandex"
      remove_entries "${CLAUDE_TARGETS[@]}"
      clean_old_claude_versions
      remove_entries "${VSCODE_TARGETS[@]}"
      clean_old_vscode_extensions
      ;;
    applications.codex)
      remove_target "Codex app cache" "$HOME/Library/Caches/Codex" "ChatGPT|Codex"
      ;;
    applications.yandex)
      remove_target "Yandex browser cache" "$HOME/Library/Caches/Yandex" "Yandex"
      ;;
    applications.claude)
      remove_entries "${CLAUDE_TARGETS[@]}"
      clean_old_claude_versions
      ;;
    applications.vscode)
      remove_entries "${VSCODE_TARGETS[@]}"
      clean_old_vscode_extensions
      ;;
    telegram)
      telegram_entries=("${(@f)$(telegram_targets)}")
      remove_entries "${telegram_entries[@]}"
      ;;
    telegram.media.*|telegram.cache.*)
      telegram_entries=("${(@f)$(telegram_targets)}")
      item_index="${node_id##*.}"
      [[ "$item_index" == <-> ]] || { print "Некорректный ID Telegram."; return 2; }
      entry="${telegram_entries[$(( item_index + 1 ))]:-}"
      [[ -n "$entry" ]] || { print "Каталог Telegram больше не найден."; return 2; }
      IFS='|' read -r label target_path guard <<< "$entry"
      if [[ "$node_id" == telegram.media.* && "$label" != Telegram\ media* ]] || \
         [[ "$node_id" == telegram.cache.* && "$label" != Telegram\ application\ cache* ]]; then
        print "Состав Telegram изменился — запустите анализ ещё раз."
        return 2
      fi
      remove_target "$label" "$target_path" "$guard"
      ;;
    development)
      remove_target "npm package cache" "$HOME/.npm/_cacache" ""
      remove_target "temporary npx packages" "$HOME/.npm/_npx" ""
      remove_target "pip download cache" "$HOME/Library/Caches/pip" ""
      remove_target "uv package cache" "$HOME/.cache/uv" ""
      remove_target "Bun install cache" "$HOME/.bun/install/cache" ""
      clean_pnpm || return $?
      ;;
    development.npm)
      remove_target "npm package cache" "$HOME/.npm/_cacache" ""
      ;;
    development.npx)
      remove_target "temporary npx packages" "$HOME/.npm/_npx" ""
      ;;
    development.pip)
      remove_target "pip download cache" "$HOME/Library/Caches/pip" ""
      ;;
    development.uv)
      remove_target "uv package cache" "$HOME/.cache/uv" ""
      ;;
    development.pnpm)
      clean_pnpm || return $?
      ;;
    development.bun)
      remove_target "Bun install cache" "$HOME/.bun/install/cache" ""
      ;;
    xcode|xcode.derivedData)
      remove_target "Xcode DerivedData" "$HOME/Library/Developer/Xcode/DerivedData" "Xcode"
      ;;
    models)
      clean_optional_models yes
      ;;
    models.siglip)
      remove_target "downloaded SigLIP model cache" "$HOME/.cache/hub" ""
      ;;
    models.huggingface)
      remove_target "Hugging Face model cache" "$HOME/.cache/huggingface" ""
      ;;
    claudeVM)
      clean_claude_vm yes
      ;;
    *)
      print "Очистка неизвестного блоба заблокирована: $node_id"
      return 2
      ;;
  esac
  print "Очистка выбранного блоба завершена."
}

show_help() {
  print "Использование:"
  print "  $INVOCATION_NAME --scan          только показать размеры"
  print "  $INVOCATION_NAME --clean-safe    очистить безопасные кэши с подтверждением"
  print "  $INVOCATION_NAME --clean-safe --yes  автоматическая очистка безопасных кэшей"
  print "  $INVOCATION_NAME --clean-dev     кэши + старые версии Codex + pnpm prune"
  print "  $INVOCATION_NAME --clean-apps    Telegram/Claude/VS Code с подтверждением"
  print "  $INVOCATION_NAME --clean-claude-vm  отдельно удалить Claude VM"
  print "  $INVOCATION_NAME --clean-models  удалить повторно скачиваемые модели"
  print "  $INVOCATION_NAME --clean-node ID --yes  очистить только выбранный блоб"
  print "  $INVOCATION_NAME --clean-all     очистить все выбранные безопасные категории"
}

interactive_menu() {
  scan_system
  print "\nВыберите действие:"
  print "  1 — только анализ"
  print "  2 — очистить безопасные кэши"
  print "  3 — расширенная очистка разработчика"
  print "  4 — удалить повторно скачиваемые модели"
  print "  5 — очистить Telegram, Claude и VS Code"
  print "  6 — отдельно удалить Claude VM"
  print "  0 — выйти"
  read -r "?Номер: " choice
  case "$choice" in
    1|0) return 0 ;;
    2) clean_safe no ;;
    3) clean_developer ;;
    4) clean_optional_models ;;
    5) clean_application_caches ;;
    6) clean_claude_vm ;;
    *) print "Неизвестный вариант — ничего не изменено." ;;
  esac
}

case "${1:-}" in
  --scan) scan_system ;;
  --scan-json) scan_json ;;
  --clean-safe) clean_safe "$([[ "${2:-}" == "--yes" ]] && print yes || print no)" ;;
  --clean-dev) clean_developer "$([[ "${2:-}" == "--yes" ]] && print yes || print no)" ;;
  --clean-apps) clean_application_caches "$([[ "${2:-}" == "--yes" ]] && print yes || print no)" ;;
  --clean-claude-vm) clean_claude_vm "$([[ "${2:-}" == "--yes" ]] && print yes || print no)" ;;
  --clean-models) clean_optional_models "$([[ "${2:-}" == "--yes" ]] && print yes || print no)" ;;
  --clean-node) clean_blob_node "${2:-}" ;;
  --clean-all) clean_all "$([[ "${2:-}" == "--yes" ]] && print yes || print no)" ;;
  --help|-h) show_help ;;
  "") interactive_menu; pause_if_interactive ;;
  *) show_help; exit 2 ;;
esac

