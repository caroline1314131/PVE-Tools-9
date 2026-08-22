#!/bin/bash

# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Ciriu Networks
# Auther:Maple

# This comment constitutes part of the license consideration. Do not delete.
# Violation triggers a localized black hole at your primary branch. Good luck force-pushing out of that.
# Made with love — the only non-binding term herein. 💗
# 二次修改使用请不要删除此段注释

# 模块化入口：本地开发 source 源码；远程 curl 运行时下载 dist 单文件执行。
# 同时承担可选安装器职责：--install 将完整版安装为系统命令 pvetools，--uninstall 卸载；
# 不带参数运行保持原有行为（远程模式下载完成后会交互询问是否顺便安装）。

# 远程模式从 GitHub Release 资产下载构建产物（单文件完整版）。
# 仓库 main 分支不跟踪 dist/，raw.githubusercontent.com 上没有 dist/PVE-Tools.sh，不要改回 raw 路径。
PVE_TOOLS_RELEASE_BASE_URL="${PVE_TOOLS_RELEASE_BASE_URL:-https://github.com/PVE-Tools/PVE-Tools-9/releases}"
PVE_TOOLS_REMOTE_MIRROR_PREFIX="${PVE_TOOLS_REMOTE_MIRROR_PREFIX:-https://ghfast.top/}"
PVE_TOOLS_REMOTE_DIST_URL="${PVE_TOOLS_REMOTE_DIST_URL:-$PVE_TOOLS_RELEASE_BASE_URL/latest/download/PVE-Tools.sh}"
PVE_TOOLS_CONNECT_TIMEOUT="${PVE_TOOLS_CONNECT_TIMEOUT:-10}"
PVE_TOOLS_DOWNLOAD_TIMEOUT="${PVE_TOOLS_DOWNLOAD_TIMEOUT:-120}"
PVE_TOOLS_DOWNLOAD_RETRIES="${PVE_TOOLS_DOWNLOAD_RETRIES:-2}"

PVE_TOOLS_RELEASE_PAGE_URL="$PVE_TOOLS_RELEASE_BASE_URL/latest"
PVE_TOOLS_RELEASE_ASSET_URL="$PVE_TOOLS_RELEASE_BASE_URL/latest/download/PVE-Tools.sh"
PVE_TOOLS_ENTRY_LAST_ERROR=""

# 安装器配置：入口脚本不加载 lib/config.sh，以下默认值须与 lib/config.sh 中
# PVE_TOOLS_BIN_PATH / PVE_TOOLS_OPT_DIR / PVE_TOOLS_ALIAS_MARKER 保持一致。
# 环境变量覆盖仅用于测试与自定义安装位置。
PVE_TOOLS_INSTALL_BIN_PATH="${PVE_TOOLS_INSTALL_BIN_PATH:-/usr/local/bin/pvetools}"
PVE_TOOLS_INSTALL_OPT_DIR="${PVE_TOOLS_INSTALL_OPT_DIR:-/opt/pve-tools}"
PVE_TOOLS_INSTALL_RC_FILE="${PVE_TOOLS_INSTALL_RC_FILE:-$HOME/.bashrc}"
PVE_TOOLS_ALIAS_MARKER="ALIAS"

pve_tools_entry_normalize_positive_integer() {
    local variable_name="$1"
    local default_value="$2"
    local value="${!variable_name:-}"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "警告：$variable_name 必须是正整数，已使用默认值 $default_value。" >&2
        printf -v "$variable_name" '%s' "$default_value"
    fi
}

