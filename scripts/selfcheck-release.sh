#!/usr/bin/env bash
# ============================================================================
# selfcheck-release.sh —— 已发布 SDK 的事后体检（报告型）
#
# 与构建时的 scripts/selfcheck.sh 同一套判据，但对象是 **GitHub Release 里已经发出去
# 的资产**：那些产物在发布时没有检查过，先把数据摆出来看。所以本脚本默认不做门禁
# （有 ❌ 也不改退出码），要收紧时加 --strict。
# 在 x64 runner 上就能跑完：只依赖 readelf / file / du；analyzer 检查另需 --ildasm。
#
# 用法：
#   selfcheck-release.sh \
#     --sdk dotnet-sdk-11.0.100-rc.1.26425.128-linux-loongarch64.tar.gz \
#     --variant lns23 --abi abi2.0 --rid linux-loongarch64 \
#     --elf-flags 0x43 --glibcxx-max 3.4.30 --glibc-max 2.38 \
#     --ildasm /tmp/ildasm --tag v11.0.100-rc.1.26425.128-abi2.0 \
#     --out report.md --json row.json
#
# 参数：
#   --sdk          SDK tar.gz 路径（必填）
#   --variant      变体名（lns8/lns23/musl），用于报告（必填）
#   --abi          abi1.0 / abi2.0，用于报告（必填）
#   --rid          linux-loongarch64 / linux-musl-loongarch64（必填）—— 解释器检查的判据
#   --elf-flags    期望的 ELF e_flags（0x3 / 0x43，必填）—— config/targets.json 的 abis[].elf_flags
#   --glibcxx-max  该变体的 libstdc++ 符号版本上限（如 3.4.30）；空 = 不检查
#                  （musl 工具链不做符号版本化，产物里一个 GLIBCXX_ 符号都没有）
#   --glibc-max    该变体 sysroot 的 glibc 上限（如 2.38）；空 = 不检查
#   --ildasm       ildasm 可执行文件（x64 版，取自 NuGet 包
#                  runtime.linux-x64.Microsoft.NETCore.ILDAsm，runner 上不需要 dotnet）；
#                  缺省则跳过 analyzer 检查并记一条警告
#   --tag          Release tag，只写进 --json 的输出（汇总表用）
#   --out          报告写入路径（markdown）
#   --json         结果写入路径（紧凑单行 JSON）。汇总 job 用 jq -s 拼总表，所以这里
#                  不写 markdown —— 报告表格一改，解析就会碎
#   --strict       存在 ❌ 时退出码为 1；缺省「只报告」，退出码不受 ❌ 影响
#
# 退出码：0 = 检查跑完（缺省下即使有 ❌ 也是 0）；1 = --strict 且存在 ❌；
#         2 = 参数 / 环境错误，检查没能完成（资产不存在、解包失败、缺工具）
# ============================================================================
set -uo pipefail

SDK="" VARIANT="" ABI="" RID="" ABI_FLAGS="" GLIBCXX_MAX="" GLIBC_MAX=""
ILDASM="" TAG="" OUT="" JSON="" STRICT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)         SDK=${2:-};         shift 2 ;;
    --variant)     VARIANT=${2:-};     shift 2 ;;
    --abi)         ABI=${2:-};         shift 2 ;;
    --rid)         RID=${2:-};         shift 2 ;;
    --elf-flags)   ABI_FLAGS=${2:-};   shift 2 ;;
    --glibcxx-max) GLIBCXX_MAX=${2:-}; shift 2 ;;
    --glibc-max)   GLIBC_MAX=${2:-};   shift 2 ;;
    --ildasm)      ILDASM=${2:-};      shift 2 ;;
    --tag)         TAG=${2:-};         shift 2 ;;
    --out)         OUT=${2:-};         shift 2 ;;
    --json)        JSON=${2:-};        shift 2 ;;
    --strict)      STRICT=1;           shift ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

for v in SDK VARIANT ABI RID ABI_FLAGS; do
  [ -n "${!v}" ] || { echo "缺参数: $v" >&2; exit 2; }
done

