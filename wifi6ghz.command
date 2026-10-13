#!/bin/bash
# macOS Wi-Fi 6 GHz 非官方尝试；兼容系统自带的 Bash 3.2。
# 来源：https://prafiles.in/some-macos-hacks/（2024-03-25 的个人实测）
# 仅修改 Country 首选项；不能增加硬件能力，也不保证驱动采用该值。

set -euo pipefail
export LC_ALL=C
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077

PREFS_DOMAIN=/Library/Preferences/.GlobalPreferences
PREFS_FILE="${PREFS_DOMAIN}.plist"
STATE_DIR=/var/db/macos-wifi6ghz-country
LOCK_DIR=/var/run/macos-wifi6ghz-country.lock
DEFAULTS=/usr/bin/defaults
PLUTIL=/usr/bin/plutil
NETWORKSETUP=/usr/sbin/networksetup
PROFILER=/usr/sbin/system_profiler
LOCK_HELD=0
TEMP_BACKUP=''
WIFI_NEEDS_ON=0
WIFI_DEVICE=''

say() { printf '%s\n' "$*"; }
fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
用法：
  bash wifi6ghz.command enable [国家码] [--no-restart]
  bash wifi6ghz.command restore [--no-restart]
  bash wifi6ghz.command status
  bash wifi6ghz.command help

enable 默认国家码为 US，来自实测作者的配置。国家码必须是两个大写字母。
enable / restore 默认关闭再打开当前已开启的 Wi-Fi，连接会短暂中断。
--no-restart 可用于远程连接；之后自行关闭再打开 Wi-Fi。
status 只读取状态，不修改设置。无参数且在终端运行时显示菜单。

前提：Mac 网卡和路由器支持 Wi-Fi 6E / 7，路由器已开启 6 GHz。
还需手动关闭：系统设置 → 隐私与安全性 → 定位服务
→ 系统服务 → 详细信息 →「网络与无线」。

本方法不是官方解锁接口，不保证当前系统有效。
国家首选项、实际监管域、实际连接频段是不同的状态。
USAGE
}

cleanup() {
    if [ "$WIFI_NEEDS_ON" -eq 1 ] && [ -n "$WIFI_DEVICE" ]; then
        "$NETWORKSETUP" -setairportpower "$WIFI_DEVICE" on >/dev/null 2>&1 ||
            printf '请手动重新打开 Wi-Fi。\n' >&2
    fi
    if [ -n "$TEMP_BACKUP" ] && [ -d "$TEMP_BACKUP" ]; then
        /bin/rm -rf -- "$TEMP_BACKUP"
    fi
    if [ "$LOCK_HELD" -eq 1 ]; then
        /bin/rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

get_wifi_device() {
    "$NETWORKSETUP" -listallhardwareports 2>/dev/null |
        /usr/bin/awk '
            /^Hardware Port:/ { wifi = ($0 ~ /^Hardware Port: (Wi-Fi|AirPort)$/) }
            wifi && /^Device:/ && !printed { print $2; printed=1 }
        '
}

get_report() {
    "$PROFILER" SPAirPortDataType -detailLevel mini -timeout 20 2>/dev/null
}

location_note() {
    say '手动关闭「网络与无线」定位后再连接 6 GHz；脚本不自动修改定位权限。'
    say '路径：系统设置 → 隐私与安全性 → 定位服务 → 系统服务 → 详细信息。'
}

hardware_check() {
    local chip model report
    chip=$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || true)
    model=$(/usr/sbin/sysctl -n hw.model 2>/dev/null || true)
    say "硬件：${model:-未知}；${chip:-芯片信息不可用}"
    case "$chip" in
        'Apple M1'|'Apple M1 Pro'|'Apple M1 Max'|'Apple M1 Ultra')
            fail 'M1 系列 Mac 的内置网卡不支持 6 GHz；修改地区首选项无法增加硬件能力。'
            ;;
    esac
    # M2 MacBook Air（13/15 英寸）和 13 英寸 M2 MacBook Pro。
    case "$model" in
        Mac14,2|Mac14,15|Mac14,7)
            fail '这款 M2 MacBook 的内置网卡仅支持 Wi-Fi 6，不支持 6 GHz。'
            ;;
    esac
    report=$(get_report || true)
    if [ -z "$report" ]; then
        say '无法读取无线硬件信息；请自行确认机型支持 Wi-Fi 6E / 7。'
        return
    fi
    printf '%s\n' "$report" | /usr/bin/awk '/Supported PHY Modes:/ && !printed {print; printed=1}'
    if printf '%s\n' "$report" | /usr/bin/awk '
        /Supported Channels:/ && /6GHz/ { found=1 }
        END { exit !found }
    '; then
        say '当前支持信道列表包含 6 GHz。'
    else
        say '当前支持信道列表未列出 6 GHz；可能是地区限制，也可能是硬件不支持。'
        say '802.11ax 本身不能证明支持 Wi-Fi 6E。'
    fi
}