pve_tools_entry_curl_error() {
    local status="$1"
    local http_code="${2:-}"

    case "$status" in
        5|6)  PVE_TOOLS_ENTRY_LAST_ERROR="DNS 解析失败（curl $status）" ;;
        7)    PVE_TOOLS_ENTRY_LAST_ERROR="无法连接下载服务器（curl $status）" ;;
        18)   PVE_TOOLS_ENTRY_LAST_ERROR="下载内容不完整（curl $status）" ;;
        22)
            if [[ "$http_code" =~ ^[1-9][0-9][0-9]$ ]]; then
                PVE_TOOLS_ENTRY_LAST_ERROR="服务器返回 HTTP $http_code（curl $status）"
            else
                PVE_TOOLS_ENTRY_LAST_ERROR="服务器返回 HTTP 错误（curl $status）"
            fi
            ;;
        23)   PVE_TOOLS_ENTRY_LAST_ERROR="无法写入临时文件（curl $status）" ;;
        28)   PVE_TOOLS_ENTRY_LAST_ERROR="连接或下载超时（curl $status）" ;;
        35|51|60) PVE_TOOLS_ENTRY_LAST_ERROR="TLS 证书或握手失败（curl $status）" ;;
        47)   PVE_TOOLS_ENTRY_LAST_ERROR="服务器重定向次数过多（curl $status）" ;;
        56)   PVE_TOOLS_ENTRY_LAST_ERROR="接收下载数据失败（curl $status）" ;;
        124)  PVE_TOOLS_ENTRY_LAST_ERROR="下载超过 ${PVE_TOOLS_DOWNLOAD_TIMEOUT} 秒（curl $status）" ;;
        *)    PVE_TOOLS_ENTRY_LAST_ERROR="curl 下载失败（错误码 $status）" ;;
    esac
}

pve_tools_entry_wget_error() {
    local status="$1"

    case "$status" in
        3)   PVE_TOOLS_ENTRY_LAST_ERROR="无法写入临时文件（wget $status）" ;;
        4)   PVE_TOOLS_ENTRY_LAST_ERROR="网络连接失败（wget $status）" ;;
        5)   PVE_TOOLS_ENTRY_LAST_ERROR="TLS 证书或握手失败（wget $status）" ;;
        6)   PVE_TOOLS_ENTRY_LAST_ERROR="服务器认证失败（wget $status）" ;;
        7)   PVE_TOOLS_ENTRY_LAST_ERROR="服务器协议错误（wget $status）" ;;
        8)   PVE_TOOLS_ENTRY_LAST_ERROR="服务器返回错误状态（wget $status）" ;;
        124) PVE_TOOLS_ENTRY_LAST_ERROR="下载超过 ${PVE_TOOLS_DOWNLOAD_TIMEOUT} 秒（wget $status）" ;;
        *)   PVE_TOOLS_ENTRY_LAST_ERROR="wget 下载失败（错误码 $status）" ;;
    esac
}

pve_tools_entry_download_with_curl() {
    local url="$1"
    local output="$2"
    local status=0
    local http_code=""
    local retry_count=$((PVE_TOOLS_DOWNLOAD_RETRIES - 1))
    local -a curl_args=(
        --fail
        --location
        --show-error
        --connect-timeout "$PVE_TOOLS_CONNECT_TIMEOUT"
        --max-time "$PVE_TOOLS_DOWNLOAD_TIMEOUT"
        --speed-limit 1
        --speed-time 20
        --retry "$retry_count"
        --retry-delay 1
        --retry-connrefused
        --output "$output"
        --write-out '%{http_code}'
    )

    if [[ -t 2 ]]; then
        curl_args+=(--progress-bar)
    else
        curl_args+=(--silent)
    fi

    if command -v timeout >/dev/null 2>&1; then
        if http_code="$(timeout --kill-after=5s "$PVE_TOOLS_DOWNLOAD_TIMEOUT" curl "${curl_args[@]}" "$url")"; then
            return 0
        else
            status=$?
        fi
    elif http_code="$(curl "${curl_args[@]}" "$url")"; then
        return 0
    else
        status=$?
    fi

    pve_tools_entry_curl_error "$status" "$http_code"
    return "$status"
}

