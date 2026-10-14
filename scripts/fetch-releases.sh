#!/usr/bin/env bash
# ============================================================================
# fetch-releases.sh —— 把 config/targets.json 里 enabled 的发布产物拉到本地
#
# 对象是 GitHub Release 里 build.yml 发出去的资产（默认只取 SDK tar.gz，--all 时连
# Private.SourceBuilt.Artifacts.* 一起）。tag 不在配置表里直接写着，按与 build.yml 的
# prepare、selfcheck.yml 的 plan 逐字相同的规则从 ref + abi 推导：
#   sdk_version = ref 去掉 "v" 前缀与 "-abiX.0" 后缀（条目里显式写了就用显式的）
#   release_tag = v<sdk_version>-<abi>（同上）
# 注意 ref 是 chenguohui/dotnet 里的分支/tag，**不是** Release tag —— 两者偶尔同名
# 是巧合，别拿 ref 当 tag 用。
#
# 用法：
#   fetch-releases.sh [--out <dir>] [--repo owner/repo] [--config <path>]
#                     [--group net9|net10|net11] [--tag <tag>]... [--all]
#                     [--jobs N] [--progress|--no-progress] [--dry-run] [--force]
#                     [--no-verify]
#
#   --out      下载根目录（默认 ./dl）；每个 Release 一个子目录 <out>/<tag>/
#   --repo     目标仓库，默认让 gh 自己从 git remote 认（在仓库里跑就是 origin）
#   --config   配置表路径（默认 config/targets.json，相对 cwd）；给了 --tag 就不读它
#   --group    只下该组（net9 / net10 / net11，同 workflow_dispatch 的 target 输入）
#   --tag      只下这些 tag（可重复）。给的是任意 tag，不查配置表 —— 补历史版本用
#   --all      连 Private.SourceBuilt.Artifacts.* 一起下（默认只下 dotnet-sdk-*.tar.gz）
#   --jobs     同时下几个文件（默认 3）—— 同一个 Release 里的多个文件因此能并行
#   --progress 进度块：默认只在 stderr 是终端时开；--no-progress 强制关掉
#   --dry-run  只列计划（每个资产多大、本地齐不齐），不下载（只比字节数，不算 sha256）
#   --force    本地已完整也重下（默认跳过完整的，只补缺的）
#   --no-verify 下完只比字节数，不算 sha256（快；但「大小对、内容错」就看不出来了）
#
# 传输用 curl（gh 只负责查资产清单和 tag）：gh release download 既没有进度条也不支持
# 续传，而这条链路（GitHub → 本地）实测只有 ~12 KB/s 且会断，167MB 起步的资产必须能
# 接着下。curl 的 -C - 从已有文件的末尾继续，重跑一次就多下一点，直到补齐。
# 代理认环境变量（https_proxy / http_proxy）：要过代理就 export 好再跑，gh 同理。
#
# 进度块：一个每秒刷新的渲染子进程，读父进程原子重写的 $WORK/pool.state，自己 stat
# 目标文件算百分比 / 速度 / ETA —— 不解析 curl 的输出，看到的就是真实落盘字节。
# 非终端（CI、重定向）不画块，只留每个文件一行 ✅ / ❌。
#
# 每个 Release 一个子目录是必须的：abi1.0 与 abi2.0 的资产**同名**（两个 Release 里
# 都有 dotnet-sdk-9.0.122-linux-loongarch64.tar.gz），共用一个目录会互相覆盖。
# 同一个 Release 内 lns23 / alpine 靠 RID 区分（linux-loongarch64 /
# linux-musl-loongarch64），不重名。
#
# 下完两道核对，两道都过才算「完整且正确」：
#   1. 字节数 = Release 登记的大小（便宜，先做；也是续传的兜底 —— 续歪了尺寸就不对）
#   2. sha256 = Release 给这个资产登记的摘要（API 的 digest 字段，上传时 GitHub 算的），
#      所以串包、代理改包、存心塞的坏包也拦得住 —— 只比大小是拦不住的
# 核对覆盖**所有**该有的资产，包括本轮没下、本地早就齐了的那些：尺寸对不代表内容对。
# 过不了的文件会被**删掉**（尺寸对、内容错的包比缺文件更危险：下次重跑会当它已完整而
# 跳过，坏包就永远躺在那儿），同时标 ❌ 并给 ::error::，重跑即重下。
# 摘要走 gh api（gh release view --json 到 2.45 都还不带 digest）。早期上传、没登记
# 摘要的资产会退回只比字节数，并在总表里明确标 ⚠️ —— 不假装验过。
#
# 退出码：0 = 应有尽有、字节数都对、登记的 sha256 也都对（含 --dry-run）；
#         1 = 有缺失/截断/内容不符/读不到；
#         2 = 参数或环境错误（缺 gh/jq/curl/sha256sum、gh 未登录、配置表读不到、
#             --out 不可写）
#
# 依赖：bash 5.1+（并发回收要用 wait -n -p）、gh、jq、curl、stat、sha256sum、
#       tput（可选，画进度块时量终端宽度用）
# ============================================================================
set -uo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ] ||
   { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "需要 bash 5.1+（当前 ${BASH_VERSION}）—— 并发回收用的 wait -n -p 从那时才有" >&2
  exit 2
fi

OUT=./dl REPO="" CONFIG=config/targets.json GROUP="" ALL=false JOBS=3
DRY_RUN=false FORCE=false VERIFY=true PROGRESS=auto
TAGS_OPT=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)         OUT=${2:-};           shift 2 ;;
    --repo)        REPO=${2:-};          shift 2 ;;
    --config)      CONFIG=${2:-};        shift 2 ;;
    --group)       GROUP=${2:-};         shift 2 ;;
    --tag)         TAGS_OPT+=("${2:-}"); shift 2 ;;
    --jobs)        JOBS=${2:-};          shift 2 ;;
    --all)         ALL=true;             shift ;;
    --progress)    PROGRESS=true;        shift ;;
    --no-progress) PROGRESS=false;       shift ;;
    --dry-run)     DRY_RUN=true;         shift ;;
    --force)       FORCE=true;           shift ;;
    --no-verify)   VERIFY=false;         shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$OUT" ] || { echo "缺参数: --out" >&2; exit 2; }