status() {
    local value report
    say 'Country 系统首选项：'
    if value=$("$DEFAULTS" read "$PREFS_DOMAIN" Country 2>/dev/null); then
        say "  $value"
    else
        say '  未读到该键（不存在或当前用户无读取权限）。'
    fi
    say '当前连接信息（不显示网络名称、密码或 MAC 地址）：'
    report=$(get_report || true)
    if [ -z "$report" ]; then
        say '  无法读取；也可按住 Option 点击菜单栏 Wi-Fi 查看信道。'
        return
    fi
    printf '%s\n' "$report" | /usr/bin/awk '
        /Current Network Information:/ { active=1; next }
        /Other Local Wi-Fi Networks:/ { active=0 }
        active && /^[[:space:]]*(PHY Mode|Channel|Country Code):/ { print; fields++ }
        END { if (!fields) print "  没有可读取的当前连接信息；请先连接路由器。" }
    '
    if printf '%s\n' "$report" | /usr/bin/awk '
        /Current Network Information:/ { active=1; next }
        /Other Local Wi-Fi Networks:/ { active=0 }
        active && /^[[:space:]]*Channel:/ && /6GHz/ { found=1 }
        END { exit !found }
    '; then
        say '结果：检测到当前连接使用 6 GHz。'
    else
        say '结果：尚未检测到当前连接使用 6 GHz。'
    fi
}

require_root() {
    if [ "$EUID" -ne 0 ]; then
        say '需要管理员权限来备份并修改系统首选项。密码输入时不会显示字符。'
        exec /usr/bin/sudo /bin/bash "$0" "$@"
    fi
}

lock_changes() {
    if ! /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        fail "另一个进程正在修改，或上次异常退出留下锁：$LOCK_DIR"
    fi
    LOCK_HELD=1
}

export_current() {
    if [ -e "$PREFS_FILE" ]; then
        "$PLUTIL" -lint "$PREFS_FILE" >/dev/null || return 1
        "$DEFAULTS" export "$PREFS_DOMAIN" -
    else
        "$PLUTIL" -create xml1 -
    fi
}

validate_backup() {
    [ ! -L "$STATE_DIR" ] && [ -d "$STATE_DIR" ] || fail '备份目录类型异常。'
    [ "$(/usr/bin/stat -f '%u' "$STATE_DIR")" = 0 ] || fail '备份目录不属于 root。'
    [ "$(/usr/bin/stat -f '%Lp' "$STATE_DIR")" = 700 ] || fail '备份目录权限不是 700。'
    [ -f "$STATE_DIR/complete" ] && [ ! -L "$STATE_DIR/complete" ] || fail '备份不完整。'
    [ -f "$STATE_DIR/original.plist" ] && [ ! -L "$STATE_DIR/original.plist" ] ||
        fail '原始首选项备份缺失。'
    "$PLUTIL" -lint "$STATE_DIR/original.plist" >/dev/null || fail '备份格式损坏。'
    [ -f "$STATE_DIR/key-state" ] && [ ! -L "$STATE_DIR/key-state" ] || fail '备份元数据缺失。'
    case "$(/bin/cat "$STATE_DIR/key-state")" in
        present)
            [ "$("$PLUTIL" -type Country "$STATE_DIR/original.plist")" = string ] ||
                fail '备份中的 Country 不是字符串。'
            ;;
        absent)
            if "$PLUTIL" -type Country "$STATE_DIR/original.plist" >/dev/null 2>&1; then
                fail '备份中键的状态与元数据不一致。'
            fi
            ;;
        *) fail '备份元数据不合法。' ;;
    esac
}

backup_original() {
    local pending
    if [ -e "$STATE_DIR" ] || [ -L "$STATE_DIR" ]; then
        validate_backup
        say "保留首次备份：$STATE_DIR"
        return
    fi
    pending="${STATE_DIR}.pending"
    /bin/mkdir "$pending" || fail "临时备份目录已存在或无法创建：$pending"
    TEMP_BACKUP="$pending"
    export_current > "$TEMP_BACKUP/original.plist" ||
        fail '无法备份现有系统首选项，未执行写入。'
    "$PLUTIL" -lint "$TEMP_BACKUP/original.plist" >/dev/null
    if "$PLUTIL" -type Country "$TEMP_BACKUP/original.plist" >/dev/null 2>&1; then
        [ "$("$PLUTIL" -type Country "$TEMP_BACKUP/original.plist")" = string ] ||
            fail '已有 Country 值不是字符串，无法用此脚本安全还原。'
        printf 'present\n' > "$TEMP_BACKUP/key-state"
    else
        printf 'absent\n' > "$TEMP_BACKUP/key-state"
    fi
    /usr/bin/touch "$TEMP_BACKUP/complete"
    /bin/chmod 700 "$TEMP_BACKUP"
    /bin/mv "$TEMP_BACKUP" "$STATE_DIR"
    TEMP_BACKUP=''
    say "原值已备份：$STATE_DIR"
}

