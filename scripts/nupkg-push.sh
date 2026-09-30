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
# 往哪推：--source 给的是 v3 服务索引（人读的），实际推送用索引里公布的 PackagePublish
#   端点**换成 https** 的那一个（见下面 push_source 的注释：公布的是 http://，新版
#   NuGet 会拒推还退出 0）。推完不信客户端的话，自己去 feed 上核一遍
#   （新推的查版本索引，覆盖的查注册索引里的 published 有没有变新）。
#   注意 CI 里 dotnet 用哪个 SDK 由镜像里最新那个决定，setup-dotnet 装的 8.0.x 不一定是
#   实际跑的那个 —— 头部会把客户端版本和推送目标一起打出来。
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

# 单个包的推送超时（秒）：**按体积算**，不用一个固定值。dotnet nuget push 的
# -t|--timeout 默认才 300 秒；而 GitHub 的 westus runner 往北京 feed 传实测只有
# 25–40 KB/s（2026-09-30）：10.6MB 用了 415 秒、26MB 用了 868 秒（固定的 900 秒
# 只差 32 秒就撞线）、31.5MB 按同速率要 ~910 秒。所以按「1MB 给 60 秒（≈17KB/s，
# 比实测慢一半也够）+ 300 秒余量」算；下限 900 秒（小包不必陪跑），上限 5400 秒
# （链路再差也别无限等 —— 超了就该失败，不要占着 job）。链路正常时这些数用不到。
PUSH_TIMEOUT_MIN=900 PUSH_TIMEOUT_MAX=5400
push_timeout() {          # $1 = 包的字节数
  local t=$(( $1 / 1048576 * 60 + 300 ))
  [ "$t" -lt "$PUSH_TIMEOUT_MIN" ] && t=$PUSH_TIMEOUT_MIN
  [ "$t" -gt "$PUSH_TIMEOUT_MAX" ] && t=$PUSH_TIMEOUT_MAX
  printf '%s' "$t"
}

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
feed_base=""; publish_base=""; reg_base=""
push_source=$SOURCE          # 索引读不到就用 --source 本身（下面能读到时会换成 https）
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
  # 真正往哪推：服务索引公布的发布端点 **换成 https** 后直接推过去，不走它公布的
  # http:// 那一条。原因（2026-09-29 实测，run 36566565170 那 9 个假成功的根因）：
  # 两个 feed 的索引都把 PackagePublish 公布成 http://，而 runner 上 `dotnet` 取的是
  # 镜像里最新的 SDK（10.0.x，setup-dotnet 装的 8.0.x 只是「也在」），新版 NuGet 有
  # HTTPS-everywhere：看到 http 发布端点**拒绝推送**，打一行 error 说"NuGet 需要
  # HTTPS 源"（还提到 allowInsecureConnections），然后**退出码 0**——退出码、日志里
  # 的关键字都看不出异常，9 个包就这么被记成了「覆盖成功」，feed 上一个字没动。
  # 换成 https 直连后，新旧客户端都真推：PUT https://<host>/api/v2/package/，没有了
  # 301 那一跳（老客户端本来能跟着 301 走，但 curl、新客户端在那一跳上的行为并不一致）。
  # 索引读不到（不是 v3、网络问题）时退回按 --source 推，与以前一样。
  case "$publish_base" in
    http://*)  push_source="https://${publish_base#http://}" ;;
    https://*) push_source=$publish_base ;;
  esac
  # 注册索引（published 在里面）—— 推送后校验覆盖有没有真的生效要用
  reg_base=$(printf '%s' "$svc" \
    | jq -r '.resources[]? | select(."@type" | test("^RegistrationsBaseUrl")) | ."@id"' 2>/dev/null \
    | head -1)
  reg_base=${reg_base%/}
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

# 某个 id+版本在**注册索引**里的 published 时间戳（读不到就输出空）。
# 用来校验「覆盖」到底生效没有：BaGet 覆盖一版会重写这一行，published 会变新
# （2026-09-29 在 lnuget 上实测：手工推的那两版时间变了）。为什么要校验 ——
# run 36566565170 里 dotnet 对 9 个包全报了成功（退出码 0、日志里也没有
# already exists/409），而 feed 上 9 个包的日期一个没动，等于什么都没干。
published_of() {
  [ -n "$reg_base" ] || return 0
  local idl idx
  idl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  idx=$(curl -fsSL --max-time 30 "$reg_base/$idl/index.json" 2>/dev/null) || return 0
  printf '%s' "$idx" \
    | jq -r --arg v "$2" '[.items[].items[] | select(.catalogEntry.version == $v) | .catalogEntry.published] | first // empty' 2>/dev/null
}

