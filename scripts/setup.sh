#!/bin/bash
# MailWidget 一键配置脚本（面向第一次拿到这份源码的人）
#
# 它做四件事：检查并自动补齐依赖 → 用你自己的 Apple 签名身份构建安装 →
# 写入你的邮箱与 AI 引擎配置 → 打开该授权的系统设置面板。
# 可以反复运行，已经满足的步骤会直接跳过。
set -uo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly BOLD=$'\033[1m'; readonly DIM=$'\033[2m'; readonly RED=$'\033[31m'
readonly GREEN=$'\033[32m'; readonly YELLOW=$'\033[33m'; readonly RESET=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "${BOLD}" "$*" "${RESET}"; }
ok()    { printf '  %s✓%s %s\n' "${GREEN}" "${RESET}" "$*"; }
warn()  { printf '  %s!%s %s\n' "${YELLOW}" "${RESET}" "$*"; }
die()   { printf '\n%s✗ %s%s\n\n' "${RED}" "$*" "${RESET}"; exit 1; }
ask()   { local p="$1" d="${2:-}" r; read -r -p "  ${p}${d:+ [${d}]}: " r; printf '%s' "${r:-$d}"; }
confirm() { local r; read -r -p "  $1 [Y/n]: " r; [[ -z "${r}" || "${r}" =~ ^[Yy] ]]; }

# ── 0. 会话可访问性自检（TCC）────────────────────────────────────────────────
# macOS 的隐私保护（TCC）：SSH/远程会话默认读不到 ~/Documents、~/Desktop 等目录。
# 如果这份源码放在那种目录里、又是从 SSH 跑的，后面每一步碰源码都会 Operation
# not permitted。所以开头先探一次——读不到自己所在目录就明确让用户改用终端 App。
if ! /bin/ls "${ROOT_DIR}" >/dev/null 2>&1; then
  die "读不到源码目录 ${ROOT_DIR}（Operation not permitted）。
  这几乎总是因为你在 SSH / 远程会话里运行，而 macOS 不给远程会话访问文稿/桌面。
  请直接在这台 Mac 前打开「终端」App，再跑一次本脚本；
  或把源码移到不受保护的位置（如 ~/mailwidget-src）后重试。"
fi

# ── 1. 系统版本 ───────────────────────────────────────────────────────────────
step "检查 macOS 版本"
major="$(/usr/bin/sw_vers -productVersion | cut -d. -f1)"
[[ "${major}" -ge 14 ]] || die "需要 macOS 14 或更高（桌面小组件从 Sonoma 起才有）。当前：$(/usr/bin/sw_vers -productVersion)"
ok "macOS $(/usr/bin/sw_vers -productVersion)"

# ── 2. 完整版 Xcode ──────────────────────────────────────────────────────────
step "检查 Xcode"
dev_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
if [[ -z "${dev_dir}" || ! -x "${dev_dir}/usr/bin/xcodebuild" || "${dev_dir}" != *".app/Contents/Developer" ]]; then
  warn "没有检测到完整版 Xcode（只有命令行工具是不够的，构建 widget 必须要 Xcode）"
  echo "    1) 到 App Store 安装 Xcode（约 10 GB，装好后打开一次同意许可）"
  echo "    2) 装完回来重新运行本脚本"
  confirm "现在打开 App Store 的 Xcode 页面？" && /usr/bin/open "macappstore://apps.apple.com/app/id497799835"
  die "等 Xcode 装好后再运行：${ROOT_DIR}/scripts/setup.sh"
fi
ok "$("${dev_dir}/usr/bin/xcodebuild" -version | head -n 1)"

