#!/bin/bash
# Movo — 本地验证脚本（第 2.4 节）
# 清理构建 iOS + macOS 双端 → 跑全部单测（Domain/Data/Privacy/Adapter/Sync）→ 打印失败摘要。
# 用法：Scripts/verify.sh [--quick]
#   --quick  跳过 iOS 端构建，只跑 macOS 构建 + 全部单测（日常快速回归）
#
# ⚠️ 编写本脚本时必须遵守（macOS 自带的是 bash 3.2）：
#   变量展开若**紧跟中文全角字符**，必须加花括号写成 ${VAR}。
#   bash 3.2 解析变量名时不识别多字节字符，会把全角字符的首字节吞进变量名，
#   例如 "$VAR）" 会被解析成 ${VAR\xEF} → set -u 下报 "VAR?: unbound variable"。
#   注意这与 locale 无关（LC_ALL=en_US.UTF-8 无效），只能靠花括号避免。
#
# ⚠️ 同样因为 bash 3.2：set -u 下展开空数组 "${ARR[@]}" 会报 unbound variable。
#   对可能为空的数组，要么先用 ${#ARR[@]} 判断，要么写成 ${ARR[@]+"${ARR[@]}"}。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$ROOT/Movo"
PROJECT="$PROJECT_DIR/Movo.xcodeproj"
SCHEME="Movo"
DERIVED="$ROOT/.build/DerivedData"
LOG_DIR="$ROOT/.build/logs"
mkdir -p "$LOG_DIR"

QUICK=0
[[ "${1:-}" == "--quick" ]] && QUICK=1

FAILURES=()
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$1"; }
bad()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$1"; FAILURES+=("$1"); }

if [[ ! -d "$PROJECT" ]]; then
  step "生成 Xcode 工程"
  (cd "$PROJECT_DIR" && xcodegen generate)
fi

# ---------------------------------------------------------------- macOS 构建
step "macOS 构建（Movo + MovoKit）"
if xcodebuild build \
      -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination 'platform=macOS' \
      -derivedDataPath "$DERIVED" \
      > "$LOG_DIR/build-macos.log" 2>&1; then
  ok "macOS 构建通过"
else
  bad "macOS 构建失败（$LOG_DIR/build-macos.log）"
  grep -E "error:" "$LOG_DIR/build-macos.log" | head -40
fi

# ------------------------------------------------------------------ iOS 构建
if [[ $QUICK -eq 0 ]]; then
  # 选取模拟器：优先 iPhone 17 Pro，否则取列表中第一个可用 iPhone。
  # 不锁定 OS 版本，交由 xcodebuild 选用当前最新的可用运行时
  # （锁定 OS 会在运行时被升级/移除后直接构建失败）。
  DEV_LIST="$(xcrun simctl list devices available 2>/dev/null || true)"
  SIM_NAME="$(printf '%s\n' "$DEV_LIST" | grep -m1 -o 'iPhone 17 Pro' || true)"
  if [[ -z "$SIM_NAME" ]]; then
    SIM_NAME="$(printf '%s\n' "$DEV_LIST" | grep -m1 -o 'iPhone[^(]*' | sed 's/[[:space:]]*$//' || true)"
  fi
  SIM_NAME="${SIM_NAME:-iPhone 17}"
  SIM_DEST="platform=iOS Simulator,name=${SIM_NAME}"

  step "iOS 构建（模拟器：${SIM_NAME}）"
  if xcodebuild build \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -destination "$SIM_DEST" \
        -derivedDataPath "$DERIVED" \
        > "$LOG_DIR/build-ios.log" 2>&1; then
    ok "iOS 构建通过（${SIM_DEST}）"
  else
    bad "iOS 构建失败（$LOG_DIR/build-ios.log）"
    printf '  当前可用模拟器：\n'
    printf '%s\n' "$DEV_LIST" | grep -m8 'iPhone' | sed 's/^/    /'
    grep -E "error:" "$LOG_DIR/build-ios.log" | head -40
  fi
fi

# --------------------------------------------------------------------- 单测
for T in MovoDomainTests MovoDataTests MovoPrivacyTests MovoAdapterTests MovoSyncTests; do
  step "测试 $T"
  if xcodebuild test \
        -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
        -destination 'platform=macOS' \
        -only-testing:"$T" \
        -derivedDataPath "$DERIVED" \
        > "$LOG_DIR/$T.log" 2>&1; then
    PASSED=$(grep -c "Test Case .* passed" "$LOG_DIR/$T.log" || true)
    ok "$T 通过（${PASSED:-0} 个用例）"
  else
    bad "$T 失败（$LOG_DIR/$T.log）"
    grep -E "error:|XCTAssert.*failed|failed - " "$LOG_DIR/$T.log" | head -20
  fi
done

# ------------------------------------------------------------------ 汇总
printf '\n\033[1m================ 验证摘要 ================\033[0m\n'
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf '\033[1;32m全部通过 ✔\033[0m\n'
  exit 0
fi
printf '\033[1;31m%d 项失败：\033[0m\n' "${#FAILURES[@]}"
for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
printf '日志目录：%s\n' "$LOG_DIR"
exit 1