# 推完之后再问一次 feed —— dotnet 的退出码不算数（上面那次的 9 个包就全被骗了）。
# 覆盖：注册索引里的 published 得变新；新推：版本索引里得能查到这一版。
# 索引可能有缓存，所以给几次重试；拿不到基准（published_of 空）时放行，不当失败。
verify_pushed() {
  local id=$1 ver=$2 overwrite=$3 before=$4 now i
  for i in 1 2 3 4 5; do
    if [ "$overwrite" = true ]; then
      [ -n "$before" ] || return 0
      now=$(published_of "$id" "$ver")
      [ -n "$now" ] && [ "$now" != "$before" ] && return 0
    else
      feed_has "$id" "$ver" && return 0
    fi
    sleep 4
  done
  return 1
}

# feed 上这一版的 sha256 与本地文件是否一致：same / different / unknown。
# 只在「说成功但 published 没变」时用来补一句：内容到底对不对。
bytes_state() {
  [ -n "$feed_base" ] || { echo unknown; return; }
  local idl sth lth
  idl=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  sth=$(curl -fsSL --max-time 600 "$feed_base/$idl/$3/$idl.$3.nupkg" 2>/dev/null \
        | sha256sum | cut -d' ' -f1) || { echo unknown; return; }
  lth=$(sha256sum "$1" | cut -d' ' -f1)
  if [ -z "$sth" ]; then echo unknown
  elif [ "$sth" = "$lth" ]; then echo same
  else echo different
  fi
}

# 日志里已知的「假成功」签名，认出来就直接点名（退出码会骗人，关键字才是最可靠的线索）。
explain_log() {
  if grep -qiE 'allowInsecureConnections|HTTPS source|需要 HTTPS|https-everywhere' "$log"; then
    echo "      ↑ 客户端拒绝往 http:// 的发布端点推（新版 NuGet 的 HTTPS-everywhere：要么用 https，要么" >&2
    echo "        在 NuGet.Config 里显式 allowInsecureConnections=true）—— 而且它**退出码是 0**，" >&2
    echo "        所以「dotnet 报了成功」就是它。本次推送目标：$push_source" >&2
    return 0
  fi
  return 1
}