# ── 3. Homebrew + xcodegen ───────────────────────────────────────────────────
step "检查构建工具 xcodegen"
if ! command -v xcodegen >/dev/null 2>&1; then
  if ! command -v brew >/dev/null 2>&1; then
    warn "缺少 Homebrew（用来装 xcodegen）"
    if confirm "自动安装 Homebrew？（会要你的登录密码）"; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" ||
        die "Homebrew 安装失败，请手动安装后重试：https://brew.sh"
      for p in /opt/homebrew/bin /usr/local/bin; do [[ -x "$p/brew" ]] && eval "$("$p/brew" shellenv)"; done
    else
      die "请先安装 Homebrew（https://brew.sh）或手动安装 xcodegen 后重试。"
    fi
  fi
  echo "  正在安装 xcodegen…"
  brew install xcodegen || die "xcodegen 安装失败。"
fi
ok "xcodegen $(xcodegen --version 2>/dev/null | head -n 1)"

# ── 4. Apple 签名身份 ────────────────────────────────────────────────────────
step "检查 Apple 签名身份"
identity_count="$(security find-identity -v -p codesigning 2>/dev/null | grep -c "Apple Development:")"
if [[ "${identity_count}" -eq 0 ]]; then
  warn "钥匙串里没有 Apple Development 证书"
  echo "    免费 Apple ID 就够用，步骤："
  echo "    1) 打开 Xcode → 菜单 Xcode → Settings → Accounts → 左下角 + → 登录你的 Apple ID"
  echo "    2) 选中账号 → Manage Certificates… → 左下角 + → Apple Development"
  echo "    3) 回来重新运行本脚本"
  confirm "现在打开 Xcode？" && /usr/bin/open -a Xcode
  die "拿到证书后再运行：${ROOT_DIR}/scripts/setup.sh"
fi
ok "找到 ${identity_count} 张 Apple Development 证书"
# Team ID 交给 install.sh 解析（它从证书的 OU 字段读，那才是真正的 Team ID；
# 证书名字括号里的那串不是）。多团队时它会提示用 MAILWIDGET_TEAM_ID 指定。
[[ "${identity_count}" -gt 1 ]] &&
  warn "有多个团队时，若构建报错请改用：MAILWIDGET_TEAM_ID=<你的TeamID> ${ROOT_DIR}/scripts/setup.sh"

# ── 5. AI 命令行（日报与邮件总结的引擎）─────────────────────────────────────
step "检查 AI 命令行"
find_cli() {  # $1=名字；在常见位置和登录 shell 里找
  local n="$1" p
  for p in "$HOME/.local/bin/$n" /opt/homebrew/bin/"$n" /usr/local/bin/"$n"; do
    [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  p="$(/bin/zsh -lc "command -v $n" 2>/dev/null)"
  [[ -n "$p" && -x "$p" ]] && { printf '%s' "$p"; return 0; }
  return 1
}
claude_path="$(find_cli claude || true)"
codex_path="$(find_cli codex || true)"

# 只看文件在不在是不够的：实测过一台机器上 codex 版本太旧，一跑就报
# "requires a newer version"，而安装脚本还在显示"已检测到"，用户被误导很久。
# 这里实际跑一次 --version，跑不通就当作不可用并提示升级。
verify_cli() {
  local path="$1" name="$2"
  "$path" --version >/dev/null 2>&1 && return 0
  warn "${name} 在 ${path}，但执行失败（可能版本过旧或安装损坏）"
  echo "    升级办法：${name} = claude 时跑 curl -fsSL https://claude.ai/install.sh | bash"
  echo "              ${name} = codex  时跑 npm install -g @openai/codex@latest"
  return 1
}
[[ -n "${claude_path}" ]] && { verify_cli "${claude_path}" claude || claude_path=""; }
[[ -n "${codex_path}" ]]  && { verify_cli "${codex_path}"  codex  || codex_path=""; }
[[ -n "${claude_path}" ]] && ok "Claude：${claude_path}" || warn "Claude：未安装"
[[ -n "${codex_path}" ]]  && ok "Codex：${codex_path}"  || warn "Codex：未安装"

if [[ -z "${claude_path}" && -z "${codex_path}" ]]; then
  echo "  两个都没有。日报和邮件总结需要其中一个（收件箱小组件不需要）。"
  choice="$(ask "装哪个？1=Claude  2=Codex  3=都不装" "1")"
  case "${choice}" in
    1) echo "  正在安装 Claude Code…"
       curl -fsSL https://claude.ai/install.sh | bash && claude_path="$(find_cli claude || true)" ;;
    2) command -v npm >/dev/null 2>&1 || { echo "  先装 Node…"; brew install node; }
       echo "  正在安装 Codex…"
       npm install -g @openai/codex && codex_path="$(find_cli codex || true)" ;;
    *) warn "跳过——之后可在 app 的设置里再配置" ;;
  esac
