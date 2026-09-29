#!/usr/bin/env bash
# ============================================================================
# nupkg-push.sh —— 按白名单筛选 nupkg 并推送到 NuGet feed（nupkg.yml 调用，也可本地跑）
#
# 用法：
#   nupkg-push.sh --packages <dir> --include-file config/nupkg.include.txt \
#                 --source https://lnuget.loongnix.cn/v3/index.json \
#                 --api-key <key> [--dry-run] [--overwrite] \
#                 [--label "lns23 / linux-loongarch64"] [--manifest <out.txt>]
#
# --overwrite：feed 上已有同 id+版本时**覆盖**它（默认跳过）。先照常推一次：服务端
#   允许覆盖就直接换掉，一步到位；服务端回 409 才删掉那一版再重推
#   （DELETE <publish>/<id>/<version>，用的是同一个 API key）。删也删不掉、推也推
#   不上，就作为**失败**报出来，不会像 --skip-duplicate 那样被吞成成功。
#   没打开这个开关时，已存在的版本一律跳过 —— 自动化那条链（自检全绿→上传）不传
#   --overwrite，避免把 feed 上已有的版本换掉。
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

PACKAGES="" INCLUDE="" SOURCE="" API_KEY="" LABEL="" MANIFEST="" DRY_RUN=false OVERWRITE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --packages)     PACKAGES=${2:-};   shift 2 ;;
    --include-file) INCLUDE=${2:-};    shift 2 ;;
    --source)       SOURCE=${2:-};     shift 2 ;;
    --api-key)      API_KEY=${2:-};    shift 2 ;;
    --label)        LABEL=${2:-};      shift 2 ;;
    --manifest)     MANIFEST=${2:-};   shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift ;;
    --overwrite)    OVERWRITE=true;    shift ;;
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
feed_base=""; publish_base=""
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  # 服务索引里公布的是 http://（实测），nginx 再 301 到 https；GET 跟跳转即可
  svc=$(curl -fsSL --max-time 30 "$SOURCE" 2>/dev/null)
  feed_base=$(printf '%s' "$svc" \
    | jq -r '.resources[]? | select(."@type" == "PackageBaseAddress/3.0.0") | ."@id"' 2>/dev/null \
    | head -1)
  feed_base=${feed_base%/}
  # --overwrite 要删版本：删除端点在服务索引的 PackagePublish/2.0.0（BaGet 就是
  # <host>/api/v2/package），不在 v3 里 —— 所以别自己拼，取索引里公布的
  publish_base=$(printf '%s' "$svc" \
    | jq -r '.resources[]? | select(."@type" | test("^PackagePublish/")) | ."@id"' 2>/dev/null \
    | head -1)
  publish_base=${publish_base%/}
fi
if [ -z "$feed_base" ]; then
  echo "::warning::nupkg-push: 读不到 $SOURCE 的 PackageBaseAddress（v3 服务索引？）——" \
       "只能按 dotnet 的退出码判断，已存在的包会被记成「成功」" >&2
fi
if [ "$OVERWRITE" = true ] && [ -z "$publish_base" ]; then
  echo "::warning::nupkg-push: 读不到 $SOURCE 的 PackagePublish 端点 —— --overwrite 删不了旧版本，" \
       "只能直接推，能不能覆盖由服务端决定" >&2
fi

# 0 = feed 上已有该 id+版本；1 = 没有；2 = 查不了（网络/工具缺失，按「没有」处理）
feed_has() {
  [ -n "$feed_base" ] || return 2
  local idl idx
  idl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  idx=$(curl -fsSL --max-time 30 "$feed_base/$idl/index.json" 2>/dev/null) || return 2
  printf '%s' "$idx" | jq -e --arg v "$2" '.versions | index($v)' >/dev/null 2>&1
}