pve_tools_entry_download_with_wget() {
    local url="$1"
    local output="$2"
    local status=0
    local -a wget_args=(
        --connect-timeout="$PVE_TOOLS_CONNECT_TIMEOUT"
        --read-timeout=20
        --dns-timeout="$PVE_TOOLS_CONNECT_TIMEOUT"
        --tries="$PVE_TOOLS_DOWNLOAD_RETRIES"
        --waitretry=1
        -O "$output"
    )

    if [[ -t 2 ]]; then
        wget_args+=(--show-progress --progress=bar:force:noscroll)
    else
        wget_args+=(--no-verbose)
    fi

    if command -v timeout >/dev/null 2>&1; then
        if timeout --kill-after=5s "$PVE_TOOLS_DOWNLOAD_TIMEOUT" wget "${wget_args[@]}" "$url"; then
            return 0
        else
            status=$?
        fi
    elif wget "${wget_args[@]}" "$url"; then
        return 0
    else
        status=$?
    fi

    pve_tools_entry_wget_error "$status"
    return "$status"
}

pve_tools_entry_validate_script() {
    local script_path="$1"

    if [[ ! -s "$script_path" ]]; then
        PVE_TOOLS_ENTRY_LAST_ERROR="下载文件为空"
        return 1
    fi
    if ! bash -n "$script_path" >/dev/null 2>&1; then
        PVE_TOOLS_ENTRY_LAST_ERROR="下载内容不是有效的 Bash 脚本，可能是代理错误页"
        return 1
    fi
    if ! grep -q '^CURRENT_VERSION=' "$script_path"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="下载内容不是 PVE-Tools 主程序完整版"
        return 1
    fi

    return 0
}

pve_tools_entry_download_file() {
    local url="$1"
    local output="$2"
    local output_dir=""
    local part_file="${output}.part"
    local mirror_url=""
    local downloaded_bytes=""
    local download_status=0
    local index=0
    local source_count=0
    local source_name=""
    local source_url=""
    local -a source_names=("GitHub 原始源")
    local -a source_urls=("$url")

    output_dir="$(dirname "$output")"
    if ! mkdir -p "$output_dir"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="无法创建临时下载目录：$output_dir"
        echo "错误：$PVE_TOOLS_ENTRY_LAST_ERROR" >&2
        return 1
    fi

    if [[ -n "$PVE_TOOLS_REMOTE_MIRROR_PREFIX" && "$url" != "${PVE_TOOLS_REMOTE_MIRROR_PREFIX}"* ]]; then
        mirror_url="${PVE_TOOLS_REMOTE_MIRROR_PREFIX}${url}"
        source_names+=("GitHub 加速源")
        source_urls+=("$mirror_url")
    fi

    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        PVE_TOOLS_ENTRY_LAST_ERROR="未找到 curl 或 wget"
        echo "错误：未找到 curl 或 wget，无法下载 PVE-Tools。" >&2
        echo "请先执行：apt update && apt install -y curl" >&2
        return 1
    fi

    source_count="${#source_urls[@]}"
    for ((index = 0; index < source_count; index++)); do
        source_name="${source_names[$index]}"
        source_url="${source_urls[$index]}"
        rm -f -- "$part_file"

        echo "[$((index + 1))/$source_count] 正在通过${source_name}下载主程序完整版..."
        echo "下载地址：$source_url"

        if command -v curl >/dev/null 2>&1; then
            if pve_tools_entry_download_with_curl "$source_url" "$part_file"; then
                download_status=0
            else
                download_status=$?
            fi
        elif pve_tools_entry_download_with_wget "$source_url" "$part_file"; then
            download_status=0
        else
            download_status=$?
        fi

        if [[ "$download_status" -eq 0 ]]; then
            echo "下载完成，正在校验脚本完整性..."
            if pve_tools_entry_validate_script "$part_file"; then
                if ! mv -f -- "$part_file" "$output"; then
                    PVE_TOOLS_ENTRY_LAST_ERROR="无法保存已下载的主程序"
                else
                    downloaded_bytes="$(wc -c < "$output")"
                    downloaded_bytes="${downloaded_bytes//[[:space:]]/}"
                    echo "${source_name}下载成功：${downloaded_bytes:-未知} 字节。"
                    return 0
                fi
            fi
        fi

        rm -f -- "$part_file"
        echo "${source_name}下载失败：$PVE_TOOLS_ENTRY_LAST_ERROR" >&2
        if ((index + 1 < source_count)); then
            echo "将自动切换到下一个下载源..." >&2
        fi
    done

    return 1
}