fi

engine=""
if [[ -n "${claude_path}" && -n "${codex_path}" ]]; then
  e="$(ask "用哪个做日报和总结？1=Claude  2=Codex" "1")"
  [[ "${e}" == "2" ]] && engine="codex" || engine="claude"
elif [[ -n "${claude_path}" ]]; then engine="claude"
elif [[ -n "${codex_path}" ]];  then engine="codex"
fi
[[ -n "${engine}" ]] && ok "引擎：${engine}"

# Gmail 日报靠的是 AI 命令行自己的 Gmail 连接器读邮件——这个 app 从不碰 Gmail 账号，
# 也没有登录框。连接器没接上的话，日报每天都会静默失败，所以这里直接探测一次。
if [[ -n "${engine}" ]]; then
  # 注意：codex 的 Gmail 是以 `codex_apps/gmail.*` 工具形式提供的，**不出现在
  # `codex mcp list` 里**——实测踩过这个坑，按 mcp list 判断会给出假阴性，害用户
  # 以为没连上而反复折腾。claude 那边才是 mcp 连接器形态。
  gmail_ok=""
  case "${engine}" in
    claude) "${claude_path}" mcp list 2>/dev/null | grep -qiE 'gmail.*connected' && gmail_ok=1 ;;
    codex)
      # codex 无法静态判断，只能看配置里插件与 connector 是否都启用；
      # 真正的验收是安装完成后用 app 里的「重新生成」跑一次。
      if grep -q 'gmail@openai' "$HOME/.codex/config.toml" 2>/dev/null &&
         ! grep -A1 'apps.connector' "$HOME/.codex/config.toml" 2>/dev/null | grep -q 'enabled = false'; then
        gmail_ok=1
      fi
      ;;
  esac
  if [[ -n "${gmail_ok}" ]]; then
    ok "${engine} 已连接 Gmail —— 日报功能可用"
  else
    warn "${engine} 还没连接 Gmail —— 收件箱小组件和邮件总结不受影响，但「Gmail 日报」会失败"
    if [[ "${engine}" == "claude" ]]; then
      echo "    去 claude.ai → Settings → Connectors → Gmail → 连接（用你要总结的那个 Gmail 账号授权）"
    else
      echo "    在 Codex 里连接 Gmail（见 Codex 的 connectors/MCP 设置）"
    fi
    echo "    ${DIM}接好之后不用重跑本脚本，日报下次运行就会生效${RESET}"
  fi
fi

# ── 6. 邮箱地址 ─────────────────────────────────────────────────────────────
step "配置邮箱"
echo "  ${DIM}日报会总结这个 Gmail 地址的邮件（留空则等第一份日报到达时自动认领）${RESET}"
MAILBOX="$(ask "你的 Gmail 地址" "")"
if [[ -n "${MAILBOX}" && "${MAILBOX}" != *@* ]]; then
  warn "看起来不像邮箱地址，已忽略：${MAILBOX}"; MAILBOX=""
fi

# ── 7. 构建并安装 ───────────────────────────────────────────────────────────
step "构建并安装 MailWidget（首次约 2–5 分钟）"
"${ROOT_DIR}/scripts/install.sh" || die "构建失败，上面的日志有具体原因。"