# 必须固定为 C locale：readelf / file 的输出描述是本地化的，
# 中文 locale 下 readelf 打印「标志：」、file 打印中文描述，解析会全部失效。
export LC_ALL=C

for t in readelf file du tar find; do
  command -v "$t" >/dev/null || { echo "缺少工具: $t" >&2; exit 2; }
done

# ABI flag 统一小写比较（readelf 可能输出 0x43 / 0X43）
ABI_FLAGS=$(printf '%s' "$ABI_FLAGS" | tr 'A-Z' 'a-z')

# 解释器判据只看 libc 家族：glibc 变体不能出现 musl 解释器，反之亦然。
# 三个变体的实测值：lns23 /lib64/ld-linux-loongarch-lp64d.so.1、
# lns8 /lib64/ld.so.1（老世界）、musl /lib/ld-musl-loongarch64.so.1 ——
# 名字各不相同，所以只比「是不是 musl」，不去猜完整路径。
case "$RID" in
  *musl*) WANT_LIBC=musl ;;
  *)      WANT_LIBC=glibc ;;
esac

REPORT=$(mktemp); ROWS=$(mktemp); DETAIL=$(mktemp); FILELIST=$(mktemp); ANZ=$(mktemp)
OK_COUNT=0; BAD_COUNT=0; WARN_COUNT=0
# 落到 --json 里的测量值
M_ELF_FLAGS="" M_INTERP="" M_GLIBCXX="" M_GLIBC="" M_ANZ_VER="" M_ANZ_N=0
M_PE=0 M_PE32=0 M_UNSTRIPPED=0 M_TAR="" M_UNPACKED=""
BAD_ELF_FLAGS=false BAD_INTERP=false BAD_GLIBCXX=false BAD_GLIBC=false BAD_ANZ=false
BAD_FLAGS_CONSIST=false