case "$JOBS" in ''|*[!0-9]*) echo "--jobs 需要正整数: $JOBS" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "--jobs 需要 ≥ 1" >&2; exit 2; }
TOOLS=( gh jq curl stat ); [ "$VERIFY" = true ] && TOOLS+=( sha256sum )
for t in "${TOOLS[@]}"; do
  command -v "$t" >/dev/null || { echo "缺少工具: $t" >&2; exit 2; }
done
gh auth status >/dev/null 2>&1 \
  || { echo "gh 未登录 —— 先 gh auth login（CI 里给 GH_TOKEN 也行）" >&2; exit 2; }

# 资产清单走 gh api：要一并拿到 digest（sha256），而 gh release view --json 到 2.45
# 都还不吐这个字段。--repo 给空时用 {owner}/{repo} 占位符，让 gh 从 git remote 认仓库
# （CI 里靠 GITHUB_REPOSITORY）—— 与之前 -R 的认法一致。per_page 给足，免得资产多时被分页截掉。
api_path() {   # $1 = tag
  if [ -n "$REPO" ]; then
    printf 'repos/%s/releases/tags/%s?per_page=100' "$REPO" "$1"
  else
    printf 'repos/{owner}/{repo}/releases/tags/%s?per_page=100' "$1"
  fi
}

# 进度块：默认「stderr 是终端才画」，免得把 CI 日志和重定向输出塞满转义序列
case "$PROGRESS" in
  auto)  if [ -t 2 ]; then USE_RENDERER=true; else USE_RENDERER=false; fi ;;
  true)  USE_RENDERER=true ;;
  false) USE_RENDERER=false ;;
esac

# ---------------------------------------------------------------- 定标签 ----
# 默认从配置表现推；显式 --tag 时以给到的为准（那条路不读配置表，补历史版本要用）
tags=()
if [ "${#TAGS_OPT[@]}" -gt 0 ]; then
  [ -z "$GROUP" ] || { echo "--group 与 --tag 不能同用" >&2; exit 2; }
  tags=("${TAGS_OPT[@]}")