# ── 8. 写入配置 ─────────────────────────────────────────────────────────────
step "写入配置"
# 权威来源：装好的 app 自己的 entitlements（里面的 App Group 已经展开成真实 Team ID）
APP_GROUP="$(codesign -d --entitlements - /Applications/MailWidget.app 2>&1 |
  sed -nE 's/.*\[String\] ([A-Z0-9]{10}\.com\.kris\.mailwidget).*/\1/p' | head -n 1)"
[[ -n "${APP_GROUP}" ]] || die "读不到已安装 app 的 App Group，配置无法写入。"
TEAM_ID="${APP_GROUP%%.*}"
ok "App Group：${APP_GROUP}"
prefs_dir="$HOME/Library/Group Containers/${APP_GROUP}/Library/Preferences"
prefs="${prefs_dir}/${APP_GROUP}"
/bin/mkdir -p "${prefs_dir}"
[[ -n "${MAILBOX}" ]] && { defaults write "${prefs}" userMailbox -string "${MAILBOX}"; ok "邮箱：${MAILBOX}"; }
if [[ -n "${engine}" ]]; then
  defaults write "${prefs}" dailySummarySource -string "${engine}"
  defaults write "${prefs}" mailSummaryEngine  -string "${engine}"
  [[ -n "${claude_path}" ]] && defaults write "${prefs}" "cliPath.claude" -string "${claude_path}"
  [[ -n "${codex_path}"  ]] && defaults write "${prefs}" "cliPath.codex"  -string "${codex_path}"
  ok "引擎与路径已写入"
fi

# ── 9. 收尾 ─────────────────────────────────────────────────────────────────
# ── Mail.app 是否配了真实账户 ─────────────────────────────────────────────
# 实测过一台机器：Mail.app 里一个账户都没有（只有本地草稿箱），于是收件箱小组件
# 和邮件总结全是空白，用户完全不知道为什么，以为软件坏了。这里提前说清楚。
step "检查邮件 App"
mail_db=$(/bin/ls -d "$HOME/Library/Mail"/V*/MailData/"Envelope Index" 2>/dev/null | tail -1)
if [[ -n "${mail_db}" ]] && command -v sqlite3 >/dev/null 2>&1; then
  remote_boxes=$(sqlite3 -readonly "${mail_db}" \
    "select count(*) from mailboxes where url like 'imap://%' or url like 'ews://%' or url like 'pop://%';" 2>/dev/null)
  if [[ "${remote_boxes:-0}" -gt 0 ]]; then
    ok "邮件 App 里有 ${remote_boxes} 个邮箱"
  else
    warn "邮件 App 里还没有添加任何邮件账户"
    echo "    收件箱小组件和邮件总结读的就是「邮件」App 的数据，没有账户它们会是空白。"
    echo "    请打开「邮件」App → 添加账户 → 登录你的邮箱，等它同步完即可。"
  fi
else
  warn "读不到邮件 App 的本地索引（可能还没授予完全磁盘访问，装完再看）"
fi

step "最后三件事（需要你手动点）"
cat <<EOS
  1) ${BOLD}授予完全磁盘访问${RESET}：马上会打开系统设置，把列表里的 MailWidget 打开
     （不给也能用，但会退化成较慢的 AppleScript 模式并不断唤起 Mail）
  2) ${BOLD}添加小组件${RESET}：在桌面空白处点右键 → 编辑小组件 → 搜 MailWidget → 拖到桌面
  3) ${BOLD}日报定时任务${RESET}（可选）：点菜单栏信封图标 → 设置 → Gmail 日报 → 一键添加

EOS
/usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null
/usr/bin/open -a MailWidget 2>/dev/null
printf '%s完成。菜单栏右上角应该出现了一个信封图标。%s\n\n' "${GREEN}${BOLD}" "${RESET}"
