#!/usr/bin/env bash
# ============================================================================
# nupkg-push.sh —— 按白名单筛选 nupkg 并推送到 NuGet feed（nupkg.yml 调用，也可本地跑）
#
# 用法：
#   nupkg-push.sh --packages <dir> --include-file config/nupkg.include.txt \
#                 --source https://lnuget.loongnix.cn/v3/index.json \
#                 --api-key <key> [--dry-run] [--label "lns23 / linux-loongarch64"] \
#                 [--manifest <out.txt>]
#
# 白名单语义（与 config/nupkg.include.txt 顶部注释一致）：
#   #  注释（支持行尾注释）；空行忽略
#   !  排除规则，优先级高于包含规则
#   其余为包含 glob，按「文件名」匹配（<包 id>.<版本>.nupkg）
#
# 「已存在」怎么判：**先查 feed 的版本索引**（PackageBaseAddress 的
# <id>/index.json），命中就跳过、不推。原因见下面 feed_has 处的注释 —— 靠
# dotnet 的退出码分类会把「已存在」记成「成功」。dry-run 也查（只读），所以
# dry-run 能预告真实的推送结果（会推哪些、哪些会被跳过）。
#
# 退出码：0 = 全部成功（含 dry-run、含全部已存在）；1 = 有包推送失败；2 = 参数或环境错误
# ============================================================================
set -uo pipefail

# 单个包的推送超时（秒）。dotnet nuget push 的 -t|--timeout，默认只有 300 秒，
# 大包（runtime/aspnetcore 上百 MB）跨境传到龙芯 feed 容易不够，放宽到 15 分钟。
PUSH_TIMEOUT=900

PACKAGES="" INCLUDE="" SOURCE="" API_KEY="" LABEL="" MANIFEST="" DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --packages)     PACKAGES=${2:-};   shift 2 ;;
    --include-file) INCLUDE=${2:-};    shift 2 ;;
    --source)       SOURCE=${2:-};     shift 2 ;;
    --api-key)      API_KEY=${2:-};    shift 2 ;;
    --label)        LABEL=${2:-};      shift 2 ;;
    --manifest)     MANIFEST=${2:-};   shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -d "$PACKAGES" ] || { echo "包目录不存在: $PACKAGES" >&2; exit 2; }
[ -f "$INCLUDE" ]  || { echo "白名单文件不存在: $INCLUDE" >&2; exit 2; }
[ -n "$SOURCE" ]   || { echo "缺 --source" >&2; exit 2; }
if [ "$DRY_RUN" != true ] && [ -z "$API_KEY" ]; then
  echo "非 dry-run 必须提供 --api-key" >&2; exit 2
fi

# 推送失败时会把 dotnet 的输出原样打出来（CI 里还会进 step summary），先把密钥抹掉。
# 密钥里可能有 . * | 之类的字符，逐个转义后再当 sed 的模式用。
if [ -n "$API_KEY" ]; then
  key_re=$(printf '%s' "$API_KEY" | sed 's/[][\.*^$\\/&|-]/\\&/g')
  REDACT=( sed "s|$key_re|***|g" )
else
  REDACT=( cat )
fi

# ------------------------------------------------------------ 读白名单 ----
excl=(); incl=()
while IFS= read -r line; do
  line=${line%$'\r'}                       # 容忍 CRLF
  line=$(printf '%s' "$line" | sed 's/[[:space:]]*#.*$//')   # 去掉行尾注释
  line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  [ -n "$line" ] || continue
  case "$line" in
    \!*) excl+=("${line#!}") ;;
    *)   incl+=("$line") ;;
  esac
done < "$INCLUDE"

if [ "${#incl[@]}" -eq 0 ]; then
  echo "白名单里没有任何包含规则: $INCLUDE" >&2; exit 2
fi

# 0 = 命中包含；1 = 被 ! 排除；2 = 都没命中
match_rule() {
  local name=$1 p
  for p in ${excl[@]+"${excl[@]}"}; do [[ $name == $p ]] && return 1; done
  for p in "${incl[@]}"; do [[ $name == $p ]] && return 0; done
  return 2
}

