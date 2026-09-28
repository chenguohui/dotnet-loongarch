#!/usr/bin/env bash
# ============================================================================
# selfcheck.sh —— .NET SDK 产物静态自检（门禁 + 报告）
#
# 在构建镜像（x64）里运行，不需要 dotnet 本身能跑：全部检查只依赖
# readelf / file / grep / du，所以在 x64 上就能完成。
# 需要真正执行 dotnet 的检查（--info、各发布参数组合）属于 test.yml（QEMU）。
#
# 用法：
#   selfcheck.sh --sdk '<glob>' --psa '<glob>' \
#                --variant lns23 --abi abi2.0 --abiflags 0x43 \
#                --version 10.0.112 --glibc-max 2.38 \
#                --out build-info/selfcheck-lns23.md
#
# 参数：
#   --sdk        SDK tar.gz 的 glob，必须恰好命中 1 个
#   --psa        Private.SourceBuilt.Artifacts.*.tar.gz 的 glob，必须恰好命中 1 个（可为空则不查）
#   --variant    变体名（lns8/lns23/musl），用于报告
#   --abi        abi1.0 / abi2.0，用于报告
#   --abiflags   该 ABI 期望的 ELF e_flags（0x3 / 0x43）——门禁
#   --version    期望的 SDK 版本（如 10.0.112）——门禁
#   --glibc-max  该变体 sysroot 的 glibc 上限（如 2.38）；空 = 不检查（musl）
#   --out        报告写入路径（相对 cwd 或绝对路径）
#
# 退出码：0 = 全部门禁通过；1 = 有门禁失败（报告仍会完整写出）
# ============================================================================
set -uo pipefail

SDK_GLOB="" PSA_GLOB="" VARIANT="" ABI="" ABI_FLAGS="" VERSION="" GLIBC_MAX="" OUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sdk)       SDK_GLOB=${2:-};   shift 2 ;;
    --psa)       PSA_GLOB=${2:-};   shift 2 ;;
    --variant)   VARIANT=${2:-};    shift 2 ;;
    --abi)       ABI=${2:-};        shift 2 ;;
    --abiflags)  ABI_FLAGS=${2:-};  shift 2 ;;
    --version)   VERSION=${2:-};    shift 2 ;;
    --glibc-max) GLIBC_MAX=${2:-};  shift 2 ;;
    --out)       OUT=${2:-};        shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

for v in SDK_GLOB VARIANT ABI ABI_FLAGS VERSION OUT; do
  [ -n "${!v}" ] || { echo "缺参数: $v" >&2; exit 2; }
done

# 必须固定为 C locale：readelf / file 的输出描述是本地化的，
# 中文 locale 下 readelf 打印「标志：」、file 打印中文描述，解析会全部失效。
export LC_ALL=C

# ABI flag 统一小写比较（readelf 可能输出 0x43 / 0X43）
ABI_FLAGS=$(printf '%s' "$ABI_FLAGS" | tr 'A-Z' 'a-z')

REPORT=$(mktemp); ROWS=$(mktemp); DETAIL=$(mktemp); FILELIST=$(mktemp)
GATES_FAILED=0; GATES_TOTAL=0; WARN_COUNT=0

say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
row()  { printf '%s\n' "$*" >> "$ROWS"; }
# detail <标题>：正文从 stdin 读，作为代码块收进报告末尾的「明细」
detail() {
  printf '\n<details><summary>%s</summary>\n\n```\n' "$1" >> "$DETAIL"
  cat >> "$DETAIL"
  printf '```\n\n</details>\n' >> "$DETAIL"
}
gate_pass() { GATES_TOTAL=$((GATES_TOTAL+1)); row "| ✅ | $1 | $2 |"; }
gate_fail() {
  GATES_TOTAL=$((GATES_TOTAL+1)); GATES_FAILED=$((GATES_FAILED+1))
  row "| ❌ | $1 | $2 |"
  echo "::error::selfcheck(${VARIANT}): $1 —— $2" >&2
}
warn() {
  GATES_TOTAL=$((GATES_TOTAL+1)); WARN_COUNT=$((WARN_COUNT+1))
  row "| ⚠️ | $1 | $2 |"
  echo "::warning::selfcheck(${VARIANT}): $1 —— $2" >&2
}
human() { du -sh "$1" 2>/dev/null | cut -f1; }
# 读 ELF 的 e_flags，输出小写十六进制（如 0x43）
elf_flags() { readelf -h "$1" 2>/dev/null | sed -n 's/^ *Flags: *//p' | sed 's/,.*//' | tr 'A-Z' 'a-z'; }