# 删掉 feed 上的一版（--overwrite 用）。0 = 删掉了；1 = 服务端拒绝；2 = 没有端点/删不了
# 用 X-NuGet-ApiKey 头（NuGet 的删除协议），key 与推送用的是同一个。
delete_version() {
  [ -n "$publish_base" ] || return 2
  local idl code body del_base
  # 和推送一样换成 https 直连，省掉 http->https 那一跳
  del_base=${publish_base/http:/https:}
  idl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  body=$(mktemp)
  code=$(curl -sSL -o "$body" -w '%{http_code}' -X DELETE --max-time 60 \
           -H "X-NuGet-ApiKey: $API_KEY" "$del_base/$idl/$2" 2>/dev/null) || code=000
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
echo "发布端点: ${publish_base:-<没读到>}    # 服务索引公布的那个；注意可能是 http://"
echo "推送目标: $push_source    # 实际用的（发布端点换 https；读不到索引时才是 --source）"
echo "客户端:   $(dotnet --version 2>/dev/null || echo '<PATH 里没有 dotnet>')    # 多 SDK 时 dotnet 取最新的那个"
echo "模式:     $([ "$DRY_RUN" = true ] && echo 'dry-run（只列不推）' || echo '真推')" \
     "$([ "$OVERWRITE" = true ] && echo '/ 覆盖已存在的版本' || echo '/ 已存在的版本跳过')"
echo "匹配结果: 共 ${#all[@]} 个 nupkg —— 选中 ${#selected[@]}，显式排除 ${#excluded[@]}，未命中规则 ${#unmatched[@]}"
echo

# 只打印前 40 行：用数组切片，不用 `| head -40` —— 后者在 printf 还没写完时就把
# 管道关掉，会打一行「printf: write error: Broken pipe」的假报错（PSA 解出来几百个
# 包，未命中的那几百行必然触发）。
if [ "${#excluded[@]}" -gt 0 ]; then
  echo "被 ! 规则排除（${#excluded[@]}）:"
  printf '  - %s\n' "${excluded[@]:0:40}"
  [ "${#excluded[@]}" -gt 40 ] && echo "  …（还有 $(( ${#excluded[@]} - 40 )) 个）"
fi
if [ "${#unmatched[@]}" -gt 0 ]; then
  echo "未命中任何包含规则（${#unmatched[@]}，不上传）:"
  printf '  - %s\n' "${unmatched[@]:0:40}"
  [ "${#unmatched[@]}" -gt 40 ] && echo "  …（还有 $(( ${#unmatched[@]} - 40 )) 个）"
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
  # 覆盖前先记下 feed 上这一版的发布时间，推完对比 —— 客户端说成功不作数
  before=""
  [ "$exists" = true ] && before=$(published_of "$id" "$ver")

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
  push_args=( "$f" --source "$push_source" --api-key "$API_KEY"
              --timeout "$(push_timeout "$(stat -c %s "$f")")" )
  [ "$exists" = true ] || push_args+=( --skip-duplicate )

  verdict=""
  # 客户端输出直接进日志（tee 同时留一份给下面判定，密钥先抹掉）——退出码会骗人，
  # 它到底干了什么只有看它说了什么才知道（见 published_of 的注释）
  if dotnet nuget push "${push_args[@]}" 2>&1 | "${REDACT[@]}" | tee "$log"; then
    :                                     # 退出码 0 也可能是「已存在被跳过」，最后统一看日志
  elif [ "$exists" = true ] && grep -qiE '409|conflict|already exists|duplicate' "$log"; then
    if delete_version "$id" "$ver"; then
      echo "  - 服务端拒绝直接覆盖，已删掉旧版本 $id $ver，重推一次"
      dotnet nuget push "${push_args[@]}" 2>&1 | "${REDACT[@]}" | tee "$log" || verdict=lost
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
      echo "      ↑ 删不掉旧版本，服务端也拒绝覆盖（BaGet 要开 AllowPackageOverwrites，或删除行为是硬删）。" >&2
      echo "        要么让服务端允许覆盖/给 key 删除权限，要么改用新版本号" >&2
      manifest_rows+=("$id|$ver|$b|$size|FAILED(已存在,覆盖被拒)")
      continue ;;
    lost)
      failed=$((failed+1))
      echo "::error::nupkg-push: 覆盖失败 $b" >&2
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
        explain_log || true
        manifest_rows+=("$id|$ver|$b|$size|FAILED")
      fi
      continue ;;
  esac

  # 走到这里 = dotnet 报成功了。两件事都要查：
  #   1) 退出码 0 也可能是 --skip-duplicate 把「已存在」跳过了（实测：409 时它退出码仍是 0）
  #   2) 就算日志里没有「已存在」，也不代表真传上去了 —— 见 published_of 的注释，
  #      所以推完还要问一次 feed：覆盖的看 published 变没变，新推的看版本在不在。
  if grep -qiE 'already exists|skipped|409|conflict|duplicate' "$log"; then
    dup=$((dup+1))
    printf '  = %-70s %-24s %s（已存在，跳过）\n' "$b" "$ver" "$size"
    manifest_rows+=("$id|$ver|$b|$size|duplicate")
  elif verify_pushed "$id" "$ver" "$exists" "$before"; then
    ok=$((ok+1))
    if [ "$exists" = true ]; then
      ovw=$((ovw+1))
      printf '  ↻ %-70s %-24s %s（覆盖）\n' "$b" "$ver" "$size"
      manifest_rows+=("$id|$ver|$b|$size|overwritten")
    else
      printf '  ✓ %-70s %-24s %s\n' "$b" "$ver" "$size"
      manifest_rows+=("$id|$ver|$b|$size|pushed")
    fi
  else
    failed=$((failed+1))
    echo "::error::nupkg-push: $b 没有真的传上去（dotnet 报了成功）" >&2
    explain_log || true
    if [ "$exists" = true ]; then
      echo "      ↑ feed 上 $id $ver 的 published 没变 —— 它多半一个字节都没传。" >&2
      echo "        推送目标是 $push_source。索引公布的发布端点是 http:// 时，新版客户端" >&2
      echo "        （镜像里那个 10.x SDK）会拒推却仍退出 0；本次已换成 https 直连，" >&2
      echo "        再出现这句就说明索引没读到、退回按 --source 推了。" >&2
      case "$(bytes_state "$f" "$id" "$ver")" in
        same)      echo "        feed 上那份的 sha256 与本地一致 —— 内容是对的，只是没有重传。" >&2 ;;
        different) echo "        而且 feed 上那份的 sha256 与本地**不一致** —— 上面还是旧包，必须重传。" >&2 ;;
        *)         echo "        （没能取回 feed 上那份来比对 sha256）" >&2 ;;
      esac
      manifest_rows+=("$id|$ver|$b|$size|FAILED(说成功但feed没变)")
    else
      echo "      ↑ 版本索引里查不到 $id $ver —— 这个包没传上去" >&2
      manifest_rows+=("$id|$ver|$b|$size|FAILED(说成功但feed上查不到)")
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