else
  [ -f "$CONFIG" ] || { echo "读不到配置表: $CONFIG" >&2; exit 2; }
  derived=$(jq -r --arg g "$GROUP" '
    .targets[]
    | select(.enabled)
    | select(($g == "") or (.group == $g))
    | (.sdk_version // (.ref | sub("^v"; "") | sub("-abi[12]\\.0$"; ""))) as $v
    | (.release_tag // ("v" + $v + "-" + .abi))
  ' "$CONFIG") || { echo "解析配置表失败: $CONFIG" >&2; exit 2; }
  mapfile -t tags < <(printf '%s\n' "$derived" | grep . | LC_ALL=C sort -u)
  if [ "${#tags[@]}" -eq 0 ]; then
    echo "配置表里没有符合条件的条目（enabled${GROUP:+ 且 group=$GROUP}）" >&2; exit 2
  fi
fi

mkdir -p "$OUT" 2>/dev/null || { echo "建不了下载目录: $OUT" >&2; exit 2; }
[ -w "$OUT" ] || { echo "下载目录不可写: $OUT" >&2; exit 2; }
OUT=$(cd "$OUT" && pwd)   # 换成绝对路径：下载在子进程里跑，绝对路径省心

WORK=$(mktemp -d /tmp/fetch-releases.XXXXXX) || { echo "建不了临时目录" >&2; exit 2; }
RENDER_PID=""
cleanup() {
  [ -n "$RENDER_PID" ] && kill "$RENDER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------ 小工具 ----
note()  { printf '[%s] %s\n' "$1" "$2" >&2; }
human() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1073741824)    printf "%.1f GiB", b/1073741824
    else if (b >= 1048576)  printf "%.0f MiB", b/1048576
    else                    printf "%.0f KiB", b/1024 }'
}
rate() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1048576) printf "%.1f MiB/s", b/1048576
    else              printf "%.0f KiB/s", b/1024 }'
}
fmt_dur() {
  local s=${1:-0}
  if   [ "$s" -ge 3600 ]; then printf '%dh%02dm' $((s/3600)) $((s%3600/60))
  elif [ "$s" -ge 60 ];   then printf '%dm%02ds' $((s/60))   $((s%60))
  else                         printf '%ds' "$s"
  fi
}

# 一遍下不完就再起一遍：-C - 每次重新读文件大小，续传起点不会错位（curl 自己的
# --retry 是在一次请求里重试，起点未必重算，所以这里宁可自己循环）；退避 5/10/15/20 秒。
# --speed-limit/--speed-time 掐掉「连上了但一点数据都不动」的死连接（实测遇到过一次）。
CURL=( curl -fL -sS -C - --connect-timeout 20 --speed-limit 1024 --speed-time 60 )
CURL_TRIES=5

# ------------------------------------------------------------------ 计划 ----
QUEUE=() PLANNED=()