finish() {
  say ""
  say "### 门禁"
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
  if [ "$GATES_FAILED" -eq 0 ]; then
    say "**通过** —— ${GATES_TOTAL} 项检查全部通过，警告 ${WARN_COUNT} 条。"
  else
    say "**未通过** —— ${GATES_FAILED}/${GATES_TOTAL} 项门禁失败，警告 ${WARN_COUNT} 条。"
  fi
  if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")"
    cp "$REPORT" "$OUT"
    echo "报告已写入 $OUT"
  fi
}

# 展开 glob，要求恰好命中 1 个（否则把命中项列出来，便于排查）。
# 结果放在全局 RESOLVED —— 不能用命令替换，否则 gate_fail 的计数会丢在子 shell 里。
RESOLVED=""
resolve_one() {
  local pattern=$1 label=$2 m=()
  RESOLVED=""
  while IFS= read -r f; do m+=("$f"); done < <(compgen -G "$pattern" || true)
  if [ "${#m[@]}" -ne 1 ]; then
    gate_fail "$label" "期望 1 个文件，实际 ${#m[@]} 个（\`${pattern}\`）"
    printf '%s\n' "${m[@]:-<无>}" | detail "${label} 的匹配项"
    return 1
  fi
  RESOLVED="${m[0]}"
}