# 删掉 feed 上的一版（--overwrite 用）。0 = 删掉了；1 = 服务端拒绝；2 = 没有端点/删不了
# 用 X-NuGet-ApiKey 头（NuGet 的删除协议），key 与推送用的是同一个。
delete_version() {
  [ -n "$publish_base" ] || return 2
  local idl code body
  idl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  body=$(mktemp)
  code=$(curl -sSL -o "$body" -w '%{http_code}' -X DELETE --max-time 60 \
           -H "X-NuGet-ApiKey: $API_KEY" "$publish_base/$idl/$2" 2>/dev/null) || code=000
  case "$code" in
    200|202|204) rm -f "$body"; return 0 ;;
    *)  local msg; msg=$(head -c 200 "$body" | "${REDACT[@]}" | tr '\n' ' ')
        echo "  服务端回 $code：${msg:-（无正文）}" >&2
        rm -f "$body"; return 1 ;;
  esac
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
echo "模式:     $([ "$DRY_RUN" = true ] && echo 'dry-run（只列不推）' || echo '真推')" \
     "$([ "$OVERWRITE" = true ] && echo '/ 覆盖已存在的版本' || echo '/ 已存在的版本跳过')"
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
ok=0; dup=0; failed=0; ovw=0; manifest_rows=()
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

  # feed 上已有同 id+版本：默认跳过；--overwrite 时才往下走（先照常推，被拒再删了重推）。
  # dry-run 也查，好让 dry-run 预告真实结果。
  exists=false
  feed_has "$id" "$ver" && exists=true

  if [ "$exists" = true ] && [ "$OVERWRITE" != true ]; then
    dup=$((dup+1))
    printf '  = %-70s %-24s %s（feed 上已有，跳过）\n' "$b" "$ver" "$size"
    manifest_rows+=("$id|$ver|$b|$size|$([ "$DRY_RUN" = true ] && echo 'dry-run(duplicate)' || echo duplicate)")
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    [ "$exists" = true ] && ovw=$((ovw+1))
    printf '  [dry-run] %-70s %-24s %s%s\n' "$b" "$ver" "$size" \
      "$([ "$exists" = true ] && echo '（已存在：--overwrite 会覆盖它）' || echo '')"
    manifest_rows+=("$id|$ver|$b|$size|dry-run$([ "$exists" = true ] && echo '(overwrite)')")
    continue
  fi

  # --overwrite：先照常推一次 —— 服务端允许覆盖（BaGet 的 AllowPackageOverwrites）
  # 就一步到位，feed 上不会出现「旧版删了、新版还没推上」的空窗；服务端回 409
  # 才删掉旧版、重推第二次。两条路都失败就按**失败**报出来，不再用
  # --skip-duplicate 把 409 吞成成功。
  push_args=( "$f" --source "$SOURCE" --api-key "$API_KEY" --timeout "$PUSH_TIMEOUT" )
  [ "$exists" = true ] || push_args+=( --skip-duplicate )

  verdict=""
  if dotnet nuget push "${push_args[@]}" > "$log" 2>&1; then
    :                                     # 退出码 0 也可能是「已存在被跳过」，最后统一看日志
  elif [ "$exists" = true ] && grep -qiE '409|conflict|already exists|duplicate' "$log"; then
    if delete_version "$id" "$ver"; then
      echo "  - 服务端拒绝直接覆盖，已删掉旧版本 $id $ver，重推一次"
      dotnet nuget push "${push_args[@]}" > "$log" 2>&1 || verdict=lost
    else
      verdict=refused
    fi
  else
    verdict=failed
  fi

  case "$verdict" in
    refused)
      failed=$((failed+1))
      echo "::error::nupkg-push: 覆盖失败 $b" >&2
      tail -6 "$log" | "${REDACT[@]}" | sed 's/^/      /' >&2
      echo "      ↑ 删不掉旧版本，服务端也拒绝覆盖（BaGet 要开 AllowPackageOverwrites，或删除行为是硬删）。" >&2
      echo "        要么让服务端允许覆盖/给 key 删除权限，要么改用新版本号" >&2
      manifest_rows+=("$id|$ver|$b|$size|FAILED(已存在,覆盖被拒)")
      continue ;;
    lost)
      failed=$((failed+1))
      echo "::error::nupkg-push: 覆盖失败 $b" >&2
      tail -6 "$log" | "${REDACT[@]}" | sed 's/^/      /' >&2
      echo "      ↑ 旧版本已经删掉了，这一版却没推上去 —— 赶紧补推" >&2
      manifest_rows+=("$id|$ver|$b|$size|FAILED(旧版已删,未推上)")
      continue ;;
    failed)
      # 查过 feed 说没有、日志却说「已存在」—— 期间被人推了，或索引没列全
      if [ "$exists" != true ] && grep -qiE 'already exists|409|conflict|duplicate' "$log"; then
        dup=$((dup+1))
        printf '  = %-70s %-24s %s（已存在，跳过）\n' "$b" "$ver" "$size"
        manifest_rows+=("$id|$ver|$b|$size|duplicate")
      else
        failed=$((failed+1))
        echo "::error::nupkg-push: 推送失败 $b" >&2
        tail -6 "$log" | "${REDACT[@]}" | sed 's/^/      /' >&2
        manifest_rows+=("$id|$ver|$b|$size|FAILED")
      fi
      continue ;;
  esac

  # 走到这里 = 推成功了。但退出码 0 也可能是 --skip-duplicate 把「已存在」跳过了
  # （实测：409 时它退出码仍是 0），所以成功路径也要看一眼输出。
  if grep -qiE 'already exists|skipped|409|conflict|duplicate' "$log"; then
    dup=$((dup+1))
    printf '  = %-70s %-24s %s（已存在，跳过）\n' "$b" "$ver" "$size"
    manifest_rows+=("$id|$ver|$b|$size|duplicate")
  else
    ok=$((ok+1))
    if [ "$exists" = true ]; then
      ovw=$((ovw+1))
      printf '  ↻ %-70s %-24s %s（覆盖）\n' "$b" "$ver" "$size"
      manifest_rows+=("$id|$ver|$b|$size|overwritten")
    else
      printf '  ✓ %-70s %-24s %s\n' "$b" "$ver" "$size"
      manifest_rows+=("$id|$ver|$b|$size|pushed")
    fi
  fi
done

echo
if [ "$DRY_RUN" = true ]; then
  echo "dry-run 结束：将推送 $(( ${#selected[@]} - dup )) 个包到 $SOURCE" \
       "$([ "$OVERWRITE" = true ] && echo "（其中 $ovw 个会覆盖已存在的版本）" \
                                 || echo "（另有 $dup 个 feed 上已有，会跳过）")"
else
  echo "推送结束：成功 $ok（其中覆盖 $ovw），已存在 $dup，失败 $failed（共 ${#selected[@]}）"
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