# ------------------------------------------- 从 nuspec 读 id / version ----
# 失败时退回文件名（去掉 .nupkg 后缀），用于报告里的可读性
pkg_meta() {
  local f=$1 id="" ver=""
  if command -v unzip >/dev/null 2>&1; then
    local ns
    ns=$(unzip -p "$f" '*.nuspec' 2>/dev/null | head -c 8192)
    id=$(printf '%s'  "$ns" | grep -oE '<id>[^<]+</id>'         | head -1 | sed 's/<[^>]*>//g')
    ver=$(printf '%s' "$ns" | grep -oE '<version>[^<]+</version>' | head -1 | sed 's/<[^>]*>//g')
  fi
  [ -n "$id" ] || id=$(basename "$f" .nupkg)
  printf '%s\t%s' "$id" "${ver:-?}"
}

# ------------------------------------------------- feed 上有没有这个版本 ----
# 为什么不用 `dotnet nuget push --skip-duplicate` 的退出码判断：**已存在时它退出码
# 还是 0**（只打一条 warning），按退出码分类会把「已存在」全记成「成功」——
# 2026-09-29 的 run 36563546210 就报了「成功 9，已存在 0」，而 9 个包在 feed 上
# 本来就都有（BaGet 对已存在的 id+版本回 409），feed 上什么都没变。
# 所以先自己问 feed：版本索引是权威的，顺带省掉白传的几十 MB。
feed_base=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # 服务索引里公布的是 http://（实测），nginx 再 301 到 https；GET 跟跳转即可
  feed_base=$(curl -fsSL --max-time 30 "$SOURCE" 2>/dev/null \
    | jq -r '.resources[]? | select(."@type" == "PackageBaseAddress/3.0.0") | ."@id"' 2>/dev/null \
    | head -1)
  feed_base=${feed_base%/}
fi
if [ -z "$feed_base" ]; then
  echo "::warning::nupkg-push: 读不到 $SOURCE 的 PackageBaseAddress（v3 服务索引？）——" \
       "只能按 dotnet 的退出码判断，已存在的包会被记成「成功」" >&2
fi

# 0 = feed 上已有该 id+版本；1 = 没有；2 = 查不了（网络/工具缺失，按「没有」处理）
feed_has() {
  [ -n "$feed_base" ] || return 2
  local idl idx
  idl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  idx=$(curl -fsSL --max-time 30 "$feed_base/$idl/index.json" 2>/dev/null) || return 2
  printf '%s' "$idx" | jq -e --arg v "$2" '.versions | index($v)' >/dev/null 2>&1
}

# ---------------------------------------------------------------- 筛选 ----
mapfile -t all < <(find "$PACKAGES" -type f -name '*.nupkg' | LC_ALL=C sort)
selected=(); excluded=(); unmatched=()

for f in ${all[@]+"${all[@]}"}; do
  b=${f##*/}
  match_rule "$b"; rc=$?
  case $rc in
    0) selected+=("$f") ;;
    1) excluded+=("$b") ;;
    *) unmatched+=("$b") ;;
  esac
done

echo "包目录:   $PACKAGES"
echo "白名单:   $INCLUDE（包含 ${#incl[@]} 条 / 排除 ${#excl[@]} 条）"
echo "feed:     $SOURCE"
echo "模式:     $([ "$DRY_RUN" = true ] && echo 'dry-run（只列不推）' || echo '真推')"
echo "匹配结果: 共 ${#all[@]} 个 nupkg —— 选中 ${#selected[@]}，显式排除 ${#excluded[@]}，未命中规则 ${#unmatched[@]}"
echo

if [ "${#excluded[@]}" -gt 0 ]; then
  echo "被 ! 规则排除（${#excluded[@]}）:"
  printf '  - %s\n' "${excluded[@]}" | head -40
fi
if [ "${#unmatched[@]}" -gt 0 ]; then
  echo "未命中任何包含规则（${#unmatched[@]}，不上传）:"
  printf '  - %s\n' "${unmatched[@]}" | head -40