# ---------------------------------------------------------------- 报告头 ----
say "## 自检报告 · ${VARIANT} / ${ABI}"
say ""
say "- 期望 SDK 版本：\`${VERSION}\`　ELF flags：\`${ABI_FLAGS}\`"
say "- glibc 上限：$([ -n "$GLIBC_MAX" ] && echo "\`${GLIBC_MAX}\`" || echo "不检查（musl）")"
say ""

# ------------------------------------------------------- 1. 产物是否齐全 ----
sdk_tar=""; psa_tar=""
if resolve_one "$SDK_GLOB" "SDK tarball"; then
  sdk_tar=$RESOLVED
  gate_pass "SDK tarball" "命中 1 个：\`$(basename "$sdk_tar")\`（$(human "$sdk_tar")）"
fi
if [ -n "$PSA_GLOB" ]; then
  if resolve_one "$PSA_GLOB" "Private.SourceBuilt.Artifacts"; then
    psa_tar=$RESOLVED
    gate_pass "私有源包" "命中 1 个：\`$(basename "$psa_tar")\`（$(human "$psa_tar")）"
  fi
fi

if [ -z "$sdk_tar" ]; then
  finish
  exit 1
fi

# 文件名里的版本号必须与期望版本一致
case "$(basename "$sdk_tar")" in
  *"${VERSION}"*) gate_pass "产物版本号" "文件名含 \`${VERSION}\`" ;;
  *) gate_fail "产物版本号" "\`$(basename "$sdk_tar")\` 不含期望版本 \`${VERSION}\`（ref 与产物不匹配？）" ;;
esac

# ------------------------------------------------------------- 2. 解包 ----
work=$(mktemp -d /tmp/selfcheck.XXXXXX) || { echo "无法创建临时目录" >&2; exit 1; }
echo "解包到 $work …"
if ! tar -xzf "$sdk_tar" -C "$work"; then
  gate_fail "解包" "\`$(basename "$sdk_tar")\` 解包失败"
  finish
  exit 1
fi
root="$work"

# --------------------------------------------- 3. 结构与主程序 ----
if [ -d "$root/sdk/${VERSION}" ]; then
  gate_pass "SDK 目录" "\`sdk/${VERSION}/\` 存在"
else
  gate_fail "SDK 目录" "\`sdk/${VERSION}/\` 不存在；实际：$(ls "$root/sdk" 2>/dev/null | tr '\n' ' ')"
fi

if [ -f "$root/dotnet" ]; then
  actual=$(elf_flags "$root/dotnet")
  if [ "$actual" = "$ABI_FLAGS" ]; then
    gate_pass "dotnet ABI flag" "\`./dotnet\` e_flags=\`${actual}\`，与 ${ABI} 相符"
  else
    gate_fail "dotnet ABI flag" "\`./dotnet\` e_flags=\`${actual}\`，期望 \`${ABI_FLAGS}\` —— ABI 不符，禁止发布"
  fi
else
  gate_fail "dotnet ABI flag" "\`./dotnet\` 不存在"
fi

# ------------------------------------------------- 4. 原生二进制批量扫描 ----
# 有界命名集：SDK 里的原生二进制不外乎 .so*、dotnet、apphost、singlefilehost、
# createdump，比全盘 file 扫描快得多，且覆盖完整。
mapfile -t elfs < <(find "$root" -type f \
  \( -name '*.so' -o -name '*.so.*' -o -name dotnet -o -name apphost \
     -o -name singlefilehost -o -name createdump \) \
  | LC_ALL=C sort)

elf_abi_match=0; elf_abi_mismatch=0; mismatch_list=""
glibc_max_found=""; glibcxx_max_found=""
maxof() { [ -z "$1" ] && { printf '%s' "$2"; return; }; printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1; }

for f in "${elfs[@]}"; do
  fl=$(elf_flags "$f")
  if [ "$fl" = "$ABI_FLAGS" ]; then
    elf_abi_match=$((elf_abi_match+1))
  else
    elf_abi_mismatch=$((elf_abi_mismatch+1))
    mismatch_list+="${f#"$root"/}  e_flags=${fl}"$'\n'
  fi
  syms=$(readelf --dyn-syms --wide "$f" 2>/dev/null || true)
  [ -n "$syms" ] || continue
  v=$(printf '%s\n' "$syms" | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sed 's/GLIBC_//' | sort -V | tail -1)
  [ -n "$v" ] && glibc_max_found=$(maxof "$glibc_max_found" "$v")
  c=$(printf '%s\n' "$syms" | grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)+' | sed 's/GLIBCXX_//' | sort -V | tail -1)
  [ -n "$c" ] && glibcxx_max_found=$(maxof "$glibcxx_max_found" "$c")
done

if [ "${#elfs[@]}" -eq 0 ]; then
  gate_fail "原生二进制" "未找到任何 .so / dotnet / apphost —— 产物结构异常"
else
  if [ "$elf_abi_mismatch" -eq 0 ]; then
    gate_pass "ABI flag 一致性" "${#elfs[@]} 个原生二进制全部为 \`${ABI_FLAGS}\`"
  else
    warn "ABI flag 一致性" "${#elfs[@]} 个中有 ${elf_abi_mismatch} 个不为 \`${ABI_FLAGS}\`"
    printf '%s' "$mismatch_list" | detail "e_flags 不符的原生二进制"
  fi
fi

if [ -z "$GLIBC_MAX" ]; then
  : # musl：没有 glibc 符号版本可查
elif [ -z "$glibc_max_found" ]; then
  warn "GLIBC 符号版本" "未在任何原生二进制中找到 GLIBC_ 符号，无法核对上限 ${GLIBC_MAX}"
elif [ "$(maxof "$GLIBC_MAX" "$glibc_max_found")" = "$GLIBC_MAX" ]; then
  gate_pass "GLIBC 符号版本" "最高 \`${glibc_max_found}\` ≤ sysroot \`${GLIBC_MAX}\`"
else
  gate_fail "GLIBC 符号版本" "最高 \`${glibc_max_found}\` 超过 sysroot \`${GLIBC_MAX}\` —— 目标系统会缺符号"
fi

# ---------------------------------------------------- 5. 全量 file 扫描 ----
echo "扫描全部文件（file，$(nproc) 并发）…"
find "$root" -type f -print0 | xargs -0 -P "$(nproc)" -n 200 file > "$FILELIST" 2>/dev/null

# 注意：file 会把描述列用空格补齐，切分路径必须用 [[:space:]]+ 而不是单个空格，
# 否则整行会漏过去、再被后面的 xargs 按空格拆碎。
pe_total=$(grep -cE ': +PE32\+' "$FILELIST" || true)
notstripped=$(grep -cE ': +.*ELF.*not stripped' "$FILELIST" || true)
if [ "$pe_total" -gt 0 ]; then
  grep -E ': +PE32\+' "$FILELIST" | sed -E 's/:[[:space:]]+PE32\+.*//' \
    | awk -v r="$root/" '{ if (index($0, r) == 1) $0 = substr($0, length(r) + 1)
                           n = split($0, a, "/")
                           if (n > 1) { p = a[1]; for (i = 2; i < n; i++) p = p "/" a[i]; print p } else print "." }' \
    | sort | uniq -c | sort -rn | head -15 | detail "PE32+ 托管 DLL 分布（前 15）"
else
  warn "PE32+ 托管 DLL" "一个都没有 —— 产物可能不完整"
fi
if [ "$notstripped" -gt 0 ]; then
  grep -E ': +.*ELF.*not stripped' "$FILELIST" | sed -E 's/:[[:space:]]+ELF.*//' \
    | awk -v r="$root/" '{ if (index($0, r) == 1) print substr($0, length(r) + 1); else print }' \
    | head -20 | detail "未 strip 的 ELF（前 20）"
  warn "strip 状态" "未 strip 的 ELF ${notstripped} 个（会显著增大体积，发布版通常应全部 strip）"
fi

# ------------------------------------------------ 6. branding 42.42.42.42 ----
branding_hits=$(grep -rl --binary-files=text -e '42\.42\.42\.42' "$root/shared" "$root/sdk" 2>/dev/null | head -20 || true)
branding_n=0
[ -n "$branding_hits" ] && branding_n=$(printf '%s\n' "$branding_hits" | grep -c . || true)
[ "$branding_n" -gt 0 ] && printf '%s\n' "$branding_hits" | sed "s|^$root/||" | detail "含 42.42.42.42 的文件（前 20）"

# ------------------------------------------------------------- 统计表 ----
say ""
say "| 统计项 | 数值 |"
say "| --- | --- |"
say "| ELF 原生二进制 | ${#elfs[@]}$([ "${#elfs[@]}" -gt 0 ] && echo "（e_flags=${ABI_FLAGS}：${elf_abi_match}）") |"
[ -n "$GLIBC_MAX" ] && say "| GLIBC 最高符号版本 | ${glibc_max_found:-无}（上限 ${GLIBC_MAX}） |"
say "| GLIBCXX 最高符号版本 | ${glibcxx_max_found:-无} |"
say "| PE32+ 托管 DLL | ${pe_total} |"
say "| 未 strip 的 ELF | ${notstripped} |"
say "| branding 42.42.42.42 | ${branding_n} 个文件 |"
say "| 解包后体积 | $(human "$root") |"
say "| 压缩包体积 | $(human "$sdk_tar") |"
say ""
say "### 需要执行 dotnet 的检查（本脚本不做，留给 test.yml）"
say ""
say "- \`dotnet --version\` / \`dotnet --info\`"
say "- 各发布参数组合运行 hello world：SingleFile / SelfContained / ReadyToRun / Trimmed"
say "- \`ildasm\` 查 analyzers 的 CodeAnalysis 版本（构建镜像内没有 ildasm）"

finish
[ "$GATES_FAILED" -eq 0 ]