say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
row()  { printf '%s\n' "$*" >> "$ROWS"; }
# detail <标题>：正文从 stdin 读，作为代码块收进报告末尾的「明细」
detail() {
  printf '\n<details><summary>%s</summary>\n\n```\n' "$1" >> "$DETAIL"
  cat >> "$DETAIL"
  printf '```\n\n</details>\n' >> "$DETAIL"
}
ok()   { OK_COUNT=$((OK_COUNT+1));   row "| ✅ | $1 | $2 |"; }
bad()  {
  BAD_COUNT=$((BAD_COUNT+1)); row "| ❌ | $1 | $2 |"
  echo "::error::selfcheck-release(${VARIANT}): $1 —— $2" >&2
}
warn() {
  WARN_COUNT=$((WARN_COUNT+1)); row "| ⚠️ | $1 | $2 |"
  echo "::warning::selfcheck-release(${VARIANT}): $1 —— $2" >&2
}
human() { du -sh "$1" 2>/dev/null | cut -f1; }
# 读 ELF 的 e_flags，输出小写十六进制（如 0x43）
elf_flags() { readelf -h "$1" 2>/dev/null | sed -n 's/^ *Flags: *//p' | sed 's/,.*//' | tr 'A-Z' 'a-z'; }
# 读 ELF 的 PT_INTERP（共享库没有这一项，输出为空）
interp() { readelf -l "$1" 2>/dev/null | sed -n 's|.*Requesting program interpreter: \(.*\)\]|\1|p'; }
maxof() { [ -z "$1" ] && { printf '%s' "$2"; return; }; printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }
# JSON 字符串转义（值都是版本号 / 路径，只需要处理反斜杠和引号）
jstr() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# 全量 file 扫描（$(nproc) 并发）：每个 chunk 写自己的临时文件，最后拼起来。
# 不能直接 `xargs -P N file > FILELIST` —— 所有 file 进程共享同一个非 O_APPEND 的 fd，
# 各自 4KB 的 stdio 缓冲刷出时会互相插队，把行从中间截断再拼到别的行上。
# 实测同一份产物：这么写比单进程基准少算 50 个 PE32、2 个未 strip（会把明细里的
# 文件名也拼坏）。分块写文件后与单进程基准逐行一致，耗时可忽略。
scan_files() {
  local d; d=$(mktemp -d)
  find "$1" -type f -print0 | xargs -0 -P "$(nproc)" -n 200 \
    env SCAN_DIR="$d" sh -c 'file "$@" > "$(mktemp "$SCAN_DIR/XXXXXX")"' sh
  cat "$d"/* 2>/dev/null
  rm -rf "$d"
}

# 写结果 JSON（紧凑单行）。检查没能完成时也要写，汇总表才不会有缺口。
write_json() {
  local status=$1
  [ -n "$JSON" ] || return 0
  mkdir -p "$(dirname "$JSON")"
  printf '{"tag":"%s","variant":"%s","abi":"%s","rid":"%s","asset":"%s","status":"%s",' \
    "$(jstr "$TAG")" "$(jstr "$VARIANT")" "$(jstr "$ABI")" "$(jstr "$RID")" "$(jstr "$(basename "$SDK")")" "$status" > "$JSON"
  printf '"elf_flags":"%s","elf_flags_ok":%s,"flags_consistent":%s,' \
    "$(jstr "$M_ELF_FLAGS")" "$([ "$BAD_ELF_FLAGS" = false ] && echo true || echo false)" \
    "$([ "$BAD_FLAGS_CONSIST" = false ] && echo true || echo false)" >> "$JSON"
  printf '"interp":"%s","interp_ok":%s,' "$(jstr "$M_INTERP")" \
    "$([ "$BAD_INTERP" = false ] && echo true || echo false)" >> "$JSON"
  printf '"glibcxx":"%s","glibcxx_ok":%s,' "$(jstr "$M_GLIBCXX")" \
    "$([ "$BAD_GLIBCXX" = false ] && echo true || echo false)" >> "$JSON"
  printf '"glibc":"%s","glibc_ok":%s,' "$(jstr "$M_GLIBC")" \
    "$([ "$BAD_GLIBC" = false ] && echo true || echo false)" >> "$JSON"
  printf '"codeanalysis":"%s","analyzers":%s,"codeanalysis_ok":%s,' \
    "$(jstr "$M_ANZ_VER")" "$M_ANZ_N" \
    "$([ "$BAD_ANZ" = false ] && echo true || echo false)" >> "$JSON"
  printf '"pe_total":%s,"pe32":%s,"unstripped":%s,"size_tar":"%s","size_unpacked":"%s",' \
    "$M_PE" "$M_PE32" "$M_UNSTRIPPED" "$(jstr "$M_TAR")" "$(jstr "$M_UNPACKED")" >> "$JSON"
  printf '"bad":%s,"warn":%s,"report":"%s"}\n' \
    "$BAD_COUNT" "$WARN_COUNT" "$(jstr "$OUT")" >> "$JSON"
}

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 报告头 ----
M_TAR=$(human "$SDK")
say "## 发布后自检 · ${VARIANT} / ${ABI}${TAG:+ · ${TAG}}"
say ""
say "- 资产：\`$(basename "$SDK")\`（${M_TAR}）"
say "- 期望 ELF flags：\`${ABI_FLAGS}\`　RID：\`${RID}\`（libc：\`${WANT_LIBC}\`）"
say "- GLIBCXX 上限：$([ -n "$GLIBCXX_MAX" ] && echo "\`${GLIBCXX_MAX}\`" || echo "不检查")　\
GLIBC 上限：$([ -n "$GLIBC_MAX" ] && echo "\`${GLIBC_MAX}\`" || echo "不检查")"
say ""

if [ ! -f "$SDK" ]; then
  warn "资产存在" "\`$SDK\` 不存在 —— 检查没能进行"
  M_UNPACKED=""
  write_json error
  say ""
  say "**检查没能进行** —— 资产不存在。"
  [ -n "$OUT" ] && { mkdir -p "$(dirname "$OUT")"; cp "$REPORT" "$OUT"; }
  exit 2
fi

# ------------------------------------------------------------- 解包 ----
WORK=$(mktemp -d /tmp/selfcheck-release.XXXXXX) || { echo "无法创建临时目录" >&2; exit 2; }
echo "解包到 $WORK …" >&2
if ! tar -xzf "$SDK" -C "$WORK"; then
  warn "解包" "\`$(basename "$SDK")\` 解包失败 —— 检查没能进行"
  write_json error
  say ""
  say "**检查没能进行** —— 解包失败。"
  [ -n "$OUT" ] && { mkdir -p "$(dirname "$OUT")"; cp "$REPORT" "$OUT"; }
  exit 2
fi
root="$WORK"
M_UNPACKED=$(human "$root")

# --------------------------------------------------- 1. 主程序 ABI flag ----
if [ -f "$root/dotnet" ]; then
  M_ELF_FLAGS=$(elf_flags "$root/dotnet")
  if [ "$M_ELF_FLAGS" = "$ABI_FLAGS" ]; then
    ok "dotnet ABI flag" "\`./dotnet\` e_flags=\`${M_ELF_FLAGS}\`，与 ${ABI} 相符"
  else
    BAD_ELF_FLAGS=true
    bad "dotnet ABI flag" "\`./dotnet\` e_flags=\`${M_ELF_FLAGS}\`，期望 \`${ABI_FLAGS}\` —— 资产与 ABI 不符"
  fi
  M_INTERP=$(interp "$root/dotnet")
else
  BAD_ELF_FLAGS=true
  bad "dotnet ABI flag" "\`./dotnet\` 不存在 —— 产物结构异常"
fi

# ---------------------------------------------------- 2. 原生二进制扫描 ----
# 有界命名集（同 selfcheck.sh）：.so* / dotnet / apphost / singlefilehost / createdump。
# 解释器只对「有 PT_INTERP 的」可执行文件有意义 —— 共享库本来就没有这项。
mapfile -t elfs < <(find "$root" -type f \
  \( -name '*.so' -o -name '*.so.*' -o -name dotnet -o -name apphost \
     -o -name singlefilehost -o -name createdump \) \
  | LC_ALL=C sort)

elf_abi_mismatch=0; mismatch_list=""
interp_bad=0; interp_list=""; interp_seen=0
glibc_max_found=""; glibcxx_max_found=""

for f in "${elfs[@]}"; do
  rel=${f#"$root"/}
  fl=$(elf_flags "$f")
  if [ "$fl" != "$ABI_FLAGS" ]; then
    elf_abi_mismatch=$((elf_abi_mismatch+1))
    mismatch_list+="${rel}  e_flags=${fl}"$'\n'
  fi

  i=$(interp "$f")
  if [ -n "$i" ]; then
    interp_seen=$((interp_seen+1))
    # glibc 变体只要不是 musl 解释器就算对（lns8 是 ld.so.1、lns23 是
    # ld-linux-loongarch-lp64d.so.1，名字不一样）；musl 变体必须带 ld-musl。
    interp_ok=1
    case "$i" in
      *ld-musl*) [ "$WANT_LIBC" = musl ]  || interp_ok=0 ;;
      *)         [ "$WANT_LIBC" = glibc ] || interp_ok=0 ;;
    esac
    if [ "$interp_ok" -eq 0 ]; then
      interp_bad=$((interp_bad+1))
      interp_list+="${rel}  → ${i}"$'\n'
    fi
  fi

  syms=$(readelf --dyn-syms --wide "$f" 2>/dev/null || true)
  [ -n "$syms" ] || continue
  v=$(printf '%s\n' "$syms" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/GLIBC_//' | sort -V | tail -1)
  [ -n "$v" ] && glibc_max_found=$(maxof "$glibc_max_found" "$v")
  c=$(printf '%s\n' "$syms" | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/GLIBCXX_//' | sort -V | tail -1)
  [ -n "$c" ] && glibcxx_max_found=$(maxof "$glibcxx_max_found" "$c")
done

if [ "${#elfs[@]}" -eq 0 ]; then
  bad "原生二进制" "未找到任何 .so / dotnet / apphost —— 产物结构异常"
elif [ "$elf_abi_mismatch" -eq 0 ]; then
  ok "ABI flag 一致性" "${#elfs[@]} 个原生二进制全部为 \`${ABI_FLAGS}\`"
else
  BAD_FLAGS_CONSIST=true
  warn "ABI flag 一致性" "${#elfs[@]} 个中有 ${elf_abi_mismatch} 个不为 \`${ABI_FLAGS}\`"
  printf '%s' "$mismatch_list" | detail "e_flags 不符的原生二进制"
fi

# 解释器：只对可执行文件有意义。它抓的是「资产名字与内容不符」——
# v9.0.121-abi2.0 那份 \`*-linux-loongarch64.tar.gz\` 实际是 musl 构建，就是这一类。
if [ -z "$M_INTERP" ]; then
  warn "ELF 解释器" "\`./dotnet\` 没有 PT_INTERP（静态链接？），无法核对 RID"
elif [ "$interp_bad" -eq 0 ]; then
  ok "ELF 解释器" "${interp_seen} 个可执行文件均为 ${WANT_LIBC} 解释器（\`${M_INTERP}\`）"
else
  BAD_INTERP=true
  bad "ELF 解释器" "${interp_bad}/${interp_seen} 个可执行文件不是 ${WANT_LIBC} 解释器，与 RID \`${RID}\` 不符"
  printf '%s' "$interp_list" | detail "解释器与 RID 不符的可执行文件"
fi

if [ -z "$GLIBCXX_MAX" ]; then
  : # musl：没有 GLIBCXX 符号版本可查
else
  M_GLIBCXX=$glibcxx_max_found
  if [ -z "$glibcxx_max_found" ]; then
    warn "GLIBCXX 符号版本" "未在任何原生二进制中找到 GLIBCXX_ 符号，无法核对上限 ${GLIBCXX_MAX}"
  elif [ "$(maxof "$GLIBCXX_MAX" "$glibcxx_max_found")" = "$GLIBCXX_MAX" ]; then
    ok "GLIBCXX 符号版本" "最高 \`${glibcxx_max_found}\` ≤ 该变体上限 \`${GLIBCXX_MAX}\`"
  else
    BAD_GLIBCXX=true
    bad "GLIBCXX 符号版本" "最高 \`${glibcxx_max_found}\` 超过该变体上限 \`${GLIBCXX_MAX}\` —— 目标系统会缺符号"
  fi
fi

if [ -z "$GLIBC_MAX" ]; then
  : # musl
else
  M_GLIBC=$glibc_max_found
  if [ -z "$glibc_max_found" ]; then
    warn "GLIBC 符号版本" "未在任何原生二进制中找到 GLIBC_ 符号，无法核对上限 ${GLIBC_MAX}"
  elif [ "$(maxof "$GLIBC_MAX" "$glibc_max_found")" = "$GLIBC_MAX" ]; then
    ok "GLIBC 符号版本" "最高 \`${glibc_max_found}\` ≤ sysroot \`${GLIBC_MAX}\`"
  else
    BAD_GLIBC=true
    bad "GLIBC 符号版本" "最高 \`${glibc_max_found}\` 超过 sysroot \`${GLIBC_MAX}\` —— 目标系统会缺符号"
  fi
fi

# ------------------------------------------- 3. analyzers 的 CodeAnalysis ----
# source-build 会把 analyzer 重编一遍，引用的是自己那份 Microsoft.CodeAnalysis。
# 期望值随版本而变（官方 x64 10.0 是 4:14:0:0、9.0 是 4:8:0:0），所以只列不判；
# 唯一判死的是 branding 漏进程序集引用的 42:42:42:42。
# 只取 analyzers/dotnet/cs/ 这一层：卫星目录（de/、zh-Hans/…）里的是 .resources.dll，
# 不引 CodeAnalysis，混进来只会把表撑长。
anz_files=()
for f in "$root"/packs/*/*/analyzers/dotnet/cs/*.dll; do
  [ -f "$f" ] && anz_files+=("$f")
done
M_ANZ_N=${#anz_files[@]}
if [ "${#anz_files[@]}" -eq 0 ]; then
  warn "analyzers 引用" "\`packs/*/*/analyzers/dotnet/cs/\` 下没有 DLL —— 产物可能不完整"
elif [ -z "$ILDASM" ] || [ ! -x "$ILDASM" ]; then
  warn "analyzers 引用" "未提供 ildasm（--ildasm），跳过 ${#anz_files[@]} 个 analyzer 的 CodeAnalysis 版本检查"
else
  say "### analyzers 的 Microsoft.CodeAnalysis 引用"
  say ""
  say "| analyzer | Microsoft.CodeAnalysis |"
  say "| --- | --- |"
  branding_hits=""
  declare -A ver_set=()
  for f in "${anz_files[@]}"; do
    # packs/<包名>/<版本>/analyzers/dotnet/cs/<dll> —— 表里只留「包名/DLL 名」
    rel=${f#"$root"/}; name="$(printf '%s' "$rel" | cut -d/ -f2)/$(basename "$f")"
    out=$("$ILDASM" "$f" 2>/dev/null || true)
    ver=$(printf '%s\n' "$out" \
      | grep -A 4 '^\.assembly extern Microsoft\.CodeAnalysis$' \
      | sed -n 's/^ *\.ver *//p' | sort -u | paste -sd, -)
    [ -n "$ver" ] && ver_set[$ver]=1
    say "| \`${name}\` | ${ver:-<无引用>} |"
    # branding 会以 42:42:42:42 的形式出现在任何程序集引用上，顺手一起看
    b=$(printf '%s\n' "$out" | grep -c '\.ver 42:42:42:42' || true)
    [ "$b" -gt 0 ] && branding_hits+="${name}: ${b} 处 .ver 42:42:42:42"$'\n'
    printf '%s\n' "$out" | grep -A 4 '^\.assembly extern Microsoft\.CodeAnalysis$' \
      | sed "s|^|${name}  |" >> "$ANZ"
  done
  say ""
  M_ANZ_VER=$(printf '%s\n' "${!ver_set[@]}" | sort -V | paste -sd, -)
  if [ -n "$M_ANZ_VER" ]; then
    ok "analyzers 引用" "${#anz_files[@]} 个 analyzer，Microsoft.CodeAnalysis 版本：\`${M_ANZ_VER}\`"
  else
    warn "analyzers 引用" "${#anz_files[@]} 个 analyzer 都没有引用 Microsoft.CodeAnalysis"
  fi
  if [ -n "$branding_hits" ]; then
    BAD_ANZ=true
    bad "analyzers branding" "程序集引用里出现 42:42:42:42（branding 未替换）"
    printf '%s' "$branding_hits" | detail "42:42:42:42 出现位置"
  fi
  detail "各 analyzer 的 CodeAnalysis 引用（ildasm）" < "$ANZ"
fi

# ---------------------------------------------------- 4. 全量 file 扫描 ----
echo "扫描全部文件（file，$(nproc) 并发）…" >&2
scan_files "$root" > "$FILELIST"

# 注意：file 会把描述列用空格补齐，切分路径必须用 [[:space:]]+ 而不是单个空格，
# 否则整行会漏过去、再被后面的 xargs 按空格拆碎。
pe_total=$(grep -cE ': +PE32\+ executable' "$FILELIST" || true)
pe32_total=$(grep -cE ': +PE32 executable' "$FILELIST" || true)
M_PE=$pe_total; M_PE32=$pe32_total

if [ "$pe_total" -gt 0 ]; then
  ok "PE32+ 托管 DLL" "${pe_total} 个（另有 PE32/AnyCPU ${pe32_total} 个）"
  grep -E ': +PE32\+ executable' "$FILELIST" | sed -E 's/:[[:space:]]+PE32\+.*//' \
    | awk -v r="$root/" '{ if (index($0, r) == 1) $0 = substr($0, length(r) + 1)
                           n = split($0, a, "/")
                           if (n > 1) { p = a[1]; for (i = 2; i < n; i++) p = p "/" a[i]; print p } else print "." }' \
    | sort | uniq -c | sort -rn | head -15 | detail "PE32+ 托管 DLL 分布（前 15）"
else
  warn "PE32+ 托管 DLL" "一个都没有 —— 产物可能不完整"
fi

# .dbg / .o 本身就是符号/目标文件，不在「该 strip 却没 strip」之列，单独计数；
# 剩下的才是可疑的（构建时的 selfcheck.sh 不区分，发布后体检要能一眼看出真问题）。
notstripped_sym=$(grep -E ': +.*ELF.*not stripped' "$FILELIST" | grep -cE '\.(dbg|o):' || true)
notstripped_all=$(grep -cE ': +.*ELF.*not stripped' "$FILELIST" || true)
notstripped=$((notstripped_all - notstripped_sym))
M_UNSTRIPPED=$notstripped

if [ "$notstripped" -eq 0 ]; then
  ok "strip 状态" "没有该 strip 而未 strip 的 ELF（另有 ${notstripped_sym} 个 .dbg/.o 本来就不 strip）"
else
  warn "strip 状态" "未 strip 的 ELF ${notstripped} 个（另有 ${notstripped_sym} 个 .dbg/.o 不计）；\
发布版通常应全部 strip，会显著影响体积"
  grep -E ': +.*ELF.*not stripped' "$FILELIST" | grep -vE '\.(dbg|o):' | sed -E 's/:[[:space:]]+ELF.*//' \
    | awk -v r="$root/" '{ if (index($0, r) == 1) print substr($0, length(r) + 1); else print }' \
    | head -20 | detail "未 strip 的 ELF（前 20，不含 .dbg/.o）"
fi

# ------------------------------------------------------------- 统计表 ----
say ""
say "| 统计项 | 数值 |"
say "| --- | --- |"
say "| ELF 原生二进制 | ${#elfs[@]}（其中可执行文件 ${interp_seen} 个） |"
say "| e_flags = ${ABI_FLAGS} | $(( ${#elfs[@]} - elf_abi_mismatch )) / ${#elfs[@]} |"
say "| ELF 解释器 | ${M_INTERP:-无} |"
[ -n "$GLIBCXX_MAX" ] && say "| GLIBCXX 最高符号版本 | ${glibcxx_max_found:-无}（上限 ${GLIBCXX_MAX}） |"
[ -n "$GLIBC_MAX" ]   && say "| GLIBC 最高符号版本 | ${glibc_max_found:-无}（上限 ${GLIBC_MAX}） |"
[ "$M_ANZ_N" -gt 0 ]  && say "| analyzer | ${M_ANZ_N} 个，CodeAnalysis 引用 ${M_ANZ_VER:-无} |"
say "| PE32+ 托管 DLL | ${pe_total} |"
say "| PE32（AnyCPU）托管 DLL | ${pe32_total} |"
say "| 未 strip 的 ELF | ${notstripped}（另有 ${notstripped_sym} 个 .dbg/.o） |"
say "| 解包后体积 | ${M_UNPACKED} |"
say "| 压缩包体积 | ${M_TAR} |"

# ---------------------------------------------------------------- 结论 ----
say ""
say "### 检查表"
say ""
say "| | 检查 | 结果 |"
say "| --- | --- | --- |"
cat "$ROWS" >> "$REPORT"
say ""
say "### 明细"
cat "$DETAIL" >> "$REPORT"
say ""
say "### 结论"
say ""
if [ "$BAD_COUNT" -eq 0 ]; then
  say "**未发现问题** —— ${OK_COUNT} 项通过，警告 ${WARN_COUNT} 条。"
else
  say "**有问题** —— ${BAD_COUNT} 项失败、${OK_COUNT} 项通过，警告 ${WARN_COUNT} 条。"
  [ "$STRICT" -eq 1 ] && say "" && say "（--strict：以退出码 1 结束）"
fi
say ""
say "> 本脚本只做静态检查。\`dotnet --info\`、各发布组合能否真正跑起来，要拿到目标发行版里执行。"

if [ -n "$OUT" ]; then
  mkdir -p "$(dirname "$OUT")"
  cp "$REPORT" "$OUT"
  echo "报告已写入 $OUT" >&2
fi
write_json "$([ "$BAD_COUNT" -gt 0 ] && echo bad || echo ok)"

if [ "$STRICT" -eq 1 ] && [ "$BAD_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