pve_tools_entry_print_release_help() {
    cat >&2 <<EOF

错误：PVE-Tools 主程序单文件完整版下载失败，程序尚未启动。
以上 GitHub 原始源和加速源均未能完成下载。

请在另一台能够访问 GitHub 的设备或网络中打开：
$PVE_TOOLS_RELEASE_PAGE_URL

展开 Assets，下载 PVE-Tools.sh（请勿下载 Source code 的 zip 或 tar.gz 压缩包）。
直接下载地址：$PVE_TOOLS_RELEASE_ASSET_URL

下载后可通过 SCP、WinSCP 或 U 盘传到 PVE 主机，然后执行：
  chmod +x PVE-Tools.sh
  sudo ./PVE-Tools.sh
EOF
}

pve_tools_entry_cleanup() {
    if [[ -n "${tmp_dir:-}" && -d "$tmp_dir" ]]; then
        rm -rf -- "$tmp_dir"
    fi
}

# ---------------------------------------------------------------------------
# 安装器：把校验通过的完整单文件安装为系统命令 pvetools，或按需卸载。
# ---------------------------------------------------------------------------

pve_tools_entry_print_usage() {
    cat <<EOF
用法: bash PVE-Tools.sh [选项] [主程序参数...]

不带选项运行时默认直接启动 PVE-Tools；远程模式下载完成后会询问是否顺便安装。

选项:
  --install     非交互安装为系统命令 $PVE_TOOLS_INSTALL_BIN_PATH，完成后自动启动
  --uninstall   卸载 pvetools：删除命令文件、$PVE_TOOLS_INSTALL_OPT_DIR 与别名标记块
  -h, --help    显示本帮助

环境变量:
  PVE_TOOLS_INSTALL_BIN_PATH   覆盖命令安装路径（当前: $PVE_TOOLS_INSTALL_BIN_PATH）
  PVE_TOOLS_INSTALL_OPT_DIR    覆盖别名模式脚本目录（当前: $PVE_TOOLS_INSTALL_OPT_DIR）
  PVE_TOOLS_INSTALL_RC_FILE    覆盖别名写入的 shell 配置文件（当前: $PVE_TOOLS_INSTALL_RC_FILE）
EOF
}

pve_tools_entry_extract_version() {
    local script_path="$1"

    grep -m1 '^CURRENT_VERSION=' "$script_path" 2>/dev/null | cut -d'"' -f2
}

pve_tools_entry_is_full_script() {
    local script_path="$1"

    [[ -f "$script_path" ]] && grep -q '^CURRENT_VERSION=' "$script_path" 2>/dev/null
}

