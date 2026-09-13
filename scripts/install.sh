#!/bin/bash

# 构建、签名并事务式安装 MailWidget 到 /Applications。
#
# 从原 GmailDailyWidget/scripts/install.sh 移植：签名校验、事务式替换、失败回滚、
# pluginkit 注册与校验的逻辑逐条保留，只改了 bundle ID / 目标名 / App Group。
# 去掉了原脚本的图标生成步骤 —— MailWidget 的 AppIcon 是已提交的 PNG，不从 SVG 生成。
#
# 必须装到 /Applications 而不是从 DerivedData 直接跑：外部 agent 的定时任务需要一个
# 稳定的绝对路径来调用 `--ingest`。

set -euo pipefail

readonly APP_NAME="MailWidget"
readonly APP_BUNDLE_NAME="${APP_NAME}.app"
readonly HOST_BUNDLE_ID="com.kris.mailwidget"
readonly EXTENSION_BUNDLE_ID="com.kris.mailwidget.widget"
readonly EXTENSION_BUNDLE_NAME="MailWidgetExtension.appex"
readonly SCHEME_NAME="MailWidget"
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SPEC_FILE="${ROOT_DIR}/project.yml"
readonly PROJECT_FILE="${ROOT_DIR}/MailWidget.xcodeproj"
readonly DERIVED_DATA_DIR="${ROOT_DIR}/.build/DerivedData"
readonly BUILD_LOG="${ROOT_DIR}/.build/xcodebuild.log"
readonly BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/Release/${APP_BUNDLE_NAME}"
readonly INSTALL_APP="/Applications/${APP_BUNDLE_NAME}"
readonly USER_DATA_DIR="${HOME}/Library/Application Support/GmailDailyWidget"
readonly LSREGISTER_BIN="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

INSTALL_TRANSACTION_ACTIVE=0
INSTALL_PREVIOUS_PRESENT=0
INSTALL_REPLACE_STARTED=0
INSTALL_USE_SUDO=0
INSTALL_STAGING_APP=""
INSTALL_BACKUP_APP=""

log() {
  printf '[MailWidget] %s\n' "$*"
}

fail() {
  printf '[MailWidget] ERROR: %s\n' "$*" >&2
  exit 1
}

run_install_command() {
  if [[ "${INSTALL_USE_SUDO}" -eq 1 ]]; then
    /usr/bin/sudo "$@"
  else
    "$@"
  fi
}