restart_wifi() {
    local power
    if [ "$NO_RESTART" -eq 1 ]; then
        say '已跳过 Wi-Fi 重启；请稍后手动关闭再打开 Wi-Fi。'
        return
    fi
    WIFI_DEVICE=$(get_wifi_device || true)
    if [ -z "$WIFI_DEVICE" ]; then
        say '未识别到 Wi-Fi 接口；请手动关闭再打开 Wi-Fi。'
        return
    fi
    power=$("$NETWORKSETUP" -getairportpower "$WIFI_DEVICE" 2>/dev/null || true)
    case "$power" in
        *': On') ;;
        *': Off') say 'Wi-Fi 原来已关闭，保持关闭。'; return ;;
        *) say '无法确认 Wi-Fi 开关状态，未重启；请手动操作。'; return ;;
    esac
    say "正在重启 Wi-Fi（$WIFI_DEVICE），连接会短暂中断……"
    WIFI_NEEDS_ON=1
    "$NETWORKSETUP" -setairportpower "$WIFI_DEVICE" off
    /bin/sleep 2
    "$NETWORKSETUP" -setairportpower "$WIFI_DEVICE" on
    WIFI_NEEDS_ON=0
    say 'Wi-Fi 已重新打开；重新连接后运行 status 查看实际频段。'
}

enable() {
    hardware_check
    backup_original
    "$DEFAULTS" write "$PREFS_DOMAIN" Country -string "$COUNTRY"
    [ "$("$DEFAULTS" read "$PREFS_DOMAIN" Country)" = "$COUNTRY" ] ||
        fail '写入后的读回值不一致；原始备份仍保留，可运行 restore。'
    say "已写入 Country=$COUNTRY；这只确认首选项写入成功，不代表 6 GHz 已解锁。"
    location_note
    restart_wifi
}

restore() {
    local old_value current archive
    if [ ! -e "$STATE_DIR" ] && [ ! -L "$STATE_DIR" ]; then
        say '没有待恢复的备份；未修改任何首选项。'
        return
    fi
    validate_backup
    current=$(export_current) || fail '无法读取当前首选项，未执行恢复；备份已保留。'
    if [ "$(/bin/cat "$STATE_DIR/key-state")" = present ]; then
        # 哨兵保留字符串末尾的换行，包括空字符串。
        old_value=$("$PLUTIL" -extract Country raw -expect string -n -o - \
            "$STATE_DIR/original.plist" && printf '.')
        old_value=${old_value%.}
        "$DEFAULTS" write "$PREFS_DOMAIN" Country -string "$old_value"
        current=$("$DEFAULTS" export "$PREFS_DOMAIN" - |
            "$PLUTIL" -extract Country raw -expect string -n -o - - && printf '.')
        [ "${current%.}" = "$old_value" ] || fail '恢复后读回值不一致，备份已保留。'
        say '已恢复原来的 Country 字符串。'
    else
        if printf '%s\n' "$current" | "$PLUTIL" -type Country - >/dev/null 2>&1; then
            "$DEFAULTS" delete "$PREFS_DOMAIN" Country
        fi
        current=$(export_current) || fail '无法验证恢复结果，备份已保留。'
        if printf '%s\n' "$current" | "$PLUTIL" -type Country - >/dev/null 2>&1; then
            fail 'Country 键仍然存在，备份已保留。'
        fi
        say '原来没有 Country 键，已删除脚本新增的键。'
    fi
    # 只还原 Country，不覆盖这期间对其他首选项的更改。
    archive="${STATE_DIR}.restored.$(/bin/date +%Y%m%d-%H%M%S).$$"
    /bin/mv "$STATE_DIR" "$archive"
    say "备份已归档：$archive"
    say '若之前手动关闭了「网络与无线」，请在系统设置中重新开启。'
    restart_wifi
}

[ "$(/usr/bin/uname -s)" = Darwin ] || fail '此脚本仅适用于 macOS。'

ACTION=${1:-}
if [ -z "$ACTION" ]; then
    if [ ! -t 0 ]; then usage; exit 0; fi
    say 'macOS 6 GHz Wi-Fi 非官方尝试'
    say '1) 尝试启用（US）  2) 查看状态  3) 恢复原值  4) 退出'
    printf '请选择 [1-4]：'
    IFS= read -r choice || exit 0
    case "$choice" in
        1) set -- enable US ;;
        2) set -- status ;;
        3) set -- restore ;;
        4) exit 0 ;;
        *) fail '无效选项。' ;;
    esac
    ACTION=$1
fi

COUNTRY=US
NO_RESTART=0
case "$ACTION" in
    help|-h|--help) usage; exit 0 ;;
    status)
        [ "$#" -eq 1 ] || fail 'status 不接受其他参数。'
        status
        exit 0
        ;;
    enable|restore)
        country_set=0
        args=("$@")
        shift
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --no-restart) NO_RESTART=1 ;;
                *)
                    if [ "$ACTION" = enable ] && [ "$country_set" -eq 0 ] &&
                        [[ "$1" =~ ^[A-Z]{2}$ ]]; then
                        COUNTRY=$1
                        country_set=1
                    else
                        fail "无效参数：$1"
                    fi
                    ;;
            esac
            shift
        done
        require_root "${args[@]}"
        lock_changes
        "$ACTION"
        ;;
    *) usage; fail "未知操作：$ACTION" ;;
esac