fi
echo
if [ "${#selected[@]}" -eq 0 ]; then
  echo "没有选中任何包，无事可做。"
  exit 0
fi

# ---------------------------------------------------------------- 推送 ----
ok=0; dup=0; failed=0; manifest_rows=()
[ -n "$MANIFEST" ] && mkdir -p "$(dirname "$MANIFEST")"
log=$(mktemp); trap 'rm -f "${log:-}"' EXIT

for f in "${selected[@]}"; do
  b=${f##*/}
  meta=$(pkg_meta "$f")
  id=${meta%%$'\t'*}; ver=${meta##*$'\t'}
  size=$(du -h "$f" | cut -f1)

  # 文件名匹配上、但 nuspec 里的 id 不含 loongarch64 —— 名字反常，值得看一眼
  case "$id" in
    *loongarch64*) ;;
    *) echo "::warning::nupkg-push: $b 的 nuspec id 为 '$id'，不含 loongarch64（名字反常？）" >&2 ;;
  esac

  # feed 上已有同 id+版本：跳过（BaGet 不接受覆盖，推了也是 409 跳过）。
  # dry-run 也查，好让 dry-run 预告真实结果。
  if feed_has "$id" "$ver"; then
    dup=$((dup+1))
    printf '  = %-70s %-24s %s（feed 上已有，跳过）\n' "$b" "$ver" "$size"
    manifest_rows+=("$id|$ver|$b|$size|$([ "$DRY_RUN" = true ] && echo 'dry-run(duplicate)' || echo duplicate)")
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    printf '  [dry-run] %-70s %-24s %s\n' "$b" "$ver" "$size"
    manifest_rows+=("$id|$ver|$b|$size|dry-run")
    continue
  fi

  if dotnet nuget push "$f" --source "$SOURCE" --api-key "$API_KEY" \
       --skip-duplicate --timeout "$PUSH_TIMEOUT" > "$log" 2>&1; then
    # 查过 feed 说没有，dotnet 却报「已存在」—— 期间被人推了，或索引没列全。
    # 退出码 0 不代表推上去了，所以成功路径也要看一眼输出。
    if grep -qiE 'already exists|skipped|409|conflict|duplicate' "$log"; then
      dup=$((dup+1))
      printf '  = %-70s %-24s %s（已存在，跳过）\n' "$b" "$ver" "$size"
      manifest_rows+=("$id|$ver|$b|$size|duplicate")
    else
      ok=$((ok+1))
      printf '  ✓ %-70s %-24s %s\n' "$b" "$ver" "$size"
      manifest_rows+=("$id|$ver|$b|$size|pushed")
    fi
  elif grep -qiE 'already exists|409|conflict|duplicate' "$log"; then
    dup=$((dup+1))
    printf '  = %-70s %-24s %s（已存在，跳过）\n' "$b" "$ver" "$size"
    manifest_rows+=("$id|$ver|$b|$size|duplicate")
  else
    failed=$((failed+1))
    echo "::error::nupkg-push: 推送失败 $b" >&2
    tail -6 "$log" | "${REDACT[@]}" | sed 's/^/      /' >&2
    manifest_rows+=("$id|$ver|$b|$size|FAILED")
  fi
done

echo
if [ "$DRY_RUN" = true ]; then
  echo "dry-run 结束：将推送 $(( ${#selected[@]} - dup )) 个包到 $SOURCE（另有 $dup 个 feed 上已有，会跳过）"
else
  echo "推送结束：成功 $ok，已存在 $dup，失败 $failed（共 ${#selected[@]}）"
fi

if [ -n "$MANIFEST" ]; then
  {
    echo "# nupkg manifest — ${LABEL:-$PACKAGES}"
    echo "# feed: $SOURCE"
    echo "# 时间: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# 格式: id|version|文件|大小|结果"
    printf '%s\n' "${manifest_rows[@]}"
  } > "$MANIFEST"
  echo "清单已写入 $MANIFEST"
fi

[ "$failed" -eq 0 ]