find_full_xcode() {
  local requested_dir
  local selected_dir
  local app
  local candidates=()

  requested_dir="${DEVELOPER_DIR:-}"
  if [[ -n "${requested_dir}" ]]; then
    if [[ -x "${requested_dir}/usr/bin/xcodebuild" &&
          "${requested_dir}" == */Contents/Developer ]]; then
      printf '%s\n' "${requested_dir}"
      return
    fi
    fail "DEVELOPER_DIR=${requested_dir} 不是完整 Xcode 的 Contents/Developer。"
  fi

  selected_dir="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [[ "${selected_dir}" == */Contents/Developer ]] &&
     [[ -x "${selected_dir}/usr/bin/xcodebuild" ]]; then
    printf '%s\n' "${selected_dir}"
    return
  fi

  shopt -s nullglob
  for app in /Applications/Xcode*.app; do
    if [[ -x "${app}/Contents/Developer/usr/bin/xcodebuild" ]]; then
      candidates+=("${app}/Contents/Developer")
    fi
  done
  shopt -u nullglob

  if [[ ${#candidates[@]} -eq 0 ]]; then
    fail "未找到完整 Xcode。请先安装 Xcode；仅有 /Library/Developer/CommandLineTools 不够构建 WidgetKit extension。"
  fi

  if [[ ${#candidates[@]} -gt 1 ]]; then
    printf '[MailWidget] 找到多个 Xcode：\n' >&2
    printf '  %s\n' "${candidates[@]}" >&2
    fail "请用 DEVELOPER_DIR=/Applications/<Xcode>.app/Contents/Developer 再运行本脚本，避免选错版本。"
  fi

  printf '%s\n' "${candidates[0]}"
}

resolve_signing() {
  local apple_identity_lines
  local certificate_hash
  local certificate_pem
  local certificate_subject
  local identities
  local identity_hash
  local team_ids
  local team_count
  local identity_line
  local identity_name
  local identity_records=""
  local selected_record
  local team_id

  identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
  apple_identity_lines="$(printf '%s\n' "${identities}" |
    /usr/bin/grep '"Apple Development:' || true)"

  while IFS= read -r identity_line; do
    [[ -n "${identity_line}" ]] || continue
    identity_hash="$(printf '%s\n' "${identity_line}" | /usr/bin/awk '{ print $2 }')"
    identity_name="$(printf '%s\n' "${identity_line}" |
      /usr/bin/sed -nE 's/^[[:space:]]*[0-9]+\) [A-F0-9]{40} "(.*)"$/\1/p')"
    [[ "${identity_hash}" =~ ^[A-F0-9]{40}$ && -n "${identity_name}" ]] ||
      fail "无法解析 Apple Development signing identity。"

    certificate_pem="$(/usr/bin/security find-certificate -c "${identity_name}" -p 2>/dev/null || true)"
    [[ -n "${certificate_pem}" ]] ||
      fail "Keychain 中找不到 signing identity 对应的证书：${identity_name}"

    certificate_hash="$(printf '%s\n' "${certificate_pem}" |
      /usr/bin/openssl x509 -noout -fingerprint -sha1 2>/dev/null |
      /usr/bin/sed -n 's/^SHA1 Fingerprint=//p' |
      /usr/bin/tr -d ':')"
    [[ "${certificate_hash}" == "${identity_hash}" ]] ||
      fail "证书与 signing identity 的 SHA-1 不匹配：${identity_name}"

    certificate_subject="$(printf '%s\n' "${certificate_pem}" |
      /usr/bin/openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)"
    team_id="$(printf '%s\n' "${certificate_subject}" |
      /usr/bin/sed -nE 's/.*[,]OU=([A-Z0-9]{10})(,|$).*/\1/p')"
    [[ -n "${team_id}" ]] ||
      fail "无法从 Apple Development certificate 的 subject OU 解析 Team ID：${identity_name}"

    identity_records+="${identity_hash}|${team_id}|${identity_name}"$'\n'
  done <<<"${apple_identity_lines}"

  team_ids="$(printf '%s\n' "${identity_records}" |
    /usr/bin/awk -F'|' 'NF >= 2 { print $2 }' |
    /usr/bin/sort -u)"

  if [[ -n "${MAILWIDGET_TEAM_ID:-}" ]]; then
    TEAM_ID="${MAILWIDGET_TEAM_ID}"
    if [[ ${#TEAM_ID} -ne 10 || "${TEAM_ID}" == *[!A-Z0-9]* ]]; then
      fail "MAILWIDGET_TEAM_ID 必须是 10 位大写字母或数字。"
    fi
  else
    team_count="$(printf '%s\n' "${team_ids}" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
    if [[ "${team_count}" -eq 0 ]]; then
      fail "没有 Apple Development 签名身份。请在 Xcode > Settings > Accounts 登录 Apple ID，并创建 Apple Development certificate。"
    fi
    if [[ "${team_count}" -gt 1 ]]; then
      printf '[MailWidget] 可用 Team ID：\n%s\n' "${team_ids}" >&2
      fail "存在多个签名团队。请用 MAILWIDGET_TEAM_ID=<TEAM_ID> ./scripts/install.sh 明确选择。"
    fi
    TEAM_ID="${team_ids}"
  fi

  selected_record="$(printf '%s\n' "${identity_records}" |
    /usr/bin/awk -F'|' -v team="${TEAM_ID}" '$2 == team { print; exit }')"
  [[ -n "${selected_record}" ]] ||
    fail "Keychain 中没有属于 Team ${TEAM_ID} 的 Apple Development certificate。"

  SIGNING_IDENTITY_HASH="${selected_record%%|*}"
  [[ "${SIGNING_IDENTITY_HASH}" =~ ^[A-F0-9]{40}$ ]] ||
    fail "无法解析 Apple Development certificate 的 SHA-1 identity。"

  APP_GROUP_IDENTIFIER="${TEAM_ID}.com.kris.mailwidget"

  # project.yml 不再写死任何人的 Team ID：entitlements 与 Info.plist 里写的是
  # $(DEVELOPMENT_TEAM).com.kris.mailwidget，而 DEVELOPMENT_TEAM 由下面这个环境
  # 变量在 xcodegen generate 时注入。这样别人克隆下来用自己的签名身份就能直接构建。
  export MAILWIDGET_TEAM_ID="${TEAM_ID}"

  # 先确认模板确实是占位符形式，省得 project.yml 被改回字面量后签名到一半才发现。
  if ! /usr/bin/grep -q '\$(DEVELOPMENT_TEAM)\.com\.kris\.mailwidget' "${SPEC_FILE}"; then
    fail "project.yml 的 App Group 不是 \$(DEVELOPMENT_TEAM).com.kris.mailwidget 占位形式，无法按签名团队自动适配。"
  fi
}

resolve_build_version() {
  local timestamp_version
  local installed_version=""

  timestamp_version="$(/bin/date -u '+%Y%m%d%H%M%S')"
  if [[ -f "${INSTALL_APP}/Contents/Info.plist" ]]; then
    installed_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
      "${INSTALL_APP}/Contents/Info.plist" 2>/dev/null || true)"
  fi

  BUILD_VERSION="${timestamp_version}"
  if [[ "${installed_version}" =~ ^[0-9]+$ && ${#installed_version} -le 18 ]] &&
     (( 10#${installed_version} >= 10#${timestamp_version} )); then
    BUILD_VERSION="$((10#${installed_version} + 1))"
  fi
}

codesign_details() {
  /usr/bin/codesign --display --verbose=4 "$1" 2>&1
}

verify_signed_item() {
  local item_path="$1"
  local expected_bundle_id="$2"
  local entitlements_file="$3"
  local details
  local actual_team
  local actual_bundle_id
  local actual_group

  /usr/bin/codesign --verify --strict --verbose=2 "${item_path}"
  details="$(codesign_details "${item_path}")"

  printf '%s\n' "${details}" | /usr/bin/grep -q '^Authority=Apple Development:' ||
    fail "${item_path} 不是 Apple Development 签名。安装脚本不会用 ad-hoc 重签。"
  if printf '%s\n' "${details}" | /usr/bin/grep -q '^Signature=adhoc$'; then
    fail "检测到 ad-hoc 签名：${item_path}"
  fi

  actual_team="$(printf '%s\n' "${details}" | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1)"
  [[ "${actual_team}" == "${TEAM_ID}" ]] ||
    fail "${item_path} 的 TeamIdentifier=${actual_team:-<空>}，预期 ${TEAM_ID}。"

  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${item_path}/Contents/Info.plist" 2>/dev/null || true)"
  [[ "${actual_bundle_id}" == "${expected_bundle_id}" ]] ||
    fail "${item_path} 的 bundle ID=${actual_bundle_id:-<空>}，预期 ${expected_bundle_id}。"

  /usr/bin/codesign --display --entitlements :- "${item_path}" >"${entitlements_file}" 2>/dev/null
  actual_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "${entitlements_file}" 2>/dev/null || true)"
  [[ "${actual_group}" == "${APP_GROUP_IDENTIFIER}" ]] ||
    fail "${item_path} 的 App Group=${actual_group:-<空>}，预期 ${APP_GROUP_IDENTIFIER}。"
}

request_widget_exit() {
  local extension_path="$1"

  /usr/bin/pkill -TERM -x "${APP_NAME}" 2>/dev/null || true
  /usr/bin/pkill -TERM -x "MailWidgetExtension" 2>/dev/null || true
  if [[ -d "${extension_path}" ]]; then
    /usr/bin/pluginkit -r "${extension_path}" >/dev/null 2>&1 || true
  fi
}

verify_plugin_registration() {
  local extension_path="$1"
  local plugin_record=""
  local attempt

  for attempt in 1 2 3 4 5; do
    plugin_record="$(/usr/bin/pluginkit -m -A -D -v \
      -p com.apple.widgetkit-extension \
      -i "${EXTENSION_BUNDLE_ID}" 2>/dev/null || true)"
    if [[ "${plugin_record}" == *"${EXTENSION_BUNDLE_ID}("* &&
          "${plugin_record}" == *"${extension_path}"* ]]; then
      return
    fi
    /bin/sleep 1
  done

  fail "pluginkit 未把 ${EXTENSION_BUNDLE_ID} 注册到 ${extension_path}。"
}

rollback_install() {
  local exit_status="${1:-1}"
  local installed_extension="${INSTALL_APP}/Contents/PlugIns/${EXTENSION_BUNDLE_NAME}"

  trap - EXIT HUP INT TERM
  set +e

  if [[ "${INSTALL_TRANSACTION_ACTIVE}" -eq 1 ]]; then
    printf '[MailWidget] 安装未完成，正在恢复旧版本。\n' >&2

    if [[ "${INSTALL_APP}" == "/Applications/MailWidget.app" &&
          "${INSTALL_STAGING_APP}" == /Applications/.MailWidget.app.install.* &&
          "${INSTALL_BACKUP_APP}" == /Applications/.MailWidget.app.previous.* ]]; then
      run_install_command /bin/rm -rf "${INSTALL_STAGING_APP}"
      if [[ "${INSTALL_PREVIOUS_PRESENT}" -eq 1 ]] &&
         run_install_command /bin/test -e "${INSTALL_BACKUP_APP}"; then
        request_widget_exit "${installed_extension}"
        run_install_command /bin/rm -rf "${INSTALL_APP}"
        run_install_command /bin/mv "${INSTALL_BACKUP_APP}" "${INSTALL_APP}"
        /usr/bin/pluginkit -a "${INSTALL_APP}/Contents/PlugIns/${EXTENSION_BUNDLE_NAME}" >/dev/null 2>&1 || true
        printf '[MailWidget] 已恢复：%s\n' "${INSTALL_APP}" >&2
      elif [[ "${INSTALL_PREVIOUS_PRESENT}" -eq 1 ]] &&
           run_install_command /bin/test -e "${INSTALL_APP}"; then
        /usr/bin/pluginkit -a "${INSTALL_APP}/Contents/PlugIns/${EXTENSION_BUNDLE_NAME}" >/dev/null 2>&1 || true
        printf '[MailWidget] 旧版本未被替换，已重新注册其 Widget extension。\n' >&2
      elif [[ "${INSTALL_PREVIOUS_PRESENT}" -eq 0 &&
              "${INSTALL_REPLACE_STARTED}" -eq 1 ]]; then
        request_widget_exit "${installed_extension}"
        run_install_command /bin/rm -rf "${INSTALL_APP}"
        run_install_command /bin/rm -rf "${INSTALL_BACKUP_APP}"
      fi
    else
      printf '[MailWidget] 临时路径校验失败；为安全起见未执行自动清理。\n' >&2
    fi
  fi

  if [[ "${exit_status}" -eq 0 ]]; then
    exit_status=1
  fi
  exit "${exit_status}"
}

install_app() {
  local extension_path="${BUILT_APP}/Contents/PlugIns/${EXTENSION_BUNDLE_NAME}"
  local install_extension="${INSTALL_APP}/Contents/PlugIns/${EXTENSION_BUNDLE_NAME}"
  local signature_dir="${ROOT_DIR}/.build/signature-entitlements"

  [[ -d "${BUILT_APP}" ]] || fail "Release 构建未产生 ${BUILT_APP}"
  [[ -d "${extension_path}" ]] || fail "App bundle 中缺少 ${EXTENSION_BUNDLE_NAME}"

  /bin/mkdir -p "${signature_dir}"
  verify_signed_item "${BUILT_APP}" "${HOST_BUNDLE_ID}" "${signature_dir}/host.plist"
  verify_signed_item "${extension_path}" "${EXTENSION_BUNDLE_ID}" "${signature_dir}/extension.plist"

  if [[ -e "${BUILT_APP}/Contents/embedded.provisionprofile" ||
        -e "${extension_path}/Contents/embedded.provisionprofile" ]]; then
    fail "构建产物包含 provisioning profile；停止安装，避免 Personal Team 的短期 profile 让 Widget 失效。"
  fi

  [[ "${INSTALL_APP}" == "/Applications/MailWidget.app" ]] || fail "安装目标异常。"
  INSTALL_STAGING_APP="/Applications/.MailWidget.app.install.$$"
  INSTALL_BACKUP_APP="/Applications/.MailWidget.app.previous.$$"
  INSTALL_PREVIOUS_PRESENT=0
  INSTALL_REPLACE_STARTED=0
  [[ "${INSTALL_STAGING_APP}" == /Applications/.MailWidget.app.install.* ]] || fail "临时安装路径异常。"
  [[ "${INSTALL_BACKUP_APP}" == /Applications/.MailWidget.app.previous.* ]] || fail "备份路径异常。"

  if [[ -w "/Applications" ]]; then
    log "安装到 ${INSTALL_APP}（当前管理员账户可直接写入 /Applications）"
  else
    INSTALL_USE_SUDO=1
    log "安装到 ${INSTALL_APP}（sudo 只用于 /Applications）"
    /usr/bin/sudo -v
  fi
  INSTALL_TRANSACTION_ACTIVE=1
  trap 'rollback_install $?' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  run_install_command /bin/rm -rf "${INSTALL_STAGING_APP}" "${INSTALL_BACKUP_APP}"
  run_install_command /usr/bin/ditto "${BUILT_APP}" "${INSTALL_STAGING_APP}"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "${INSTALL_STAGING_APP}"

  if run_install_command /bin/test -e "${INSTALL_APP}"; then
    INSTALL_PREVIOUS_PRESENT=1
    log "请求旧 app 与 Widget extension 退出并刷新注册"
    request_widget_exit "${install_extension}"
    run_install_command /bin/mv "${INSTALL_APP}" "${INSTALL_BACKUP_APP}"
  fi

  INSTALL_REPLACE_STARTED=1
  run_install_command /bin/mv "${INSTALL_STAGING_APP}" "${INSTALL_APP}"

  /usr/bin/codesign --verify --deep --strict --verbose=2 "${INSTALL_APP}"
  "${LSREGISTER_BIN}" -u "${BUILT_APP}" >/dev/null 2>&1 || true
  /usr/bin/pluginkit -r "${extension_path}" >/dev/null 2>&1 || true
  "${LSREGISTER_BIN}" -f -R -trusted "${INSTALL_APP}" >/dev/null
  /usr/bin/pluginkit -a "${install_extension}" ||
    fail "应用已安装，但 WidgetKit extension 注册失败。"
  verify_plugin_registration "${install_extension}"

  /bin/mkdir -p "${USER_DATA_DIR}"
  /usr/bin/open "${INSTALL_APP}"

  INSTALL_TRANSACTION_ACTIVE=0
  trap - EXIT HUP INT TERM
  run_install_command /bin/rm -rf "${INSTALL_BACKUP_APP}"
}

main() {
  local xcode_developer_dir
  local xcodebuild_bin
  local xcodegen_bin

  [[ -f "${SPEC_FILE}" ]] || fail "缺少 ${SPEC_FILE}"
  xcode_developer_dir="$(find_full_xcode)"
  export DEVELOPER_DIR="${xcode_developer_dir}"
  xcodebuild_bin="${DEVELOPER_DIR}/usr/bin/xcodebuild"

  log "使用 $(${xcodebuild_bin} -version | /usr/bin/head -n 1)（${DEVELOPER_DIR}）"
  if ! "${xcodebuild_bin}" -checkFirstLaunchStatus >/dev/null 2>&1; then
    log "完成 Xcode 首次启动组件与许可配置"
    # 实测大多数情况下不需要 sudo；先不带权限试一次，省掉一次密码提示。
    if ! "${xcodebuild_bin}" -runFirstLaunch >/dev/null 2>&1; then
      log "需要管理员权限完成 Xcode 组件安装"
      /usr/bin/sudo "${xcodebuild_bin}" -runFirstLaunch
    fi
  fi

  xcodegen_bin="$(command -v xcodegen || true)"
  [[ -n "${xcodegen_bin}" ]] ||
    fail "未安装 xcodegen。安装命令：brew install xcodegen"

  resolve_signing
  resolve_build_version
  log "签名团队：${TEAM_ID}；App Group：${APP_GROUP_IDENTIFIER}"
  log "构建版本：${BUILD_VERSION}"

  log "生成 Xcode project"
  (cd "${ROOT_DIR}" && "${xcodegen_bin}" generate --spec "${SPEC_FILE}")
  [[ -d "${PROJECT_FILE}" ]] || fail "xcodegen 未生成 ${PROJECT_FILE}"

  /bin/mkdir -p "${ROOT_DIR}/.build"
  log "开始 Release 构建 host app + WidgetKit extension"
  "${xcodebuild_bin}" \
    -project "${PROJECT_FILE}" \
    -scheme "${SCHEME_NAME}" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "${DERIVED_DATA_DIR}" \
    CURRENT_PROJECT_VERSION="${BUILD_VERSION}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${SIGNING_IDENTITY_HASH}" \
    CODE_SIGNING_REQUIRED=YES \
    PROVISIONING_PROFILE_SPECIFIER= \
    REGISTER_APP_GROUPS=NO \
    clean build 2>&1 | /usr/bin/tee "${BUILD_LOG}"

  install_app

  log "安装完成：${INSTALL_APP}"
  log "日报交接目录：${USER_DATA_DIR}"
  log "App Group 数据位于：${HOME}/Library/Group Containers/${APP_GROUP_IDENTIFIER}"
  log "如果菜单栏里数据源显示为 appleScript，去系统设置重新授予「完全磁盘访问」。"
}

main "$@"