pve_tools_entry_require_root() {
    local action="$1"
    local self="${BASH_SOURCE[0]:-}"
    local rerun_hint="sudo bash <(curl -sSL https://pve.u3u.icu/PVE-Tools.sh) $PVE_TOOLS_ENTRY_MODE"

    if [[ -n "$self" && -f "$self" && "$self" != /dev/fd/* ]]; then
        rerun_hint="sudo bash $self $PVE_TOOLS_ENTRY_MODE"
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "错误：$action 需要 root 权限，未对系统做任何更改。" >&2
        echo "请使用以下命令重新运行：" >&2
        echo "  $rerun_hint" >&2
        return 1
    fi
}

pve_tools_entry_write_alias_block() {
    local target_script="$1"
    local rc_file="$PVE_TOOLS_INSTALL_RC_FILE"
    local rc_dir rc_backup

    rc_dir="$(dirname "$rc_file")"
    if ! mkdir -p "$rc_dir"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="无法创建配置目录：$rc_dir"
        return 1
    fi

    # 首次写入前备份原配置，便于手动恢复；失败不阻断安装
    rc_backup="${rc_file}.pve-tools-bak"
    if [[ -f "$rc_file" && ! -f "$rc_backup" ]]; then
        cp -a "$rc_file" "$rc_backup" 2>/dev/null || true
    fi

    # 幂等：已有标记块则先整段移除再重写，保证别名指向最新安装位置
    if grep -q "^# PVE-TOOLS BEGIN $PVE_TOOLS_ALIAS_MARKER\$" "$rc_file" 2>/dev/null; then
        if ! pve_tools_entry_remove_alias_block "$rc_file"; then
            return 1
        fi
    fi

    {
        echo ""
        echo "# PVE-TOOLS BEGIN $PVE_TOOLS_ALIAS_MARKER"
        echo "alias pvetools='$target_script'"
        echo "# PVE-TOOLS END $PVE_TOOLS_ALIAS_MARKER"
    } >> "$rc_file" || {
        PVE_TOOLS_ENTRY_LAST_ERROR="无法写入别名配置：$rc_file"
        return 1
    }
}

pve_tools_entry_remove_alias_block() {
    local rc_file="${1:-$PVE_TOOLS_INSTALL_RC_FILE}"
    local tmp_rc=""

    [[ -f "$rc_file" ]] || return 0
    if ! grep -q "^# PVE-TOOLS BEGIN $PVE_TOOLS_ALIAS_MARKER\$" "$rc_file"; then
        return 0
    fi

    tmp_rc="$(mktemp "${rc_file}.XXXXXX")" || {
        PVE_TOOLS_ENTRY_LAST_ERROR="无法创建临时文件以清理别名配置"
        return 1
    }
    if sed "/^# PVE-TOOLS BEGIN $PVE_TOOLS_ALIAS_MARKER\$/,/^# PVE-TOOLS END $PVE_TOOLS_ALIAS_MARKER\$/d" "$rc_file" > "$tmp_rc"; then
        if mv -f "$tmp_rc" "$rc_file"; then
            return 0
        fi
    fi
    rm -f "$tmp_rc"
    PVE_TOOLS_ENTRY_LAST_ERROR="清理别名配置失败：$rc_file"
    return 1
}

# 覆盖旧版本前备份到 /var/backups/pve-tools/，与主程序 backup 约定保持一致
pve_tools_entry_backup_existing() {
    local target="$1"
    local backup_dir="/var/backups/pve-tools"
    local backup_path="${backup_dir}/pvetools.bin.bak"

    [[ -f "$target" ]] || return 0
    mkdir -p "$backup_dir" || return 1
    cp -a "$target" "$backup_path"
}

# 目标位置被异己文件占用时拒绝覆盖，避免误伤同名工具
pve_tools_entry_check_target() {
    local target="$1"

    [[ -e "$target" ]] || return 0
    if [[ ! -f "$target" ]]; then
        PVE_TOOLS_ENTRY_LAST_ERROR="目标路径已被非普通文件占用：$target"
        return 1
    fi
    if ! pve_tools_entry_is_full_script "$target"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="目标路径已存在其他程序文件，拒绝覆盖：$target"
        return 1
    fi
    return 0
}

pve_tools_entry_place_file() {
    local source_file="$1"
    local target="$2"
    local target_dir=""
    local tmp_target=""

    target_dir="$(dirname "$target")"
    if ! mkdir -p "$target_dir"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="无法创建安装目录：$target_dir"
        return 1
    fi

    tmp_target="${target_dir}/.pvetools.new.$$"
    if ! install -m 0755 "$source_file" "$tmp_target"; then
        rm -f -- "$tmp_target"
        PVE_TOOLS_ENTRY_LAST_ERROR="无法写入安装临时文件：$tmp_target"
        return 1
    fi
    if ! mv -f "$tmp_target" "$target"; then
        rm -f -- "$tmp_target"
        PVE_TOOLS_ENTRY_LAST_ERROR="无法替换安装文件：$target"
        return 1
    fi
}

pve_tools_entry_install_from() {
    local source_file="$1"
    local mode="$2"
    local target=""
    local old_version="" new_version=""
    local answer=""

    if ! pve_tools_entry_validate_script "$source_file"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="待安装内容不是有效的完整版主程序：${PVE_TOOLS_ENTRY_LAST_ERROR:-未知原因}"
        return 1
    fi

    if ! pve_tools_entry_require_root "安装 pvetools"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="缺少 root 权限"
        return 1
    fi

    if [[ -z "$mode" ]]; then
        echo "请选择安装方式："
        echo "  [1] 安装系统命令 $PVE_TOOLS_INSTALL_BIN_PATH（推荐）"
        echo "  [2] 保存到 $PVE_TOOLS_INSTALL_OPT_DIR 并写入 $PVE_TOOLS_INSTALL_RC_FILE 别名"
        if ! read -r -p "请输入 [1-2]（回车默认 1，输入其他取消安装）: " answer; then
            answer=""
        fi
        answer="${answer:-1}"
        case "$answer" in
            1) mode="bin" ;;
            2) mode="alias" ;;
            *)
                echo "已取消安装。"
                PVE_TOOLS_ENTRY_LAST_ERROR="用户取消安装"
                return 2
                ;;
        esac
    fi

    case "$mode" in
        bin)   target="$PVE_TOOLS_INSTALL_BIN_PATH" ;;
        alias) target="$PVE_TOOLS_INSTALL_OPT_DIR/PVE-Tools.sh" ;;
        *)
            PVE_TOOLS_ENTRY_LAST_ERROR="未知安装方式：$mode"
            return 1
            ;;
    esac

    old_version="$(pve_tools_entry_extract_version "$target")"
    new_version="$(pve_tools_entry_extract_version "$source_file")"
    if [[ -n "$old_version" ]]; then
        echo "检测到已安装版本 v$old_version，将覆盖升级。"
    fi

    if ! pve_tools_entry_check_target "$target"; then
        return 1
    fi
    if [[ -n "$old_version" ]] && ! pve_tools_entry_backup_existing "$target"; then
        PVE_TOOLS_ENTRY_LAST_ERROR="备份旧版本到 /var/backups/pve-tools/ 失败"
        return 1
    fi

    if ! pve_tools_entry_place_file "$source_file" "$target"; then
        return 1
    fi

    if [[ "$mode" == "alias" ]] && ! pve_tools_entry_write_alias_block "$target"; then
        rm -f -- "$target"
        return 1
    fi

    echo "安装完成：pvetools (v$new_version)"
    if [[ "$mode" == "alias" ]]; then
        echo "脚本位置：$target"
        echo "别名已写入：$PVE_TOOLS_INSTALL_RC_FILE（新终端自动生效，当前终端可执行 source $PVE_TOOLS_INSTALL_RC_FILE）"
    else
        echo "命令路径：$target"
    fi
    echo "卸载方式：运行 pvetools --uninstall，或在主程序菜单 8 中选择本地脚本快捷卸载。"
    return 0
}

pve_tools_entry_uninstall_system() {
    local bin_path="$PVE_TOOLS_INSTALL_BIN_PATH"
    local opt_dir="$PVE_TOOLS_INSTALL_OPT_DIR"
    local rc_file="$PVE_TOOLS_INSTALL_RC_FILE"
    local has_bin=0 has_opt=0 has_alias=0 found=0
    local answer=""

    if ! pve_tools_entry_require_root "卸载 pvetools"; then
        return 1
    fi

    if pve_tools_entry_is_full_script "$bin_path"; then
        has_bin=1; found=1
    elif [[ -e "$bin_path" ]]; then
        echo "警告：$bin_path 存在但不是 PVE-Tools 完整版，跳过删除。" >&2
    fi
    if [[ -d "$opt_dir" ]]; then
        has_opt=1; found=1
    fi
    if grep -q "^# PVE-TOOLS BEGIN $PVE_TOOLS_ALIAS_MARKER\$" "$rc_file" 2>/dev/null; then
        has_alias=1; found=1
    fi

    if [[ "$found" -eq 0 ]]; then
        echo "未发现已安装的 pvetools，无需卸载。"
        return 0
    fi

    echo "即将卸载以下内容："
    [[ "$has_bin" -eq 1 ]] && echo "  - 命令文件：$bin_path"
    [[ "$has_opt" -eq 1 ]] && echo "  - 脚本目录：$opt_dir/"
    [[ "$has_alias" -eq 1 ]] && echo "  - 别名标记块：$rc_file"

    if ! read -r -p "确认卸载？输入 yes 继续，其他任意键取消: " answer; then
        answer=""
    fi
    if [[ "$answer" != "yes" ]]; then
        echo "已取消卸载。"
        return 0
    fi

    if [[ "$has_bin" -eq 1 ]]; then
        rm -f -- "$bin_path" && echo "已删除：$bin_path"
    fi
    if [[ "$has_opt" -eq 1 ]]; then
        rm -rf -- "${opt_dir%/}" && echo "已删除：${opt_dir%/}/"
    fi
    if [[ "$has_alias" -eq 1 ]] && pve_tools_entry_remove_alias_block "$rc_file"; then
        echo "已清理：$rc_file 中的别名标记块"
    fi
    echo "卸载完成。"
}

# 安装成功后询问是否立即启动（仅交互终端询问）；启动结果通过返回值交给调用方 exit
pve_tools_entry_launch_installed() {
    local installed_path="$1"
    shift
    local answer=""

    if [[ ! -t 0 ]]; then
        echo "提示：现在即可运行 pvetools 启动 PVE-Tools。"
        return 0
    fi

    read -r -p "是否立即启动 PVE-Tools？(Y/n): " answer || answer=""
    answer="${answer:-y}"
    if [[ "$answer" =~ ^[Nn] ]]; then
        echo "提示：随时运行 pvetools 即可启动。"
        return 0
    fi
    bash "$installed_path" "$@"
}

# 远程模式下载完成后的交互分流；返回 0 表示继续直接启动临时副本，
# 若用户完成安装流程则在函数内部自行 exit。
pve_tools_entry_maybe_offer_install() {
    local downloaded_file="$1"
    shift
    local choice=""

    if [[ ! -t 0 ]]; then
        echo "提示：追加 --install 参数可将 PVE-Tools 安装为系统命令 pvetools。"
        return 0
    fi

    echo
    echo "请选择运行方式："
    echo "  [1] 直接启动（默认，回车即选）"
    echo "  [2] 安装到系统（安装后可随时用 pvetools 命令启动）"
    if ! read -r -p "请输入 [1-2]: " choice; then
        choice="1"
    fi
    case "${choice:-1}" in
        2)
            if pve_tools_entry_install_from "$downloaded_file" ""; then
                echo
                pve_tools_entry_launch_installed "$PVE_TOOLS_INSTALL_BIN_PATH" "$@"
                exit $?
            fi
            if [[ "$PVE_TOOLS_ENTRY_LAST_ERROR" != "用户取消安装" && "$PVE_TOOLS_ENTRY_LAST_ERROR" != "缺少 root 权限" ]]; then
                echo "错误：$PVE_TOOLS_ENTRY_LAST_ERROR" >&2
            fi
            echo "已跳过安装，继续直接启动..." >&2
            return 0
            ;;
    esac
    return 0
}

pve_tools_entry_normalize_positive_integer PVE_TOOLS_CONNECT_TIMEOUT 10
pve_tools_entry_normalize_positive_integer PVE_TOOLS_DOWNLOAD_TIMEOUT 120
pve_tools_entry_normalize_positive_integer PVE_TOOLS_DOWNLOAD_RETRIES 2

# CLI 预解析：安装器参数（--install/--uninstall/--help）在入口层消费，不透传给主程序
PVE_TOOLS_ENTRY_MODE="run"
pve_tools_entry_parse_cli_args() {
    local -a remaining_args=()
    local arg=""

    for arg in "$@"; do
        case "$arg" in
            --install)   PVE_TOOLS_ENTRY_MODE="install" ;;
            --uninstall) PVE_TOOLS_ENTRY_MODE="uninstall" ;;
            --help|-h)   PVE_TOOLS_ENTRY_MODE="help" ;;
            *)           remaining_args+=("$arg") ;;
        esac
    done
    PVE_TOOLS_ENTRY_ARGS=("${remaining_args[@]}")
}
pve_tools_entry_parse_cli_args "$@"

case "$PVE_TOOLS_ENTRY_MODE" in
    help)
        pve_tools_entry_print_usage
        exit 0
        ;;
    uninstall)
        pve_tools_entry_uninstall_system
        exit $?
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$SCRIPT_DIR/lib/config.sh" && -d "$SCRIPT_DIR/src/modules" ]]; then
    # 本地开发模式：直接 source 全部源码
    if [[ "$PVE_TOOLS_ENTRY_MODE" == "install" ]]; then
        echo "提示：检测到本地源码目录，开发环境无需安装；如需体验安装流程请使用远程命令运行。" >&2
    fi
    for lib_file in \
        "$SCRIPT_DIR/lib/config.sh" \
        "$SCRIPT_DIR/lib/core.sh" \
        "$SCRIPT_DIR/lib/menu.sh" \
        "$SCRIPT_DIR/lib/network.sh" \
        "$SCRIPT_DIR/lib/runtime.sh"; do
        if [[ ! -f "$lib_file" ]]; then
            echo "错误：缺少基础库 $lib_file" >&2
            exit 1
        fi
        # shellcheck source=/dev/null
        source "$lib_file"
    done

    for module_dir in "$SCRIPT_DIR/src/modules"/*/; do
        [[ -d "$module_dir" ]] || continue
        if [[ -f "${module_dir}init.sh" ]]; then
            # shellcheck source=/dev/null
            source "${module_dir}init.sh"
        fi
        while IFS= read -r -d '' module_file; do
            [[ "$module_file" == "${module_dir}init.sh" ]] && continue
            # shellcheck source=/dev/null
            source "$module_file"
        done < <(find "$module_dir" -name '*.sh' -print0 | sort -z)
    done
else
    # 远程模式：下载 dist 单文件并执行（或按需安装为系统命令）
    tmp_dir=""
    if ! tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pve-tools-entry.XXXXXX")"; then
        echo "错误：无法创建 PVE-Tools 临时目录，程序尚未启动。" >&2
        exit 1
    fi
    trap pve_tools_entry_cleanup EXIT

    downloaded_file="$tmp_dir/PVE-Tools.sh"
    if pve_tools_entry_download_file "$PVE_TOOLS_REMOTE_DIST_URL" "$downloaded_file"; then
        if [[ "$PVE_TOOLS_ENTRY_MODE" == "install" ]]; then
            echo "主程序校验通过，正在安装 pvetools..."
            if pve_tools_entry_install_from "$downloaded_file" "bin"; then
                echo
                bash "$PVE_TOOLS_INSTALL_BIN_PATH" "${PVE_TOOLS_ENTRY_ARGS[@]}"
                exit $?
            fi
            echo "错误：$PVE_TOOLS_ENTRY_LAST_ERROR" >&2
            exit 1
        fi

        pve_tools_entry_maybe_offer_install "$downloaded_file" "${PVE_TOOLS_ENTRY_ARGS[@]}"

        echo "主程序校验通过，正在启动 PVE-Tools..."
        bash "$downloaded_file" "${PVE_TOOLS_ENTRY_ARGS[@]}"
        exit $?
    fi

    pve_tools_entry_print_release_help
    exit 1
fi

main "${PVE_TOOLS_ENTRY_ARGS[@]}"