plan_tag() {   # $1 = tag；把资产清单写成 $WORK/<tag>.assets，要下的追加进 QUEUE
  local tag=$1
  local dir="$OUT/$tag" assetsf="$WORK/$tag.assets" errf="$WORK/$tag.err"
  local size name url digest got line
  : > "$assetsf"
  if ! mkdir -p "$dir"; then
    note "$tag" "❌ 建不了目录 $dir"; return 1
  fi

  local assets
  if ! assets=$(gh api "$(api_path "$tag")" \
                  --jq '.assets[] | [.size, .name, .browser_download_url, (.digest // "")] | @tsv' \
                  2>"$errf"); then
    note "$tag" "❌ 读不到该 Release —— $(head -n1 "$errf" 2>/dev/null)"
    return 1
  fi

  # 认哪些资产：默认只认 SDK（后缀判据与 selfcheck.yml 一致），--all 才连 PSA 一起
  local n=0
  while IFS=$'\t' read -r size name url digest; do
    [ -n "$name" ] || continue
    if [ "$ALL" != true ]; then
      case "$name" in dotnet-sdk-*.tar.gz) ;; *) continue ;; esac
    fi
    printf '%s\t%s\t%s\t%s\n' "$size" "$name" "$url" "$digest" >> "$assetsf"
    n=$((n+1))
  done <<< "$assets"

  if [ "$n" -eq 0 ]; then
    note "$tag" "❌ Release 里没有$([ "$ALL" = true ] && echo "资产" || echo " dotnet-sdk-*.tar.gz")"
    return 1
  fi

  # 本地字节数对得上的不进队列（重跑只补缺的、不陪跑已完整的）
  local need_n=0 need_bytes=0
  while IFS=$'\t' read -r size name url digest; do
    got=0; [ -f "$dir/$name" ] && got=$(stat -c%s "$dir/$name" 2>/dev/null || echo 0)
    # 尺寸对就先不下；内容对不对由后面的 sha256 核对判 —— 判不过会把文件删掉，重跑再下
    if [ "$FORCE" != true ] && [ "$got" = "$size" ]; then continue; fi
    [ "${got:-0}" -gt 0 ] && note "$tag" "… $name 本地 $(human "$got") / 登记 $(human "$size")"
    need_n=$((need_n+1)); need_bytes=$((need_bytes+size))
    [ "$DRY_RUN" = true ] || QUEUE+=( "$tag"$'\t'"$name"$'\t'"$size"$'\t'"$url"$'\t'"$dir" )
  done < "$assetsf"

  if [ "$need_n" -eq 0 ]; then
    note "$tag" "本地已完整，跳过"
  elif [ "$DRY_RUN" = true ]; then
    note "$tag" "dry-run：要下 $need_n 个 / $(human "$need_bytes")"
  else
    note "$tag" "要下 $need_n 个 / $(human "$need_bytes")"
  fi
  return 0
}

# ------------------------------------------------------------- 进度渲染 ----
# 渲染在子进程里跑：每秒擦掉上一帧、打新的 ✅/❌ 永久行、再画状态块。
# 父进程只管把状态原子写进 $WORK/pool.state，两边不共享内存。
R_DRAWN=0
p_erase() {   # 擦掉上一帧，光标回到帧顶
  [ "$R_DRAWN" -gt 0 ] || return 0
  printf '\033[%dA' "$R_DRAWN" >&2
  local k
  for ((k=0; k<R_DRAWN; k++)); do printf '\033[2K\n' >&2; done
  printf '\033[%dA' "$R_DRAWN" >&2
  R_DRAWN=0
  return 0
}

p_frame() {   # $1 = 终端宽度
  [ -f "$WORK/pool.state" ] || return 0
  local cols=$1 now b pct filled elapsed eta speed k short
  local total_files total_bytes done_files done_bytes
  local name path size start
  local lines=()

  IFS=$'\t' read -r total_files total_bytes done_files done_bytes < "$WORK/pool.state" || return 0
  local w=$(( cols - 66 )); [ "$w" -lt 16 ] && w=16
  now=$(date +%s)

  while IFS=$'\t' read -r name path size start; do
    [ -n "$name" ] || continue
    b=$(stat -c%s "$path" 2>/dev/null || echo 0)
    if [ "${size:-0}" -gt 0 ]; then pct=$(( b * 100 / size )); else pct=100; fi

    filled=$(( pct * 10 / 100 )); local bar=""
    for ((k=0; k<10; k++)); do
      if [ "$k" -lt "$filled" ]; then bar+="#"; else bar+="-"; fi
    done

    elapsed=$(( now - ${start:-$now} )); [ "$elapsed" -le 0 ] && elapsed=1
    speed=$(( b / elapsed ))
    if [ "$speed" -gt 0 ]; then eta=$(fmt_dur $(( (size - b) / speed ))); else eta="--"; fi

    # 名字取尾部：变体 / RID 在末尾，截尾会认不出是哪一份
    if [ "${#name}" -gt "$w" ]; then short="…${name: -$((w-1))}"; else short=$name; fi
    lines+=( "$(printf '  %-*s [%s] %3d%% %s/%s %s 剩 %s' \
                "$w" "$short" "$bar" "$pct" "$(human "$b")" "$(human "$size")" \
                "$(rate "$speed")" "$eta")" )
  done < <(tail -n +2 "$WORK/pool.state" 2>/dev/null)

  p_erase
  printf '下载中 %d 个 · 已完成 %d/%d 个 · 合计 %s / %s\n' \
    "${#lines[@]}" "${done_files:-0}" "${total_files:-0}" \
    "$(human "${done_bytes:-0}")" "$(human "${total_bytes:-0}")" >&2
  [ "${#lines[@]}" -gt 0 ] && printf '%s\n' "${lines[@]}" >&2
  R_DRAWN=$(( ${#lines[@]} + 1 ))
  return 0
}

render_loop() {
  local cols printed=0 n
  cols=$(tput cols 2>/dev/null || echo "${COLUMNS:-100}")
  case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
  trap 'p_erase; exit 0' TERM INT
  while :; do
    # 新完成的永久行：先擦帧、打出来、下一轮再把帧画回去
    n=$(grep -c . "$WORK/finished" 2>/dev/null || true)
    if [ "${n:-0}" -gt "$printed" ]; then
      p_erase
      tail -n +"$((printed+1))" "$WORK/finished" >&2
      printed=$n
    fi
    p_frame "$cols"
    sleep 1
  done
}

# ------------------------------------------------------------------ 下载 ----
# 一个文件一个 curl；本地已有的部分由 -C - 接着写，对错交给核对阶段统一判。
download_one() {   # $1 tag  $2 name  $3 size  $4 url  $5 dir
  # 注意别写成一条 local：local 是先展开全部参数再赋值，行内引用 $name 会拿到旧值
  local tag=$1 name=$2 size=$3 url=$4 dir=$5
  local out="$dir/$name" errf="$WORK/err.$tag.$name"
  local got=0 rc=0 i=0

  [ -f "$out" ] && got=$(stat -c%s "$out" 2>/dev/null || echo 0)
  # 本地已经 >= 登记值：要么是坏的（比登记还大），要么是 --force 要重下的 —— 都得先删。
  # 不删的话 -C - 会对着已完整的文件要 Range，服务端回 416（--fail 下就是退出码 22）。
  [ "${got:-0}" -ge "${size:-0}" ] && rm -f "$out"

  while [ "$i" -lt "$CURL_TRIES" ]; do
    i=$((i+1))
    "${CURL[@]}" -o "$out" "$url" 2>"$errf" && return 0
    rc=$?
    # 22 = --fail 收到 4xx/5xx：404/403 这种重试也没用，早退早报错
    [ "$rc" -eq 22 ] && { note "$tag" "❌ $name —— $(head -n1 "$errf" 2>/dev/null)"; return 1; }
    [ "$i" -lt "$CURL_TRIES" ] && sleep $(( i * 5 ))
  done
  note "$tag" "❌ $name —— curl 退出码 $rc（$(head -n1 "$errf" 2>/dev/null)）"
  return 1
}

POOL_TOTAL=0 POOL_TOTAL_BYTES=0 POOL_OK=0 POOL_DONE_BYTES=0
declare -A ST=() J_T0=()

write_state() {   # 原子重写 pool.state，渲染进程永远读到完整的一份
  local tmp="$WORK/pool.state.tmp" k
  {
    printf '%s\t%s\t%s\t%s\n' "$POOL_TOTAL" "$POOL_TOTAL_BYTES" "$POOL_OK" "$POOL_DONE_BYTES"
    for k in ${ST[@]+"${!ST[@]}"}; do printf '%s\t%s\n' "${ST[$k]}" "${J_T0[$k]}"; done
  } > "$tmp" && mv -f "$tmp" "$WORK/pool.state"
}

run_pool() {
  local next=0 done=0 row jtag jname jsize jurl jdir pid fin rc dur jn jp js info
  POOL_TOTAL=${#QUEUE[@]}
  [ "$POOL_TOTAL" -gt 0 ] || return 0

  for row in "${QUEUE[@]}"; do
    IFS=$'\t' read -r jn jp jsize _ _ <<< "$row"
    POOL_TOTAL_BYTES=$(( POOL_TOTAL_BYTES + jsize ))
  done
  : > "$WORK/finished"
  if [ "$USE_RENDERER" = true ]; then render_loop & RENDER_PID=$!; fi

  while [ "$done" -lt "$POOL_TOTAL" ]; do
    # 起新任务，直到槽位占满 —— 同一个 Release 的多个文件此时就并行了
    while [ "${#ST[@]}" -lt "$JOBS" ] && [ "$next" -lt "$POOL_TOTAL" ]; do
      row="${QUEUE[$next]}"; next=$((next+1))
      IFS=$'\t' read -r jtag jname jsize jurl jdir <<< "$row"
      download_one "$jtag" "$jname" "$jsize" "$jurl" "$jdir" &
      pid=$!
      ST[$pid]="$jname"$'\t'"$jdir/$jname"$'\t'"$jsize"
      J_T0[$pid]=$(date +%s)
      write_state
    done

    [ "${#ST[@]}" -gt 0 ] || break
    fin="" rc=0
    wait -n -p fin "${!ST[@]}" || rc=$?

    info="${ST[$fin]:-}"; unset 'ST[$fin]'
    dur=$(( $(date +%s) - ${J_T0[$fin]:-$(date +%s)} )); unset 'J_T0[$fin]'
    IFS=$'\t' read -r jn jp js <<< "$info"
    done=$((done+1))

    if [ "$rc" -eq 0 ]; then
      printf '✅ %s  %s  %s\n' "$jn" "$(human "$js")" "$(fmt_dur "$dur")" >> "$WORK/finished"
      POOL_OK=$((POOL_OK+1)); POOL_DONE_BYTES=$((POOL_DONE_BYTES+js))
    else
      printf '❌ %s  %s\n' "$jn" "下载失败（重跑一次会接着下）" >> "$WORK/finished"
    fi
    write_state
  done

  if [ -n "$RENDER_PID" ]; then
    kill "$RENDER_PID" 2>/dev/null; wait "$RENDER_PID" 2>/dev/null; RENDER_PID=""
  fi
  # 没渲染进程时（非终端 / --no-progress）在这里补打永久行；有的话它已经打过了
  if [ "$USE_RENDERER" != true ]; then grep . "$WORK/finished" >&2 || true; fi
  return 0
}

# ------------------------------------------------------------------ 核对 ----
# 两道：字节数 = Release 登记值；sha256 = Release 登记的摘要。都过才算「完整且正确」。
# 这里覆盖的是**所有**该有的资产，包括本轮没下的那些 —— 尺寸对不代表内容对，早先下来的
# 坏包只能在这一步现形。
verify_tag() {   # $1 = tag
  local tag=$1
  local dir="$OUT/$tag" rowf="$WORK/$tag.rows" assetsf="$WORK/$tag.assets"
  local size name url digest got want sum bad=0 total=0 n=0
  : > "$rowf"
  while IFS=$'\t' read -r size name url digest; do
    [ -n "$name" ] || continue
    got=0; [ -f "$dir/$name" ] && got=$(stat -c%s "$dir/$name" 2>/dev/null || echo 0)
    total=$((total+size)); n=$((n+1))

    if [ "$got" != "$size" ]; then
      if [ "$DRY_RUN" = true ]; then
        printf 'plan\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"
      else
        bad=$((bad+1)); printf 'bad\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"
        echo "::error::fetch-releases(${tag}): ${name} 本地 ${got} 字节，登记 ${size} 字节" >&2
      fi
      continue
    fi

    # 尺寸先过。--dry-run 到此为止：算 sha256 要读完整份文件，那是下载时才值得付的代价
    if [ "$DRY_RUN" = true ]; then
      printf 'ok\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"; continue
    fi
    if [ "$VERIFY" != true ]; then
      printf 'oknover\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"; continue
    fi

    want=""
    case "$digest" in
      sha256:*) want=${digest#sha256:} ;;
      *) printf 'oksize\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"; continue ;;
    esac

    note "$tag" "… 校验 $name"
    sum=$(sha256sum -- "$dir/$name" 2>/dev/null | cut -d' ' -f1)
    if [ "$sum" = "$want" ]; then
      printf 'ok\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"
    else
      bad=$((bad+1)); printf 'badsum\t%s\t%s\t%s\n' "$name" "$got" "$size" >> "$rowf"
      # 删掉：留着的话下次重跑看尺寸会当它已完整而跳过，坏包就永远躺在那儿了
      rm -f "$dir/$name"
      echo "::error::fetch-releases(${tag}): ${name} sha256 ${sum:-算不出} ≠ 登记 ${want}（已删除，重跑会重下）" >&2
    fi
  done < "$assetsf"
  [ "$bad" -eq 0 ] || note "$tag" "❌ $bad/$n 个不完整"
  return 0
}

# ------------------------------------------------------------------ 跑 ----
for t in "${tags[@]}"; do
  plan_tag "$t" && PLANNED+=("$t")
done

run_pool

for t in "${PLANNED[@]}"; do verify_tag "$t"; done

# ------------------------------------------------------------------ 总表 ----
echo
echo "$([ "$DRY_RUN" = true ] && echo "计划" || echo "结果")："
n_ok=0 total_bytes=0 n_plan=0 plan_bytes=0 n_bad=0 n_sum=0 n_nover=0
for t in "${tags[@]}"; do
  rowf="$WORK/$t.rows"
  echo "$t"
  if [ ! -s "$rowf" ]; then
    echo "  ❌ 读不到这个 Release 的资产"; n_bad=$((n_bad+1)); continue
  fi
  while IFS=$'\t' read -r st name got want; do
    case "$st" in
      ok)     printf '  ✅ %-78s %s\n' "$name" "$(human "$got")"
              n_ok=$((n_ok+1)); total_bytes=$((total_bytes+got)) ;;
      oksize) printf '  ⚠️  %-78s %s（只核了字节数：Release 没登记 sha256）\n' "$name" "$(human "$got")"
              n_sum=$((n_sum+1)); n_ok=$((n_ok+1)); total_bytes=$((total_bytes+got)) ;;
      oknover) printf '  ⚠️  %-78s %s（--no-verify，只核了字节数）\n' "$name" "$(human "$got")"
              n_nover=$((n_nover+1)); n_ok=$((n_ok+1)); total_bytes=$((total_bytes+got)) ;;
      plan)   printf '  ⏳ %-78s %s（待下载）\n' "$name" "$(human "$want")"
              n_plan=$((n_plan+1)); plan_bytes=$((plan_bytes+want)) ;;
      bad)    printf '  ❌ %-78s 本地 %s / 登记 %s\n' "$name" "$(human "$got")" "$(human "$want")"
              n_bad=$((n_bad+1)) ;;
      badsum) printf '  ❌ %-78s sha256 与 Release 登记的不符（已删除）\n' "$name"
              n_bad=$((n_bad+1)) ;;
      *)      printf '  ❓ %s %s\n' "$st" "$name" ;;
    esac
  done < "$rowf"
done
echo

if [ "$n_bad" -gt 0 ]; then
  echo "❌ $n_bad 个资产缺失、截断或内容不符 —— 再跑一次接着下（已完整的会跳过）"
  exit 1
fi
if [ "$DRY_RUN" = true ]; then
  if [ "$n_plan" -gt 0 ]; then
    echo "⏳ ${n_plan} 个资产待下载（$(human "$plan_bytes")），本地已有 ${n_ok} 个（$(human "$total_bytes")）"
  else
    echo "✅ ${n_ok} 个资产本地都已完整（$(human "$total_bytes")，只比了字节数，没算 sha256）"
  fi
  exit 0
fi
msg="✅ ${n_ok} 个资产全部就位（$(human "$total_bytes")）"
[ "$n_sum"   -gt 0 ] && msg+="；其中 ${n_sum} 个 Release 没登记 sha256，只核了字节数"
[ "$n_nover" -gt 0 ] && msg+="；${n_nover} 个按 --no-verify 只核了字节数"
[ "$n_sum" -eq 0 ] && [ "$n_nover" -eq 0 ] && msg+="，sha256 与 Release 登记的摘要逐一核对一致"
echo "$msg"
exit 0
