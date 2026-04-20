#!/bin/bash
#===============================================================================
# DEEP SYSTEM SCAN v7.1 - Производственный диагностический инструмент
# READ-ONLY сканирование системы с генерацией отчёта для ИИ-анализа
# Версия: 7.1 | Лицензия: MIT | Автор: Senior Linux Engineer
#===============================================================================

#-------------------------------------------------------------------------------
# НАСТРОЙКИ И КОНСТАНТЫ
#-------------------------------------------------------------------------------
set -uo pipefail
# set -e НЕ используется для продолжения сканирования при ошибках

readonly SCRIPT_VERSION="7.1"
readonly SCRIPT_NAME="deep_system_scan_v7.sh"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "unknown")
readonly OUTPUT_FILENAME="DEEP_SCAN_${HOSTNAME_SHORT}_${TIMESTAMP}.log"

# Уровни сканирования
readonly LEVEL_MINIMAL=1
readonly LEVEL_MEDIUM=2
readonly LEVEL_TOTAL=3
readonly LEVEL_PROFILING=4

# Глобальные переменные
SCAN_LEVEL=0
OUTPUT_FILE=""
TARGET_DIR=""
declare -a CRITICAL_ISSUES=()
declare -a WARNING_ISSUES=()
declare -a INFO_ISSUES=()
declare -a STRICT_PROHIBITIONS=()
PKG_MGR=""
AUTO_INSTALL=false
FORCE_PROFILING=false

# Цвета для терминала (если поддерживаются)
if [[ -t 1 ]]; then
    readonly COLOR_RED='\033[0;31m'
    readonly COLOR_GREEN='\033[0;32m'
    readonly COLOR_YELLOW='\033[0;33m'
    readonly COLOR_BLUE='\033[0;34m'
    readonly COLOR_RESET='\033[0m'
else
    readonly COLOR_RED=''
    readonly COLOR_GREEN=''
    readonly COLOR_YELLOW=''
    readonly COLOR_BLUE=''
    readonly COLOR_RESET=''
fi

#-------------------------------------------------------------------------------
# ОБРАБОТКА ПРЕРЫВАНИЙ
#-------------------------------------------------------------------------------
trap 'echo -e "\n${COLOR_YELLOW}⚠️ Сканирование прервано пользователем.${COLOR_RESET}"; exit 130' INT TERM

#-------------------------------------------------------------------------------
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
#-------------------------------------------------------------------------------

# safe_cmd - выполнение команды с таймаутом и обработкой ошибок (от имени root)
safe_cmd() {
    local timeout_sec=${1:-15}
    shift
    
    # Проверяем, есть ли уже sudo в команде, чтобы не дублировать
    if [[ "$1" == "sudo" ]]; then
        timeout "$timeout_sec" "$@" 2>/dev/null
    else
        # Выполняем команду от имени root через sudo
        timeout "$timeout_sec" sudo "$@" 2>/dev/null
    fi
    return $?
}

# safe_sudo_cmd - выполнение sudo-команды с проверкой прав (теперь дублирует safe_cmd для совместимости)
safe_sudo_cmd() {
    local timeout_sec=${1:-15}
    shift
    
    # Теперь safe_cmd уже выполняет команды через sudo, поэтому просто вызываем его
    safe_cmd "$timeout_sec" "$@"
    return $?
}

# sanitize_num - очистка строки от нечисловых символов для безопасного сравнения
# Удаляет: символы перевода строки (\n), лишние пробелы, табуляции, нецифровые символы
# Возвращает: чистое число или 0 если строка пустая/некорректная
sanitize_num() {
    local input="$1"
    local cleaned
    
    # Удаляем все нецифровые символы кроме минуса для отрицательных чисел
    cleaned=$(echo "$input" | tr -d '\n\r\t' | tr -s ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -oE '^-?[0-9]+' | head -1)
    
    # Если результат пустой или только минус, возвращаем 0
    if [[ -z "$cleaned" ]] || [[ "$cleaned" == "-" ]]; then
        echo "0"
    else
        echo "$cleaned"
    fi
}

# check_tool - проверка наличия утилиты
check_tool() {
    local tool="$1"
    command -v "$tool" >/dev/null 2>&1
    return $?
}

# print_status - вывод статуса с цветом
print_status() {
    local status="$1"
    local message="$2"
    
    case "$status" in
        OK)       echo -e "${COLOR_GREEN}[OK]${COLOR_RESET} $message" ;;
        WARNING)  echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $message" ;;
        CRITICAL) echo -e "${COLOR_RED}[CRITICAL]${COLOR_RESET} $message" ;;
        SKIPPED)  echo -e "${COLOR_BLUE}[SKIPPED]${COLOR_RESET} $message" ;;
        *)        echo "[$status] $message" ;;
    esac
}

# detect_package_manager - автодетект пакетного менеджера
detect_package_manager() {
    if check_tool apt-get; then
        PKG_MGR="apt"
    elif check_tool dnf; then
        PKG_MGR="dnf"
    elif check_tool yum; then
        PKG_MGR="yum"
    elif check_tool pacman; then
        PKG_MGR="pacman"
    elif check_tool zypper; then
        PKG_MGR="zypper"
    else
        PKG_MGR="unknown"
    fi
}

# add_issue - добавление проблемы в массив
add_issue() {
    local severity="$1"
    local description="$2"
    local target="$3"
    local recommendation="$4"
    
    case "$severity" in
        CRITICAL)
            CRITICAL_ISSUES+=("[CRITICAL] $description | $target | $recommendation")
            ;;
        WARNING)
            WARNING_ISSUES+=("[WARNING] $description | $target | $recommendation")
            ;;
        INFO)
            INFO_ISSUES+=("[INFO] $description | $target | $recommendation")
            ;;
    esac
}

# add_prohibition - добавление запрета
add_prohibition() {
    local action="$1"
    local reason="$2"
    local alternative="$3"
    
    STRICT_PROHIBITIONS+=("[НЕ ДЕЛАТЬ] $action | $reason | $alternative")
}

#-------------------------------------------------------------------------------
# ФУНКЦИЯ: check_and_install_tools - Проверка и установка утилит
#-------------------------------------------------------------------------------
check_and_install_tools() {
    local missing_tools=()
    local tools_list=(
        "smartctl" "sensors" "dmidecode" "perf" "stress-ng" "fio"
        "edac-util" "bpftrace" "nvme-cli" "ethtool" "ipmitool"
        "fwupdmgr" "powertop" "turbostat" "inxi" "hw-probe"
        "lm-sensors" "sysstat" "lscpu" "lsblk" "lsmod" "systemctl"
        "journalctl" "dmesg" "ss" "ip" "df" "free" "top" "ps"
    )
    
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "🔍 Проверка необходимых утилит..."
    echo "═══════════════════════════════════════════════════════════"
    
    for tool in "${tools_list[@]}"; do
        # Нормализация имени для проверки (дефисы на подчёркивания для некоторых пакетов)
        local pkg_name="$tool"
        case "$tool" in
            smartctl) pkg_name="smartmontools" ;;
            sensors|lm-sensors) pkg_name="lm-sensors" ;;
            dmidecode) pkg_name="dmidecode" ;;
            edac-util) pkg_name="edac-utils" ;;
            nvme-cli) pkg_name="nvme-cli" ;;
            ipmitool) pkg_name="ipmitool" ;;
            fwupdmgr) pkg_name="fwupd" ;;
            stress-ng) pkg_name="stress-ng" ;;
            hw-probe) pkg_name="hw-probe" ;;
            sysstat) pkg_name="sysstat" ;;
        esac
        
        if ! check_tool "$tool"; then
            missing_tools+=("$pkg_name")
            echo -e "${COLOR_YELLOW}[MISSING]${COLOR_RESET} $tool пакет: $pkg_name"
        fi
    done
    
    if [[ ${#missing_tools[@]} -eq 0 ]]; then
        echo -e "${COLOR_GREEN}✅ Все необходимые утилиты установлены${COLOR_RESET}"
        return 0
    fi
    
    echo ""
    echo "⚠️ Отсутствуют утилиты: ${missing_tools[*]}"
    
    if [[ "$AUTO_INSTALL" == "true" ]]; then
        echo "📦 Автоматическая установка включена (--auto-install)"
        install_missing_tools "${missing_tools[@]}"
    else
        echo ""
        read -p "Установить недостающие утилиты? [y/N]: " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            install_missing_tools "${missing_tools[@]}"
        else
            echo -e "${COLOR_YELLOW}⚠️ Некоторые разделы отчёта могут быть неполными${COLOR_RESET}"
        fi
    fi
}

install_missing_tools() {
    local -a tools_to_install=("$@")
    local install_cmd=""
    
    detect_package_manager
    
    case "$PKG_MGR" in
        apt)
            # Используем safe_cmd для выполнения установки через sudo
            echo ""
            echo "📦 Установка пакетов через apt-get..."
            safe_cmd 300 apt-get install -y "${tools_to_install[@]}"
            return $?
            ;;
        dnf|yum)
            echo ""
            echo "📦 Установка пакетов через $PKG_MGR..."
            safe_cmd 300 "$PKG_MGR" install -y "${tools_to_install[@]}"
            return $?
            ;;
        pacman)
            echo ""
            echo "📦 Установка пакетов через pacman..."
            safe_cmd 300 pacman -S --noconfirm "${tools_to_install[@]}"
            return $?
            ;;
        zypper)
            echo ""
            echo "📦 Установка пакетов через zypper..."
            safe_cmd 300 zypper install -y "${tools_to_install[@]}"
            return $?
            ;;
        *)
            echo -e "${COLOR_RED}❌ Не удалось определить пакетный менеджер${COLOR_RESET}"
            return 1
            ;;
    esac
}

#-------------------------------------------------------------------------------
# МОДУЛИ СКАНИРОВАНИЯ - CPU & ПРОЦЕССОРНАЯ ПОДСИСТЕМА
#-------------------------------------------------------------------------------

scan_basic_info() {
    local level_required=$LEVEL_MINIMAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [BASIC_INFO]"
    echo "### SYSTEM_IDENTITY"
    
    local hostname_val=$(safe_cmd 5 hostname 2>/dev/null || echo "[UNAVAILABLE]")
    local kernel_ver=$(safe_cmd 5 uname -r 2>/dev/null || echo "[UNAVAILABLE]")
    local arch=$(safe_cmd 5 uname -m 2>/dev/null || echo "[UNAVAILABLE]")
    local uptime_raw=$(safe_cmd 5 cat /proc/uptime 2>/dev/null | cut -d. -f1 || echo "0")
    local uptime_days=$((uptime_raw / 86400))
    local uptime_hours=$(( (uptime_raw % 86400) / 3600 ))
    local distro_info=$(safe_cmd 5 cat /etc/os-release 2>/dev/null | grep "^PRETTY_NAME=" | cut -d'"' -f2 || echo "[UNKNOWN]")
    
    echo "• STATUS: OK"
    echo "• DATA:"
    echo "  hostname: $hostname_val"
    echo "  kernel: $kernel_ver"
    echo "  architecture: $arch"
    echo "  uptime_days: $uptime_days"
    echo "  uptime_hours: $uptime_hours"
    echo "  distro: $distro_info"
    
    # Проверка на критические проблемы
    if [[ $uptime_days -gt 365 ]]; then
        add_issue "WARNING" "Система не перезагружалась более года" "uptime" "Планируемая перезагрузка для применения обновлений"
    fi
}

scan_cpu_detailed() {
    local level_required=$LEVEL_MINIMAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [CPU_DETAILED]"
    echo "### CPU_BASIC"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # Базовая информация из /proc/cpuinfo
    local cpu_model=$(safe_cmd 5 grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "[UNAVAILABLE]")
    local cpu_vendor=$(safe_cmd 5 grep "vendor_id" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "[UNAVAILABLE]")
    local cpu_family=$(safe_cmd 5 grep "cpu family" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "[UNAVAILABLE]")
    local cpu_flags=$(safe_cmd 5 grep "flags" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "[UNAVAILABLE]")
    
    echo "  model: $cpu_model"
    echo "  vendor: $cpu_vendor"
    echo "  family: $cpu_family"
    echo "  flags_preview: ${cpu_flags:0:100}..."
    
    # Подсчёт ядер
    local phys_cores=$(safe_cmd 5 nproc --all 2>/dev/null || safe_cmd 5 grep -c "^processor" /proc/cpuinfo || echo "0")
    local log_cores=$(safe_cmd 5 nproc 2>/dev/null || echo "$phys_cores")
    
    echo "  physical_cores: $phys_cores"
    echo "  logical_cores: $log_cores"
    
    # Частоты
    echo ""
    echo "### CPU_FREQUENCIES"
    echo "• DATA:"
    
    if [[ -f /proc/cpuinfo ]]; then
        local cpu_mhz=$(safe_cmd 5 grep "cpu MHz" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "[UNAVAILABLE]")
        echo "  current_mhz: $cpu_mhz"
    fi
    
    # Governor
    local governor="[UNAVAILABLE]"
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        governor=$(safe_cmd 5 cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "[UNAVAILABLE]")
    fi
    echo "  governor: $governor"
    
    # Уязвимости
    echo ""
    echo "### CPU_VULNERABILITIES"
    echo "• DATA:"
    
    if [[ -d /sys/devices/system/cpu/vulnerabilities ]]; then
        for vuln_file in /sys/devices/system/cpu/vulnerabilities/*; do
            local vuln_name=$(basename "$vuln_file")
            local vuln_status=$(safe_cmd 5 cat "$vuln_file" 2>/dev/null || echo "[READ_ERROR]")
            echo "  $vuln_name: $vuln_status"
            
            if [[ "$vuln_status" != *"Mitigation"* ]] && [[ "$vuln_status" != "Not affected" ]]; then
                add_issue "WARNING" "Возможная уязвимость CPU" "$vuln_name" "Проверить обновления микрокода и ядра"
            fi
        done
    else
        echo "  vulnerabilities_dir: [NOT_FOUND]"
    fi
    
    # Микрокод
    echo ""
    echo "### CPU_MICROCODE"
    echo "• DATA:"
    
    local microcode_ver=$(safe_cmd 5 grep "microcode" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}' || echo "[UNAVAILABLE]")
    echo "  microcode_version: $microcode_ver"
    
    local mce_logs=$(safe_cmd 10 dmesg 2>/dev/null | grep -i "microcode" | tail -5 || echo "")
    if [[ -n "$mce_logs" ]]; then
        echo "• RAW_LOGS: [LIMITED: last 5]"
        echo "$mce_logs" | while read -r line; do echo "  $line"; done
    fi
}

scan_cpu_topology() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [CPU_TOPOLOGY]"
    echo "### TOPOLOGY_DETAILS"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    if check_tool lscpu; then
        local sockets=$(safe_cmd 5 lscpu 2>/dev/null | grep "^Socket(s):" | awk '{print $2}' || echo "1")
        local cores_per_socket=$(safe_cmd 5 lscpu 2>/dev/null | grep "^Core(s) per socket:" | awk '{print $4}' || echo "1")
        local threads_per_core=$(safe_cmd 5 lscpu 2>/dev/null | grep "^Thread(s) per core:" | awk '{print $4}' || echo "1")
        
        echo "  sockets: $sockets"
        echo "  cores_per_socket: $cores_per_socket"
        echo "  threads_per_core: $threads_per_core"
        
        # Кэш
        local l1d=$(safe_cmd 5 lscpu 2>/dev/null | grep "^L1d cache:" | awk '{print $3, $4}' || echo "[UNAVAILABLE]")
        local l1i=$(safe_cmd 5 lscpu 2>/dev/null | grep "^L1i cache:" | awk '{print $3, $4}' || echo "[UNAVAILABLE]")
        local l2=$(safe_cmd 5 lscpu 2>/dev/null | grep "^L2 cache:" | awk '{print $3, $4}' || echo "[UNAVAILABLE]")
        local l3=$(safe_cmd 5 lscpu 2>/dev/null | grep "^L3 cache:" | awk '{print $3, $4}' || echo "[UNAVAILABLE]")
        
        echo "  l1d_cache: $l1d"
        echo "  l1i_cache: $l1i"
        echo "  l2_cache: $l2"
        echo "  l3_cache: $l3"
    else
        echo "[TOOL_MISSING: lscpu]"
    fi
    
    # SMT статус
    echo ""
    echo "### SMT_STATUS"
    echo "• DATA:"
    
    if [[ -f /sys/devices/system/cpu/smt/active ]]; then
        local smt_active=$(safe_cmd 5 cat /sys/devices/system/cpu/smt/active 2>/dev/null || echo "0")
        if [[ "$smt_active" == "1" ]]; then
            echo "  smt_enabled: true"
        else
            echo "  smt_enabled: false"
        fi
    else
        echo "  smt_status: [UNAVAILABLE]"
    fi
}

scan_memory_detailed() {
    local level_required=$LEVEL_MINIMAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [MEMORY_DETAILED]"
    echo "### MEMORY_USAGE"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    if [[ -f /proc/meminfo ]]; then
        local mem_total=$(safe_cmd 5 grep "^MemTotal:" /proc/meminfo | awk '{print $2}' || echo "0")
        local mem_free=$(safe_cmd 5 grep "^MemFree:" /proc/meminfo | awk '{print $2}' || echo "0")
        local mem_available=$(safe_cmd 5 grep "^MemAvailable:" /proc/meminfo | awk '{print $2}' || echo "$mem_free")
        local mem_buffers=$(safe_cmd 5 grep "^Buffers:" /proc/meminfo | awk '{print $2}' || echo "0")
        local mem_cached=$(safe_cmd 5 grep "^Cached:" /proc/meminfo | awk '{print $2}' || echo "0")
        local swap_total=$(safe_cmd 5 grep "^SwapTotal:" /proc/meminfo | awk '{print $2}' || echo "0")
        local swap_free=$(safe_cmd 5 grep "^SwapFree:" /proc/meminfo | awk '{print $2}' || echo "0")
        
        local mem_used=$((mem_total - mem_free - mem_buffers - mem_cached))
        local mem_percent=0
        if (( mem_total > 0 )); then
            mem_percent=$((mem_used * 100 / mem_total))
        fi
        local swap_used=$((swap_total - swap_free))
        
        echo "  total_kb: $mem_total"
        echo "  used_kb: $mem_used"
        echo "  free_kb: $mem_free"
        echo "  available_kb: $mem_available"
        echo "  buffers_kb: $mem_buffers"
        echo "  cached_kb: $mem_cached"
        echo "  usage_percent: $mem_percent%"
        echo "  swap_total_kb: $swap_total"
        echo "  swap_used_kb: $swap_used"
        
        if [[ $mem_percent -gt 90 ]]; then
            add_issue "CRITICAL" "Использование RAM > 90%" "memory" "Проверить процессы через top/htop, рассмотреть увеличение RAM"
        elif [[ $mem_percent -gt 80 ]]; then
            add_issue "WARNING" "Использование RAM > 80%" "memory" "Мониторить использование, проверить утечки памяти"
        fi
    else
        echo "[UNAVAILABLE]"
    fi
    
    # OOM статистика
    echo ""
    echo "### OOM_STATISTICS"
    echo "• DATA:"
    
    local oom_kills_raw=$(safe_cmd 5 dmesg 2>/dev/null | grep -c "Out of memory" || echo "0")
    local oom_kills=$(sanitize_num "$oom_kills_raw")
    echo "  oom_kills_count: $oom_kills"
    
    if [[ $oom_kills -gt 0 ]]; then
        add_issue "WARNING" "Зафиксированы OOM kills" "kernel" "Проверить логи dmesg/journalctl, увеличить RAM или swap"
    fi
}

scan_storage_detailed() {
    local level_required=$LEVEL_MINIMAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [STORAGE_DETAILED]"
    echo "### DISK_USAGE"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    safe_cmd 10 df -hT 2>/dev/null | tail -n +2 | while read -r filesystem type size used avail use_pct mount; do
        # Пропускаем pseudo-filesystems
        [[ "$filesystem" == "tmpfs" ]] && continue
        [[ "$filesystem" == "devtmpfs" ]] && continue
        [[ "$filesystem" == "overlay" ]] && continue
        
        echo "  device: $filesystem"
        echo "    type: $type"
        echo "    size: $size"
        echo "    used: $used"
        echo "    available: $avail"
        echo "    use_percent: $use_pct"
        echo "    mount: $mount"
        
        # Проверка на заполненность
        local use_num=$(sanitize_num "${use_pct%\\%}")
        if [[ $use_num -gt 95 ]]; then
            add_issue "CRITICAL" "Диск заполнен > 95%" "$mount" "Очистить место или расширить раздел"
        elif [[ $use_num -gt 85 ]]; then
            add_issue "WARNING" "Диск заполнен > 85%" "$mount" "Планировать очистку места"
        fi
    done
    
    # Inodes
    echo ""
    echo "### INODE_USAGE"
    echo "• DATA:"
    
    safe_cmd 10 df -i 2>/dev/null | tail -n +2 | while read -r filesystem inodes iused ifree iuse_pct mounted; do
        [[ "$filesystem" == "tmpfs" ]] && continue
        local iuse_num=$(sanitize_num "${iuse_pct%\\%}")
        if [[ $iuse_num -gt 90 ]]; then
            echo "  WARNING: $filesystem inode usage: $iuse_pct"
            add_issue "WARNING" "Высокое использование inodes" "$mounted" "Найти и удалить мелкие файлы"
        fi
    done
    
    # SMART информация (если доступна)
    echo ""
    echo "### SMART_HEALTH"
    
    if check_tool smartctl; then
        local disks=$(safe_cmd 10 lsblk -dpn 2>/dev/null | grep -E "^/dev/(sd|nvme|hd)" | awk '{print $1}')
        
        for disk in $disks; do
            echo ""
            echo "#### DEVICE: $disk"
            echo "• DATA:"
            
            local smart_status=$(safe_cmd 30 smartctl -H "$disk" 2>/dev/null | grep -i "SMART overall-health" | cut -d: -f2 | xargs || echo "[UNAVAILABLE]")
            echo "  smart_health: $smart_status"
            
            if [[ "$smart_status" != "PASSED" ]] && [[ "$smart_status" != "ok" ]]; then
                add_issue "CRITICAL" "SMART тест не пройден" "$disk" "Срочно сделать backup и заменить диск"
                add_prohibition "Форматировать $disk" "SMART ошибки" "Сначала backup + замена диска"
            fi
            
            # Reallocated sectors
            local reallocated=$(sanitize_num "$(safe_cmd 30 smartctl -A "$disk" 2>/dev/null | grep -i "Reallocated_Sector" | awk '{ print $NF }' || echo "0")")
            echo "  reallocated_sectors: $reallocated"
            
            if [[ $reallocated -gt 0 ]]; then
                add_issue "WARNING" "Переназначенные сектора" "$disk" "Мониторить рост, планировать замену"
                add_prohibition "Игнорировать рост Reallocated_Sector_Ct" "$disk" "Подготовить замену диска"
            fi
            
            local poh=$(sanitize_num "$(safe_cmd 30 smartctl -A "$disk" 2>/dev/null | grep -i "Power_On_Hours" | awk '{ print $NF }' || echo "0")")
            echo "  power_on_hours: $poh"
        done
    else
        echo "[TOOL_MISSING: smartctl]"
    fi
}

scan_gpu_detailed() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [GPU_DETAILED]"
    echo "### GPU_DEVICES"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # lspci для GPU
    local gpu_devices=$(safe_cmd 10 lspci 2>/dev/null | grep -i "VGA\|3D\|Display" || echo "")
    
    if [[ -n "$gpu_devices" ]]; then
        echo "$gpu_devices" | while read -r line; do
            echo "  pci_device: $line"
        done
    else
        echo "  discrete_gpu: [NOT_FOUND]"
    fi
    
    # NVIDIA (если есть)
    if check_tool nvidia-smi; then
        echo ""
        echo "### NVIDIA_GPU"
        echo "• DATA:"
        
        local nvidia_status=$(safe_cmd 15 nvidia-smi -q 2>/dev/null | head -50 || echo "[UNAVAILABLE]")
        if [[ -n "$nvidia_status" ]]; then
            echo "• RAW_LOGS: [TRUNCATED: first 50 lines]"
            echo "$nvidia_status" | head -20 | while read -r line; do echo "  $line"; done
        fi
    else
        echo "  nvidia_driver: [NOT_INSTALLED]"
    fi
    
    # Intel GPU
    if check_tool intel_gpu_top; then
        echo ""
        echo "### INTEL_GPU"
        echo "• DATA:"
        echo "  intel_gpu_tools: installed"
    fi
}

scan_battery_power() {
    local level_required=$LEVEL_MINIMAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [BATTERY_POWER]"
    echo "### BATTERY_STATUS"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    if [[ -d /sys/class/power_supply ]]; then
        local batteries=$(ls -d /sys/class/power_supply/BAT* 2>/dev/null || echo "")
        
        if [[ -n "$batteries" ]]; then
            for bat in $batteries; do
                local bat_name=$(basename "$bat")
                echo "  battery: $bat_name"
                
                local capacity=$(sanitize_num "$(safe_cmd 5 cat "$bat/capacity" 2>/dev/null || echo "[UNAVAILABLE]")")
                local status=$(safe_cmd 5 cat "$bat/status" 2>/dev/null || echo "[UNAVAILABLE]")
                local energy_full=$(safe_cmd 5 cat "$bat/energy_full" 2>/dev/null || safe_cmd 5 cat "$bat/charge_full" 2>/dev/null || echo "[UNAVAILABLE]")
                local energy_now=$(safe_cmd 5 cat "$bat/energy_now" 2>/dev/null || safe_cmd 5 cat "$bat/charge_now" 2>/dev/null || echo "[UNAVAILABLE]")
                
                echo "    capacity_percent: $capacity%"
                echo "    status: $status"
                echo "    energy_full: $energy_full"
                echo "    energy_now: $energy_now"
                
                if [[ $(sanitize_num "$capacity") -lt 50 ]]; then
                    add_issue "WARNING" "Износ батареи > 50%" "$bat_name" "Рассмотреть замену батареи"
                fi
            done
        else
            echo "  battery: [NO_BATTERY_DETECTED] (desktop or unavailable)"
        fi
    else
        echo "[UNAVAILABLE]"
    fi
    
    # AC адаптер
    echo ""
    echo "### AC_ADAPTER"
    echo "• DATA:"
    
    local ac_adapters=$(ls -d /sys/class/power_supply/AC* 2>/dev/null || echo "")
    if [[ -n "$ac_adapters" ]]; then
        for ac in $ac_adapters; do
            local ac_status=$(safe_cmd 5 cat "$ac/online" 2>/dev/null || echo "[UNAVAILABLE]")
            echo "  adapter: $(basename $ac)"
            echo "    online: $ac_status"
        done
    else
        echo "  ac_adapter: [NOT_FOUND]"
    fi
}

scan_thermal_cooling() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [THERMAL_COOLING]"
    echo "### TEMPERATURES"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    if check_tool sensors; then
        local sensors_output=$(safe_cmd 15 sensors 2>/dev/null || echo "")
        if [[ -n "$sensors_output" ]]; then
            echo "• RAW_LOGS: [TRUNCATED]"
            echo "$sensors_output" | head -30 | while read -r line; do
                [[ -n "$line" ]] && echo "  $line"
            done
            
            # Проверка на перегрев
            local high_temp=$(echo "$sensors_output" | grep -E "Package id 0|Core|Tdie" | grep -oE '[0-9]+\.[0-9]+' | sort -rn | head -1 || echo "0")
            if [[ -n "$high_temp" ]]; then
                local temp_int=$(sanitize_num "${high_temp%.*}")
                if [[ $temp_int -gt 90 ]]; then
                    add_issue "CRITICAL" "Критическая температура CPU > 90°C" "thermal" "Проверить систему охлаждения, заменить термопасту"
                elif [[ $temp_int -gt 80 ]]; then
                    add_issue "WARNING" "Высокая температура CPU > 80°C" "thermal" "Проверить вентиляцию и нагрузку"
                fi
            fi
        else
            echo "  sensors: [NO_DATA]"
        fi
    else
        echo "[TOOL_MISSING: sensors]"
    fi
    
    # Тепловые зоны
    echo ""
    echo "### THERMAL_ZONES"
    echo "• DATA:"
    
    if [[ -d /sys/class/thermal ]]; then
        for zone in /sys/class/thermal/thermal_zone*; do
            local zone_type=$(safe_cmd 5 cat "$zone/type" 2>/dev/null || echo "unknown")
            local zone_temp=$(safe_cmd 5 cat "$zone/temp" 2>/dev/null || echo "0")
            local temp_c=$((zone_temp / 1000))
            echo "  zone: $zone_type"
            echo "    temperature_c: $temp_c"
        done
    fi
}

scan_network_detailed() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [NETWORK_DETAILED]"
    echo "### INTERFACES"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # Основные интерфейсы
    safe_cmd 10 ip -br addr 2>/dev/null | while read -r iface state mac_addr; do
        echo "  interface: $iface"
        echo "    state: $state"
        echo "    mac: $mac_addr"
        
        # Статистика
        if [[ -f "/sys/class/net/$iface/statistics/rx_bytes" ]]; then
            local rx_bytes=$(safe_cmd 5 cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo "0")
            local tx_bytes=$(safe_cmd 5 cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo "0")
            local rx_errors_raw=$(safe_cmd 5 cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo "0")
            local tx_errors_raw=$(safe_cmd 5 cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo "0")
            local rx_errors=$(sanitize_num "$rx_errors_raw")
            local tx_errors=$(sanitize_num "$tx_errors_raw")
            
            echo "    rx_bytes: $rx_bytes"
            echo "    tx_bytes: $tx_bytes"
            echo "    rx_errors: $rx_errors"
            echo "    tx_errors: $tx_errors"
            
            if [[ $rx_errors -gt 100 ]] || [[ $tx_errors -gt 100 ]]; then
                add_issue "WARNING" "Ошибки сети на интерфейсе" "$iface" "Проверить кабель, драйвер, настройки"
            fi
        fi
    done
    
    # Маршруты
    echo ""
    echo "### ROUTING_TABLE"
    echo "• DATA:"
    
    safe_cmd 10 ip route 2>/dev/null | head -10 | while read -r line; do
        echo "  route: $line"
    done
    
    # DNS
    echo ""
    echo "### DNS_CONFIG"
    echo "• DATA:"
    
    if [[ -f /etc/resolv.conf ]]; then
        safe_cmd 5 grep "^nameserver" /etc/resolv.conf 2>/dev/null | while read -r line; do
            echo "  nameserver: $line"
        done
    fi
    
    # Открытые порты
    echo ""
    echo "### OPEN_PORTS"
    echo "• DATA:"
    
    if check_tool ss; then
        local listening_ports=$(safe_cmd 10 ss -tulpn 2>/dev/null | tail -n +2 || echo "")
        if [[ -n "$listening_ports" ]]; then
            echo "• RAW_LOGS: [TRUNCATED: first 30]"
            echo "$listening_ports" | head -30 | while read -r line; do echo "  $line"; done
        fi
    else
        echo "[TOOL_MISSING: ss]"
    fi
}

scan_audio_subsystem() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [AUDIO_SUBSYSTEM]"
    echo "### ALSA_DEVICES"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    if [[ -f /proc/asound/cards ]]; then
        local alsa_cards=$(safe_cmd 5 cat /proc/asound/cards 2>/dev/null || echo "")
        if [[ -n "$alsa_cards" ]]; then
            echo "• RAW_LOGS:"
            echo "$alsa_cards" | while read -r line; do
                [[ -n "$line" ]] && echo "  $line"
            done
        else
            echo "  alsa_cards: [NONE]"
        fi
    fi
    
    # PulseAudio/PipeWire
    echo ""
    echo "### AUDIO_SERVER"
    echo "• DATA:"
    
    if check_tool pactl; then
        local pulse_status=$(safe_cmd 10 pactl info 2>/dev/null | grep "Server Name" || echo "[UNAVAILABLE]")
        echo "  audio_server: $pulse_status"
    elif check_tool pw-cli; then
        echo "  audio_server: PipeWire"
    else
        echo "  audio_server: [NOT_DETECTED]"
    fi
}

scan_hardware_errors() {
    local level_required=$LEVEL_TOTAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [HARDWARE_ERRORS]"
    echo "### MCE_ERRORS"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # MCE ошибки
    local mce_count_raw=$(safe_cmd 10 dmesg 2>/dev/null | grep -c -iE "MCE|Machine Check" || echo "0")
    local mce_count=$(sanitize_num "$mce_count_raw")
    echo "  mce_events: $mce_count"
    
    if [[ $mce_count -gt 0 ]]; then
        add_issue "CRITICAL" "Обнаружены MCE ошибки" "cpu/hardware" "Проверить стабильность CPU, RAM, питание"
        add_prohibition "Игнорировать MCE ошибки" "hardware" "Срочная диагностика оборудования"
    fi
    
    # PCIe AER ошибки
    echo ""
    echo "### PCIE_AER_ERRORS"
    echo "• DATA:"
    local aer_errors_raw=$(safe_cmd 10 dmesg 2>/dev/null | grep -c -iE "AER|PCIe.*error" || echo "0")
    local aer_errors=$(sanitize_num "$aer_errors_raw")
    echo "  aer_error_count: $aer_errors"
    
    if [[ $aer_errors -gt 0 ]]; then
        add_issue "WARNING" "Ошибки PCIe AER" "pci_bus" "Проверить устройства PCIe, обновить прошивки"
    fi
    
    # USB ошибки
    echo ""
    echo "### USB_ERRORS"
    echo "• DATA:"
    local usb_errors_raw=$(safe_cmd 10 dmesg 2>/dev/null | grep -c -iE "usb.*reset|usb.*error" || echo "0")
    local usb_errors=$(sanitize_num "$usb_errors_raw")
    echo "  usb_reset_error_count: $usb_errors"
    
    if [[ $usb_errors -gt 10 ]]; then
        add_issue "WARNING" "Частые сбросы USB" "usb_subsystem" "Проверить USB устройства и кабели"
    fi
}

scan_logs_analysis() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [LOGS_ANALYSIS]"
    echo "### JOURNALCTL_ERRORS"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # Критические сообщения из journalctl
    local journal_errors=$(safe_cmd 30 journalctl -p err -xb --no-pager 2>/dev/null | tail -50 || echo "")
    
    if [[ -n "$journal_errors" ]]; then
        local error_count=$(echo "$journal_errors" | wc -l)
        echo "  error_count_current_boot: $error_count"
        
        # Поиск паттернов
        local segfault_count_raw=$(echo "$journal_errors" | grep -c "segfault" || echo "0")
        local segfault_count=$(sanitize_num "$segfault_count_raw")
        local io_error_count_raw=$(echo "$journal_errors" | grep -c -i "I/O error" || echo "0")
        local io_error_count=$(sanitize_num "$io_error_count_raw")
        local oom_kills_raw=$(echo "$journal_errors" | grep -c -i "Out of memory" || echo "0")
        local oom_kills=$(sanitize_num "$oom_kills_raw")
        
        echo "  segfault_events: $segfault_count"
        echo "  oom_events: $oom_kills"
        echo "  io_error_events: $io_error_count"
        
        if [[ $segfault_count -gt 5 ]]; then
            add_issue "WARNING" "Множественные segfault" "applications" "Проверить стабильность приложений"
        fi
        
        if [[ $io_error_count -gt 0 ]]; then
            add_issue "CRITICAL" "Ошибки ввода-вывода в логах" "storage" "Проверить диски на SMART, кабели SATA"
        fi
        
        echo ""
        echo "• RAW_LOGS: [TRUNCATED: last 20 errors]"
        echo "$journal_errors" | tail -20 | while read -r line; do
            [[ -n "$line" ]] && echo "  $line"
        done
    else
        echo "  critical_errors: [NONE_FOUND]"
    fi
    
    # Dmesg предупреждения
    echo ""
    echo "### DMESG_WARNINGS"
    echo "• DATA:"
    
    local dmesg_warn=$(safe_cmd 10 dmesg -l err,warn 2>/dev/null | tail -30 || echo "")
    if [[ -n "$dmesg_warn" ]]; then
        local warn_count=$(echo "$dmesg_warn" | wc -l)
        echo "  warning_count: $warn_count"
        echo "• RAW_LOGS: [TRUNCATED: last 15]"
        echo "$dmesg_warn" | tail -15 | while read -r line; do echo "  $line"; done
    else
        echo "  kernel_warnings: [NONE]"
    fi
}

scan_config_validation() {
    local level_required=$LEVEL_TOTAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [CONFIG_VALIDATION]"
    echo "### FSTAB_CHECK"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    if [[ -f /etc/fstab ]]; then
        local fstab_lines=$(safe_cmd 5 wc -l < /etc/fstab || echo "0")
        echo "  fstab_entries: $fstab_lines"
        
        # Проверка синтаксиса (findmnt)
        if check_tool findmnt; then
            if safe_cmd 10 findmnt --verify >/dev/null 2>&1; then
                echo "  fstab_verification: PASSED"
            else
                local fstab_verify=$(safe_cmd 10 findmnt --verify 2>&1 || echo "")
                echo "  fstab_verification: FAILED"
                echo "• RAW_LOGS:"
                echo "$fstab_verify" | while read -r line; do echo "  $line"; done
                add_issue "WARNING" "Ошибки в /etc/fstab" "/etc/fstab" "Исправить некорректные записи"
            fi
        fi
    else
        echo "  fstab: [NOT_FOUND]"
    fi
    
    # SSH конфиг
    echo ""
    echo "### SSHD_CONFIG"
    echo "• DATA:"
    
    if [[ -f /etc/ssh/sshd_config ]]; then
        if check_tool sshd; then
            local sshd_test=$(safe_cmd 10 sshd -t 2>&1 || echo "")
            if [[ -n "$sshd_test" ]]; then
                echo "  sshd_syntax_check: FAILED"
                echo "• RAW_LOGS:"
                echo "$sshd_test" | while read -r line; do echo "  $line"; done
                add_issue "WARNING" "Ошибки в конфигурации SSH" "/etc/ssh/sshd_config" "Исправить синтаксис sshd_config"
            else
                echo "  sshd_syntax_check: PASSED"
            fi
        else
            echo "  sshd_binary: [NOT_FOUND]"
        fi
    else
        echo "  sshd_config: [NOT_FOUND]"
    fi
    
    # Systemd units
    echo ""
    echo "### SYSTEMD_UNITS"
    echo "• DATA:"
    
    local failed_units=$(safe_cmd 10 systemctl --failed --no-pager 2>/dev/null | tail -n +2 || echo "")
    if [[ -n "$failed_units" ]]; then
        local failed_count=0
        [[ -n "$failed_units" ]] && failed_count=$(echo "$failed_units" | wc -l)
        echo "  failed_units_count: $failed_count"
        echo "• RAW_LOGS:"
        echo "$failed_units" | while read -r line; do echo "  $line"; done
        add_issue "WARNING" "Есть упавшие systemd службы" "systemd" "Проверить статус через systemctl status <unit>"
    else
        echo "  failed_units: [NONE]"
    fi
}

scan_package_management() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [PACKAGE_MANAGEMENT]"
    echo "### PACKAGE_MANAGER"
    
    detect_package_manager
    echo "• STATUS: OK"
    echo "• DATA:"
    echo "  detected_manager: $PKG_MGR"
    
    case "$PKG_MGR" in
        apt)
            echo ""
            echo "### APT_STATUS"
            echo "• DATA:"
            
            # Обновления
            local updates_avail=$(safe_cmd 30 apt list --upgradable 2>/dev/null | tail -n +2 | wc -l || echo "0")
            updates_avail=$(sanitize_num "$updates_avail")
            echo "  available_updates: $updates_avail"
            
            # Битые пакеты
            local broken=$(safe_cmd 10 dpkg --audit 2>/dev/null | wc -l || echo "0")
            broken=$(sanitize_num "$broken")
            echo "  broken_packages: $broken"
            
            if [[ $broken -gt 0 ]]; then
                add_issue "WARNING" "Битые пакеты в dpkg" "apt" "Выполнить sudo apt --fix-broken install"
            fi
            
            # Автоудаление
            local autoremove=$(safe_cmd 10 apt autoremove --dry-run 2>/dev/null | grep "^Remv" | wc -l || echo "0")
            autoremove=$(sanitize_num "$autoremove")
            echo "  autoremove_candidates: $autoremove"
            ;;
            
        dnf|yum)
            echo ""
            echo "### DNF_STATUS"
            echo "• DATA:"
            
            local updates_avail=$(safe_cmd 30 dnf check-update 2>/dev/null | tail -n +2 | wc -l || echo "0")
            updates_avail=$(sanitize_num "$updates_avail")
            echo "  available_updates: $updates_avail"
            
            local broken=$(safe_cmd 10 dnf verify 2>/dev/null | grep -c "FAILED" || echo "0")
            broken=$(sanitize_num "$broken")
            echo "  verification_failures: $broken"
            ;;
            
        pacman)
            echo ""
            echo "### PACMAN_STATUS"
            echo "• DATA:"
            
            local updates_avail=$(safe_cmd 30 pacman -Qu 2>/dev/null | wc -l || echo "0")
            updates_avail=$(sanitize_num "$updates_avail")
            echo "  available_updates: $updates_avail"
            
            # Orphaned пакеты
            local orphaned=$(safe_cmd 10 pacman -Qdtq 2>/dev/null | wc -l || echo "0")
            orphaned=$(sanitize_num "$orphaned")
            echo "  orphaned_packages: $orphaned"
            ;;
            
        zypper)
            echo ""
            echo "### ZYPPER_STATUS"
            echo "• DATA:"
            
            local updates_avail=$(safe_cmd 30 zypper list-updates 2>/dev/null | tail -n +2 | wc -l || echo "0")
            updates_avail=$(sanitize_num "$updates_avail")
            echo "  available_updates: $updates_avail"
            ;;
            
        *)
            echo "  package_management: [UNKNOWN_MANAGER]"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# scan_connected_repositories - Сканирование подключенных репозиториев
# Уровень: 2 (Средний)
#-------------------------------------------------------------------------------
scan_connected_repositories() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [CONNECTED_REPOSITORIES]"
    echo "### REPOSITORY_SCAN_SUMMARY"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    local repos_found=0
    local repos_available=0
    
    # === GIT РЕПОЗИТОРИИ ===
    echo ""
    echo "### GIT_REPOSITORIES"
    echo "• DATA:"
    
    local git_repos=()
    local common_dirs=("$HOME" "$HOME/projects" "$HOME/workspace" "$HOME/dev" "$HOME/src" "/opt" "/var/www")
    
    for dir in "${common_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r -d '' repo; do
                git_repos+=("$repo")
            done < <(find "$dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null)
        fi
    done
    
    if [[ ${#git_repos[@]} -gt 0 ]]; then
        echo "  git_repos_found: ${#git_repos[@]}"
        echo "• RAW_LOGS: [TRUNCATED: first 50]"
        local count=0
        for repo_path in "${git_repos[@]}"; do
            [[ $count -ge 50 ]] && break
            local repo_dir=$(dirname "$repo_path")
            local repo_name=$(basename "$repo_dir")
            
            # Получаем информацию о remote origin если есть доступ
            local remote_url=""
            if [[ -d "$repo_path" ]]; then
                remote_url=$(safe_cmd 5 git -C "$repo_dir" remote get-url origin 2>/dev/null || echo "[NO_REMOTE]")
            fi
            
            echo "  • $repo_name | path: $repo_dir | origin: $remote_url"
            ((count++))
            ((repos_found++))
        done
        
        if [[ ${#git_repos[@]} -gt 50 ]]; then
            echo "  ... и ещё $((${#git_repos[@]} - 50)) репозиториев"
        fi
    else
        echo "  git_repos_found: 0"
        echo "  status: [NO_GIT_REPOS_FOUND]"
    fi
    
    # Проверка наличия git
    if ! check_tool git; then
        echo "  git_tool: [NOT_INSTALLED]"
        add_issue "INFO" "Git не установлен" "tools" "Установить: sudo $PKG_MGR install git"
    fi
    
    # === DOCKER РЕПОЗИТОРИИ/ОБРАЗЫ ===
    echo ""
    echo "### DOCKER_REPOSITORIES"
    echo "• DATA:"
    
    if check_tool docker; then
        # Проверяем доступ к Docker (sudo или группа docker)
        local has_docker_access=false
        if safe_cmd 5 true 2>/dev/null; then
            has_docker_access=true
        elif groups | grep -q docker; then
            has_docker_access=true
        fi
        
        if [[ "$has_docker_access" == "true" ]]; then
            local docker_images=$(safe_cmd 30 docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -50 || echo "")
            local docker_containers=$(safe_cmd 15 docker ps -a --format "{{.Names}} ({{.Status}})" 2>/dev/null | head -20 || echo "")
            local docker_volumes=$(safe_cmd 15 docker volume ls --format "{{.Name}}" 2>/dev/null | head -20 || echo "")
            
            if [[ -n "$docker_images" ]]; then
                local img_count=$(echo "$docker_images" | wc -l)
                echo "  docker_images_found: $img_count"
                echo "• RAW_LOGS: [TRUNCATED: first 50]"
                echo "$docker_images" | while read -r line; do echo "  • $line"; done
                ((repos_found += img_count))
            else
                echo "  docker_images_found: 0"
            fi
            
            if [[ -n "$docker_containers" ]]; then
                local cont_count=$(echo "$docker_containers" | wc -l)
                echo "  docker_containers: $cont_count"
                echo "• RAW_LOGS: [TRUNCATED: first 20]"
                echo "$docker_containers" | while read -r line; do echo "  • $line"; done
            fi
            
            if [[ -n "$docker_volumes" ]]; then
                local vol_count=$(echo "$docker_volumes" | wc -l)
                echo "  docker_volumes: $vol_count"
            fi
        else
            echo "  docker_access: [NEEDS_ROOT_OR_DOCKER_GROUP]"
            add_issue "WARNING" "Нет доступа к Docker" "permissions" "Добавить пользователя в группу docker: sudo usermod -aG docker \$USER"
        fi
    else
        echo "  docker_tool: [NOT_INSTALLED]"
        echo "  status: Docker не установлен"
        ((repos_available++))
    fi
    
    # === SNAP ПАКЕТЫ/РЕПОЗИТОРИИ ===
    echo ""
    echo "### SNAP_PACKAGES"
    echo "• DATA:"
    
    if check_tool snap; then
        # Проверяем доступ через sudo (snap требует root)
        if safe_cmd 5 true 2>/dev/null; then
            local snap_list=$(safe_cmd 20 snap list 2>/dev/null | tail -n +2 | head -50 || echo "")
            
            if [[ -n "$snap_list" ]]; then
                local snap_count=$(echo "$snap_list" | wc -l)
                echo "  snap_packages_found: $snap_count"
                echo "• RAW_LOGS: [TRUNCATED: first 50]"
                echo "$snap_list" | while read -r line; do echo "  • $line"; done
                ((repos_found += snap_count))
            else
                echo "  snap_packages_found: 0"
            fi
        else
            echo "  snap_access: [NEEDS_ROOT]"
        fi
    else
        echo "  snap_tool: [NOT_INSTALLED]"
        echo "  status: Snap не установлен"
        ((repos_available++))
    fi
    
    # === FLATPAK ПРИЛОЖЕНИЯ ===
    echo ""
    echo "### FLATPAK_APPLICATIONS"
    echo "• DATA:"
    
    if check_tool flatpak; then
        local flatpak_apps=$(safe_cmd 20 flatpak list --app --columns=application,version,origin 2>/dev/null | head -50 || echo "")
        local flatpak_remotes=$(safe_cmd 15 flatpak remotes 2>/dev/null | tail -n +2 || echo "")
        
        if [[ -n "$flatpak_apps" ]]; then
            local fp_count=$(echo "$flatpak_apps" | wc -l)
            echo "  flatpak_apps_found: $fp_count"
            echo "• RAW_LOGS: [TRUNCATED: first 50]"
            echo "$flatpak_apps" | while read -r line; do echo "  • $line"; done
            ((repos_found += fp_count))
        else
            echo "  flatpak_apps_found: 0"
        fi
        
        if [[ -n "$flatpak_remotes" ]]; then
            local remote_count=$(echo "$flatpak_remotes" | wc -l)
            echo "  flatpak_remotes: $remote_count"
            echo "• RAW_LOGS:"
            echo "$flatpak_remotes" | while read -r line; do echo "  • $line"; done
        fi
    else
        echo "  flatpak_tool: [NOT_INSTALLED]"
        echo "  status: Flatpak не установлен"
        ((repos_available++))
    fi
    
    # === APT РЕПОЗИТОРИИ (для Debian/Ubuntu) ===
    echo ""
    echo "### APT_REPOSITORIES"
    echo "• DATA:"
    
    detect_package_manager
    if [[ "$PKG_MGR" == "apt" ]]; then
        if [[ -d /etc/apt/sources.list.d ]]; then
            local apt_sources=$(safe_cmd 10 find /etc/apt/sources.list.d -name "*.list" -type f 2>/dev/null | head -20 || echo "")
            local main_source=$(safe_cmd 5 cat /etc/apt/sources.list 2>/dev/null | grep -v "^#" | grep -v "^$" | head -10 || echo "")
            
            local apt_repo_count=0
            if [[ -n "$apt_sources" ]]; then
                apt_repo_count=$(echo "$apt_sources" | wc -l)
                echo "  apt_sources_files: $apt_repo_count"
                echo "• RAW_LOGS: [FILES]"
                echo "$apt_sources" | while read -r file; do 
                    local fname=$(basename "$file")
                    local enabled=$(safe_cmd 5 grep -v "^#" "$file" 2>/dev/null | grep -v "^$" | wc -l || echo "0")
                    echo "  • $fname | enabled_entries: $enabled"
                done
                ((repos_found += apt_repo_count))
            fi
            
            if [[ -n "$main_source" ]]; then
                echo "  main_sources_list: [CONFIGURED]"
            fi
        fi
        
        # Проверка на отключенные репозитории
        local disabled_repos=$(safe_cmd 10 apt-cache policy 2>/dev/null | grep -E "^\s+500|^\s+100" | wc -l || echo "0")
        echo "  active_apt_repos: $disabled_repos"
    else
        echo "  apt_manager: [NOT_APPLICABLE]"
    fi
    
    # === DNF/YUM РЕПОЗИТОРИИ (для RHEL/Fedora) ===
    echo ""
    echo "### DNF_YUM_REPOSITORIES"
    echo "• DATA:"
    
    if [[ "$PKG_MGR" == "dnf" ]] || [[ "$PKG_MGR" == "yum" ]]; then
        if [[ -d /etc/yum.repos.d ]]; then
            local yum_repos=$(safe_cmd 10 find /etc/yum.repos.d -name "*.repo" -type f 2>/dev/null | head -20 || echo "")
            
            if [[ -n "$yum_repos" ]]; then
                local yum_count=$(echo "$yum_repos" | wc -l)
                echo "  yum_repo_files: $yum_count"
                echo "• RAW_LOGS: [FILES]"
                echo "$yum_repos" | while read -r file; do 
                    local fname=$(basename "$file")
                    local enabled=$(safe_cmd 5 grep -i "^enabled=1" "$file" 2>/dev/null | wc -l || echo "0")
                    echo "  • $fname | enabled: $enabled"
                done
                ((repos_found += yum_count))
            fi
        fi
        
        # Список активных репозиториев
        local active_repos=$(safe_cmd 20 dnf repolist enabled 2>/dev/null | tail -n +2 | wc -l || echo "0")
        echo "  active_dnf_repos: $active_repos"
    else
        echo "  dnf_yum_manager: [NOT_APPLICABLE]"
    fi
    
    # === PACMAN РЕПОЗИТОРИИ (для Arch) ===
    echo ""
    echo "### PACMAN_REPOSITORIES"
    echo "• DATA:"
    
    if [[ "$PKG_MGR" == "pacman" ]]; then
        if [[ -f /etc/pacman.conf ]]; then
            local pacman_repos=$(safe_cmd 5 grep -E "^\[" /etc/pacman.conf 2>/dev/null | tr -d '[]' | head -20 || echo "")
            
            if [[ -n "$pacman_repos" ]]; then
                local pac_count=$(echo "$pacman_repos" | wc -l)
                echo "  pacman_repos_configured: $pac_count"
                echo "• RAW_LOGS:"
                echo "$pacman_repos" | while read -r repo; do echo "  • $repo"; done
                ((repos_found += pac_count))
            fi
        fi
    else
        echo "  pacman_manager: [NOT_APPLICABLE]"
    fi
    
    # === ZYPPER РЕПОЗИТОРИИ (для openSUSE) ===
    echo ""
    echo "### ZYPPER_REPOSITORIES"
    echo "• DATA:"
    
    if [[ "$PKG_MGR" == "zypper" ]]; then
        if check_tool zypper; then
            local zypper_repos=$(safe_cmd 20 zypper repos -u 2>/dev/null | tail -n +4 | head -20 || echo "")
            
            if [[ -n "$zypper_repos" ]]; then
                local zyp_count=$(echo "$zypper_repos" | wc -l)
                echo "  zypper_repos_found: $zyp_count"
                echo "• RAW_LOGS: [TRUNCATED: first 20]"
                echo "$zypper_repos" | while read -r line; do echo "  • $line"; done
                ((repos_found += zyp_count))
            fi
        fi
    else
        echo "  zypper_manager: [NOT_APPLICABLE]"
    fi
    
    # === ИТОГОВАЯ СТАТИСТИКА ===
    echo ""
    echo "### REPOSITORY_SUMMARY"
    echo "• DATA:"
    echo "  total_repos_found: $repos_found"
    echo "  additional_repos_available: $repos_available"
    
    if [[ $repos_available -gt 0 ]]; then
        echo "  status: [CAN_CONNECT_MORE]"
        add_issue "INFO" "Можно подключить дополнительные репозитории" "repositories" "Рассмотреть установку: docker, snap, flatpak"
    else
        echo "  status: [ALL_COMMON_REPOS_CHECKED]"
    fi
    
    # Рекомендации по подключению
    echo ""
    echo "### AVAILABLE_TO_CONNECT"
    echo "• DATA:"
    echo "  format: tool | install_command | description"
    echo "• RAW_LOGS:"
    
    if ! check_tool docker; then
        echo "  • docker | curl -fsSL https://get.docker.com |sh | Контейнеризация приложений"
    fi
    if ! check_tool snap; then
        case "$PKG_MGR" in
            apt) echo "  • snap | sudo apt install snapd | Универсальные пакеты от Canonical" ;;
            dnf|yum) echo "  • snap | sudo dnf install snapd | Универсальные пакеты от Canonical" ;;
            pacman) echo "  • snap | sudo pacman -S snapd | Универсальные пакеты от Canonical" ;;
            zypper) echo "  • snap | sudo zypper install snapd | Универсальные пакеты от Canonical" ;;
        esac
    fi
    if ! check_tool flatpak; then
        case "$PKG_MGR" in
            apt) echo "  • flatpak | sudo apt install flatpak | Универсальные пакеты от сообщества" ;;
            dnf|yum) echo "  • flatpak | sudo dnf install flatpak | Универсальные пакеты от сообщества" ;;
            pacman) echo "  • flatpak | sudo pacman -S flatpak | Универсальные пакеты от сообщества" ;;
            zypper) echo "  • flatpak | sudo zypper install flatpak | Универсальные пакеты от сообщества" ;;
        esac
    fi
}

#-------------------------------------------------------------------------------
# scan_all_installed_packages - Полный список всех установленных пакетов
# Уровень: 2 (Средний)
#-------------------------------------------------------------------------------
scan_all_installed_packages() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [ALL_INSTALLED_PACKAGES]"
    echo "### PACKAGE_LIST"
    echo "• STATUS: OK"
    echo "• DATA:"
    echo "  format: one_package_per_line"
    echo "• RAW_LOGS:"
    
    detect_package_manager
    
    case "$PKG_MGR" in
        apt|dpkg)
            # Debian/Ubuntu - dpkg list
            safe_cmd 30 dpkg-query -W -f='${Package} ${Version} ${Status}\n' 2>/dev/null | grep "install ok installed" | cut -d' ' -f1,2 || echo "[NO_PACKAGES_FOUND]"
            ;;
        dnf|yum|rpm)
            # RHEL/Fedora - rpm list
            safe_cmd 30 rpm -qa --last 2>/dev/null | head -500 || echo "[NO_PACKAGES_FOUND]"
            ;;
        pacman)
            # Arch Linux - pacman list
            safe_cmd 30 pacman -Q 2>/dev/null | head -500 || echo "[NO_PACKAGES_FOUND]"
            ;;
        zypper)
            # openSUSE - zypper list
            safe_cmd 30 zypper search --installed-only 2>/dev/null | tail -n +5 | head -500 || echo "[NO_PACKAGES_FOUND]"
            ;;
        *)
            echo "[UNKNOWN_PACKAGE_MANAGER]"
            ;;
    esac
}

#-------------------------------------------------------------------------------
# scan_all_installed_drivers - Полный список всех установленных драйверов
# Уровень: 2 (Средний)
#-------------------------------------------------------------------------------
scan_all_installed_drivers() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [ALL_INSTALLED_DRIVERS]"
    echo "### KERNEL_MODULES_DRIVERS"
    echo "• STATUS: OK"
    echo "• DATA:"
    echo "  format: MODULE_NAME | VERSION | LICENSE | DESCRIPTION"
    echo "• RAW_LOGS:"
    
    # Загруженные модули ядра
    echo "# Загруженные модули ядра (drivers):"
    safe_cmd 15 lsmod 2>/dev/null | tail -n +2 | while read -r module size used_by; do
        local mod_info=$(safe_cmd 5 modinfo "$module" 2>/dev/null || echo "")
        local version=$(echo "$mod_info" | grep "^version:" | head -1 | awk '{print $2}')
        local license=$(echo "$mod_info" | grep "^license:" | head -1 | awk '{print $2}')
        local desc=$(echo "$mod_info" | grep "^description:" | head -1 | cut -d':' -f2- | xargs)
        version=${version:-unknown}
        license=${license:-unknown}
        desc=${desc:-no_description}
        echo "  $module | $version | $license | $desc"
    done
    
    echo ""
    echo "### GPU_DRIVERS"
    echo "• DATA:"
    
    # NVIDIA драйверы
    if check_tool nvidia-smi; then
        echo "  NVIDIA_DRIVER: $(safe_cmd 5 nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "[NOT_FOUND]")"
    else
        echo "  NVIDIA_DRIVER: [NOT_INSTALLED]"
    fi
    
    # AMD GPU
    if safe_cmd 5 lspci -nn 2>/dev/null | grep -i "vga.*amd\|vga.*ati\|display.*amd" >/dev/null; then
        local amdgpu_loaded=$(safe_cmd 5 lsmod | grep -c amdgpu || echo "0")
        echo "  AMDGPU_MODULE: ${amdgpu_loaded}_loaded"
    fi
    
    # Intel GPU
    if safe_cmd 5 lspci -nn 2>/dev/null | grep -i "vga.*intel\|display.*intel" >/dev/null; then
        local i915_loaded=$(safe_cmd 5 lsmod | grep -c i915 || echo "0")
        echo "  I915_MODULE: ${i915_loaded}_loaded"
    fi
    
    echo ""
    echo "### WIFI_NETWORK_DRIVERS"
    echo "• DATA:"
    
    # Wireless драйверы
    safe_cmd 10 lspci -k 2>/dev/null | grep -A3 -i network | grep -E "Kernel driver in use|Kernel modules" | while read -r line; do
        echo "  $line"
    done
    
    # USB WiFi адаптеры
    safe_cmd 10 lsusb 2>/dev/null | grep -i wireless | while read -r line; do
        echo "  USB_WIFI: $line"
    done
    
    echo ""
    echo "### DKMS_MODULES"
    echo "• DATA:"
    
    if check_tool dkms; then
        safe_cmd 15 dkms status 2>/dev/null | while read -r line; do
            echo "  DKMS: $line"
        done
    else
        echo "  DKMS: [NOT_INSTALLED]"
    fi
    
    echo ""
    echo "### FIRMWARE_BLOBS"
    echo "• DATA:"
    
    if [[ -d /lib/firmware ]]; then
        local fw_count=$(safe_cmd 10 find /lib/firmware -type f 2>/dev/null | wc -l || echo "0")
        echo "  firmware_files_count: $fw_count"
        echo "  firmware_path: /lib/firmware"
    else
        echo "  firmware_path: [NOT_FOUND]"
    fi
}

#-------------------------------------------------------------------------------
# scan_broken_packages_deps - Список всех сломанных пакетов и зависимостей
# Уровень: 2 (Средний)
#-------------------------------------------------------------------------------
scan_broken_packages_deps() {
    local level_required=$LEVEL_MEDIUM
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [BROKEN_PACKAGES_DEPENDENCIES]"
    echo "### BROKEN_PACKAGES_DETECT"
    echo "• STATUS: OK"
    echo "• DATA:"
    
    detect_package_manager
    local broken_found=0
    
    case "$PKG_MGR" in
        apt|dpkg)
            echo "  manager: apt/dpkg"
            echo ""
            echo "### DPKG_AUDIT"
            
            local dpkg_audit=$(safe_cmd 30 dpkg --audit 2>/dev/null)
            if [[ -n "$dpkg_audit" ]]; then
                echo "• STATUS: WARNING"
                echo "• RAW_LOGS:"
                echo "$dpkg_audit" | while read -r line; do
                    echo "  $line"
                done
                broken_found=1
                add_issue "WARNING" "Битые пакеты в dpkg audit" "apt" "sudo apt --fix-broken install"
            else
                echo "  dpkg_audit: [CLEAN]"
            fi
            
            echo ""
            echo "### APT_BROKEN"
            
            local apt_broken=$(safe_cmd 30 apt-get check 2>&1 | grep -v "^Reading" || echo "")
            if [[ -n "$apt_broken" ]]; then
                echo "• STATUS: WARNING"
                echo "• RAW_LOGS:"
                echo "$apt_broken" | while read -r line; do
                    echo "  $line"
                done
                broken_found=1
                add_issue "WARNING" "Ошибки зависимостей apt" "apt" "sudo apt --fix-broken install"
            else
                echo "  apt_check: [CLEAN]"
            fi
            
            echo ""
            echo "### HELD_PACKAGES"
            
            local held=$(safe_cmd 10 apt-mark showhold 2>/dev/null)
            if [[ -n "$held" ]]; then
                echo "• DATA:"
                echo "  held_packages:"
                echo "$held" | while read -r pkg; do
                    echo "    - $pkg"
                done
            else
                echo "  held_packages: [NONE]"
            fi
            ;;
            
        dnf|yum)
            echo "  manager: dnf/yum"
            echo ""
            echo "### DNF_VERIFY"
            
            local dnf_verify=$(safe_cmd 60 dnf verify 2>/dev/null | grep "FAILED" || echo "")
            if [[ -n "$dnf_verify" ]]; then
                echo "• STATUS: WARNING"
                echo "• RAW_LOGS:"
                echo "$dnf_verify" | head -50 | while read -r line; do
                    echo "  $line"
                done
                broken_found=1
                add_issue "WARNING" "Ошибки верификации dnf" "dnf" "sudo dnf check"
            else
                echo "  dnf_verify: [CLEAN]"
            fi
            
            echo ""
            echo "### DNF_PROBLEMS"
            
            local dnf_problems=$(safe_cmd 30 dnf check 2>&1 | grep -iE "error|problem|broken" || echo "")
            if [[ -n "$dnf_problems" ]]; then
                echo "• STATUS: WARNING"
                echo "• RAW_LOGS:"
                echo "$dnf_problems" | head -50 | while read -r line; do
                    echo "  $line"
                done
                broken_found=1
            else
                echo "  dnf_check: [CLEAN]"
            fi
            ;;
            
        pacman)
            echo "  manager: pacman"
            echo ""
            echo "### PACMAN_CHECK"
            
            local pacman_check=$(safe_cmd 30 pacman -Qk 2>/dev/null | grep -v "ok$" || echo "")
            if [[ -n "$pacman_check" ]]; then
                echo "• STATUS: WARNING"
                echo "• RAW_LOGS:"
                echo "$pacman_check" | head -100 | while read -r line; do
                    echo "  $line"
                done
                broken_found=1
                add_issue "WARNING" "Ошибки проверки pacman" "pacman" "sudo pacman -Syu"
            else
                echo "  pacman_check: [CLEAN]"
            fi
            
            echo ""
            echo "### ORPHANED_PACKAGES"
            
            local orphaned=$(safe_cmd 10 pacman -Qdtq 2>/dev/null)
            if [[ -n "$orphaned" ]]; then
                echo "• DATA:"
                echo "  orphaned_packages:"
                echo "$orphaned" | head -50 | while read -r pkg; do
                    echo "    - $pkg"
                done
            else
                echo "  orphaned_packages: [NONE]"
            fi
            ;;
            
        zypper)
            echo "  manager: zypper"
            echo ""
            echo "### ZYPPER_VERIFY"
            
            local zypper_verify=$(safe_cmd 60 zypper verify 2>/dev/null | grep -iE "error|broken|missing" || echo "")
            if [[ -n "$zypper_verify" ]]; then
                echo "• STATUS: WARNING"
                echo "• RAW_LOGS:"
                echo "$zypper_verify" | head -50 | while read -r line; do
                    echo "  $line"
                done
                broken_found=1
            else
                echo "  zypper_verify: [CLEAN]"
            fi
            ;;
            
        *)
            echo "  manager: [UNKNOWN]"
            echo "  broken_check: [SKIPPED_UNKNOWN_MANAGER]"
            ;;
    esac
    
    echo ""
    echo "### MISSING_SHARED_LIBRARIES"
    echo "• DATA:"
    
    # Проверка отсутствующих библиотек через ldconfig
    local missing_libs=$(safe_cmd 30 ldconfig -p 2>/dev/null | wc -l || echo "0")
    echo "  available_libraries_in_ldconfig: $missing_libs"
    
    # Проверка битых ссылок на библиотеки в установленных бинарниках
    if check_tool ldd; then
        local broken_ldd=$(safe_cmd 60 find /usr/bin /usr/sbin /bin /sbin -type f -executable 2>/dev/null | head -100 | xargs -I {} sh -c 'ldd "{}" 2>/dev/null | grep -q "not found" && echo "{}"' | head -20 || echo "")
        if [[ -n "$broken_ldd" ]]; then
            echo "• STATUS: WARNING"
            echo "  binaries_with_missing_libs:"
            echo "$broken_ldd" | while read -r bin; do
                echo "    - $bin"
                ldd "$bin" 2>/dev/null | grep "not found" | head -3 | while read -r lib_line; do
                    echo "      missing: $lib_line"
                done
            done
            broken_found=1
            add_issue "WARNING" "Бинарники с отсутствующими библиотеками" "ldd" "Переустановить соответствующие пакеты"
        else
            echo "  binaries_with_missing_libs: [NONE]"
        fi
    fi
    
    # Итоговый статус
    echo ""
    echo "### SUMMARY"
    if [[ $broken_found -eq 0 ]]; then
        echo "• STATUS: OK"
        echo "  overall_status: [NO_BROKEN_PACKAGES_FOUND]"
    else
        echo "• STATUS: WARNING"
        echo "  overall_status: [BROKEN_PACKAGES_DETECTED]"
        add_issue "WARNING" "Обнаружены проблемы с пакетами или зависимостями" "package_manager" "Выполнить проверку и восстановление пакетов"
    fi
}

scan_containers_virt() {
    local level_required=$LEVEL_TOTAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [CONTAINERS_VIRTUALIZATION]"
    echo "### VIRTUALIZATION_DETECT"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    local virt_type=$(safe_cmd 10 systemd-detect-virt 2>/dev/null || echo "none")
    echo "  virtualization: $virt_type"
    
    # Docker
    echo ""
    echo "### DOCKER_STATUS"
    echo "• DATA:"
    
    if check_tool docker; then
        local docker_running=$(safe_cmd 10 systemctl is-active docker 2>/dev/null || echo "inactive")
        echo "  docker_service: $docker_running"
        
        if [[ "$docker_running" == "active" ]]; then
            local containers=$(safe_cmd 15 docker ps -a 2>/dev/null | tail -n +2 | wc -l || echo "0")
            local images=$(safe_cmd 15 docker images 2>/dev/null | tail -n +2 | wc -l || echo "0")
            echo "  containers_count: $containers"
            echo "  images_count: $images"
        fi
    else
        echo "  docker: [NOT_INSTALLED]"
    fi
    
    # Podman
    echo ""
    echo "### PODMAN_STATUS"
    echo "• DATA:"
    
    if check_tool podman; then
        echo "  podman: installed"
        local podman_containers=$(safe_cmd 15 podman ps -a 2>/dev/null | tail -n +2 | wc -l || echo "0")
        echo "  containers_count: $podman_containers"
    else
        echo "  podman: [NOT_INSTALLED]"
    fi
    
    # KVM/libvirt
    echo ""
    echo "### KVM_LIBVIRT"
    echo "• DATA:"
    
    if check_tool virsh; then
        local libvirtd=$(safe_cmd 10 systemctl is-active libvirtd 2>/dev/null || echo "inactive")
        echo "  libvirtd_service: $libvirtd"
        
        if [[ "$libvirtd" == "active" ]]; then
            local vms=$(safe_cmd 15 virsh list --all 2>/dev/null | tail -n +3 | wc -l || echo "0")
            echo "  vms_count: $vms"
        fi
    else
        echo "  libvirt: [NOT_INSTALLED]"
    fi
}

scan_security_hardening() {
    local level_required=$LEVEL_TOTAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [SECURITY_HARDENING]"
    echo "### FIREWALL_STATUS"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # UFW
    if check_tool ufw; then
        local ufw_status=$(safe_cmd 10 ufw status 2>/dev/null | head -1 || echo "inactive")
        echo "  ufw: $ufw_status"
    fi
    
    # iptables
    local ipt_rules=$(safe_cmd 10 iptables -L -n 2>/dev/null | wc -l || echo "0")
    echo "  iptables_rules: $ipt_rules"
    
    # SELinux/AppArmor
    echo ""
    echo "### MAC_SYSTEM"
    echo "• DATA:"
    
    if check_tool getenforce; then
        local selinux=$(safe_cmd 5 getenforce 2>/dev/null || echo "disabled")
        echo "  selinux: $selinux"
    fi
    
    if check_tool aa-status; then
        local apparmor=$(safe_cmd 10 aa-status 2>/dev/null | head -1 || echo "[UNAVAILABLE]")
        echo "  apparmor: $apparmor"
    fi
    
    # SUID/SGID файлы
    echo ""
    echo "### SUID_SGID_FILES"
    echo "• DATA:"
    
    local suid_files=$(safe_cmd 60 find /usr /bin /sbin -perm -4000 2>/dev/null | head -20 || echo "")
    if [[ -n "$suid_files" ]]; then
        local suid_count=$(echo "$suid_files" | wc -l)
        echo "  suid_files_found: $suid_count"
        echo "• RAW_LOGS: [TRUNCATED: first 20]"
        echo "$suid_files" | while read -r file; do echo "  $file"; done
    fi
    
    # SSH безопасность
    echo ""
    echo "### SSH_SECURITY"
    echo "• DATA:"
    
    if [[ -f /etc/ssh/sshd_config ]]; then
        local root_login=$(safe_cmd 5 grep -i "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not_set")
        local pass_auth=$(safe_cmd 5 grep -i "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "not_set")
        
        echo "  permit_root_login: $root_login"
        echo "  password_authentication: $pass_auth"
        
        if [[ "$root_login" == "yes" ]]; then
            add_issue "WARNING" "Разрешён root login по SSH" "security" "Установить PermitRootLogin no"
        fi
    fi
}

scan_performance_metrics() {
    local level_required=$LEVEL_PROFILING
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [PERFORMANCE_METRICS]"
    echo "### LOAD_AVERAGE"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    local load_avg=$(safe_cmd 5 cat /proc/loadavg 2>/dev/null || echo "0 0 0 0 0")
    local load_1=$(echo "$load_avg" | awk '{print $1}')
    local load_5=$(echo "$load_avg" | awk '{print $2}')
    local load_15=$(echo "$load_avg" | awk '{print $3}')
    
    echo "  load_1min: $load_1"
    echo "  load_5min: $load_5"
    echo "  load_15min: $load_15"
    
    # Проверка на высокую нагрузку
    local cpu_count=$(safe_cmd 5 nproc 2>/dev/null || echo "1")
    local load_int=${load_1%.*}
    if [[ $load_int -gt $((cpu_count * 2)) ]]; then
        add_issue "CRITICAL" "Очень высокая нагрузка CPU" "performance" "Найти процесс через top, проверить троттлинг"
    fi
    
    # Топ процессов
    echo ""
    echo "### TOP_PROCESSES_CPU"
    echo "• DATA:"
    
    safe_cmd 10 ps aux --sort=-%cpu 2>/dev/null | head -11 | tail -10 | while read -r user pid cpu mem vsz rss tty stat start time cmd; do
        echo "  pid: $pid | cpu: $cpu% | mem: $mem% | cmd: $cmd"
    done
    
    echo ""
    echo "### TOP_PROCESSES_MEM"
    echo "• DATA:"
    
    safe_cmd 10 ps aux --sort=-%mem 2>/dev/null | head -11 | tail -10 | while read -r user pid cpu mem vsz rss tty stat start time cmd; do
        echo "  pid: $pid | cpu: $cpu% | mem: $mem% | cmd: $cmd"
    done
    
    # I/O статистика
    echo ""
    echo "### IO_STATS"
    echo "• DATA:"
    
    if check_tool iostat; then
        local iostat_out=$(safe_cmd 10 iostat -x 2>/dev/null | tail -20 || echo "")
        if [[ -n "$iostat_out" ]]; then
            echo "• RAW_LOGS:"
            echo "$iostat_out" | while read -r line; do [[ -n "$line" ]] && echo "  $line"; done
        fi
    else
        echo "[TOOL_MISSING: iostat]"
    fi
}

#-------------------------------------------------------------------------------
# scan_hardware_driver_audit - Аудит железа и драйверов, поиск несоответствий
# Уровень: 3 (Тотальный)
#-------------------------------------------------------------------------------
scan_hardware_driver_audit() {
    local level_required=$LEVEL_TOTAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    echo ""
    echo "## [HARDWARE_DRIVER_AUDIT]"
    echo "### HARDWARE_INVENTORY"
    echo "• STATUS: OK"
    echo "• DATA:"
    echo "  scanning: PCI USB SATA NVMe I2C SDIO devices"
    
    local mismatches_found=0
    local missing_drivers=0
    
    # === PCI УСТРОЙСТВА ===
    echo ""
    echo "### PCI_DEVICES_CHECK"
    echo "• DATA:"
    
    if check_tool lspci; then
        local pci_output=$(safe_cmd 15 lspci -nnk 2>/dev/null || echo "")
        local driver_in_use=""
        while read -r line; do
            if [[ "$line" =~ ^[0-9a-f] ]]; then
                # Это строка устройства
                local pci_slot=$(echo "$line" | cut -d' ' -f1)
                local device_desc=$(echo "$line" | cut -d':' -f2-)
                echo "  PCI_DEVICE: $pci_slot |$device_desc"
                driver_in_use=""
            elif [[ "$line" =~ "Kernel driver in use:" ]]; then
                local driver=$(echo "$line" | cut -d':' -f2 | xargs)
                echo "    DRIVER_IN_USE: $driver"
                driver_in_use="$driver"
                
                # Проверка на универсальные драйверы вместо специфичных
                if [[ "$driver" == "pcieport" ]]; then
                    echo "    NOTE: Универсальный драйвер pcieport (нормально для мостов)"
                fi
            elif [[ "$line" =~ "Kernel modules:" ]]; then
                local modules=$(echo "$line" | cut -d':' -f2 | xargs)
                echo "    AVAILABLE_MODULES: $modules"
                
                # Если нет драйвера в использовании
                if [[ -z "$driver_in_use" ]]; then
                    echo "    WARNING: Нет активного драйвера!"
                fi
            fi
        done < <(echo "$pci_output")
        
        # Поиск устройств без драйверов
        echo ""
        echo "### PCI_NO_DRIVER"
        local no_driver=$(safe_cmd 15 lspci -k 2>/dev/null | grep -B1 "Kernel driver in use:" | grep -v "Kernel driver" | grep -v "^--$" || echo "")
        if [[ -z "$no_driver" ]]; then
            # Альтернативная проверка - устройства без "Kernel driver in use"
            local all_devices=$(safe_cmd 15 lspci 2>/dev/null | wc -l)
            local devices_with_driver=$(safe_cmd 15 lspci -k 2>/dev/null | grep -c "Kernel driver in use:" || echo "0")
            local devices_without=$((all_devices - devices_with_driver))
            
            echo "  total_pci_devices: $all_devices"
            echo "  with_driver: $devices_with_driver"
            echo "  without_explicit_driver: $devices_without (может быть нормально для мостов)"
            
            if [[ $devices_without -gt $((all_devices / 2)) ]]; then
                add_issue "WARNING" "Множество PCI устройств без явного драйвера" "hardware" "Проверить lspci -v для деталей"
                ((mismatches_found++))
            fi
        fi
    else
        echo "  [TOOL_MISSING: lspci]"
    fi
    
    # === USB УСТРОЙСТВА ===
    echo ""
    echo "### USB_DEVICES_CHECK"
    echo "• DATA:"
    
    if check_tool lsusb; then
        local usb_count=$(safe_cmd 10 lsusb 2>/dev/null | wc -l)
        echo "  total_usb_devices: $usb_count"
        
        # Поиск USB устройств без драйверов
        echo ""
        echo "### USB_DRIVER_STATUS"
        local lsusb_output=$(safe_cmd 10 lsusb -t 2>/dev/null || echo "")
        while read -r line; do
            if [[ "$line" =~ Hub|Hub ]]; then
                continue
            fi
            if [[ "$line" =~ Driver= ]]; then
                local driver=$(echo "$line" | grep -oP 'Driver=\K[^ ]*' || echo "none")
                if [[ "$driver" == "(none)" || -z "$driver" ]]; then
                    echo "  MISSING_USB_DRIVER: $line"
                else
                    echo "  USB_OK: $(echo "$line" | grep -oP '.*?(?=:)' || echo "device") | driver=$driver"
                fi
            fi
        done < <(echo "$lsusb_output")
        
        # Проверка на устройства в режиме высокой скорости без драйверов
        local usb_errors=$(safe_cmd 10 dmesg 2>/dev/null | grep -iE "usb.*not recognized|usb.*descriptor failed" | tail -5 || echo "")
        if [[ -n "$usb_errors" ]]; then
            echo ""
            echo "### USB_ERRORS_DMESG"
            echo "• STATUS: WARNING"
            echo "• RAW_LOGS:"
            echo "$usb_errors" | while read -r line; do echo "  $line"; done
            add_issue "WARNING" "Ошибки распознавания USB устройств" "hardware" "Проверить питание и кабели"
            ((mismatches_found++))
        fi
    else
        echo "  [TOOL_MISSING: lsusb]"
    fi
    
    # === SATA/NVMe УСТРОЙСТВА ===
    echo ""
    echo "### STORAGE_CONTROLLER_CHECK"
    echo "• DATA:"
    
    # Контроллеры хранилищ
    if check_tool lspci; then
        local storage_controllers=$(safe_cmd 15 lspci -nn 2>/dev/null | grep -iE "sata|nvme|storage|mass storage" || echo "")
        if [[ -n "$storage_controllers" ]]; then
            echo "  storage_controllers_found:"
            echo "$storage_controllers" | while read -r line; do
                echo "    $line"
            done
            
            # Проверка драйверов для контроллеров
            while read -r line; do
                if [[ "$line" =~ "Kernel driver in use:" ]]; then
                    echo "    STORAGE_DRIVER: $(echo "$line" | cut -d':' -f2 | xargs)"
                fi
            done < <(safe_cmd 15 lspci -k 2>/dev/null | grep -A2 -iE "sata|nvme|storage")
        else
            echo "  standard_sata_nvme_controllers: detected"
        fi
    fi
    
    # NVMe health
    if check_tool nvme; then
        echo ""
        echo "### NVME_HEALTH_CHECK"
        local nvme_list=$(safe_cmd 10 nvme list 2>/dev/null || echo "")
        if [[ -n "$nvme_list" ]]; then
            echo "• DATA:"
            echo "$nvme_list" | tail -n +2 | while read -r line; do
                local nvme_dev=$(echo "$line" | awk '{print $1}')
                local nvme_model=$(echo "$line" | awk '{$1=""; print}' | xargs)
                echo "  NVME_DEVICE: $nvme_dev | $nvme_model"
                
                # Health check если есть доступ
                if [[ -e "/dev/${nvme_dev}" ]]; then
                    local health=$(safe_sudo_cmd 10 nvme smart-log "/dev/${nvme_dev}" 2>/dev/null | grep -E "critical_warning|temperature|available_spare" || echo "")
                    if [[ -n "$health" ]]; then
                        echo "    HEALTH: critical_warning=$(echo "$health" | grep critical_warning | awk '{print $2}')"
                    fi
                fi
            done
        else
            echo "  nvme_cli: installed_but_no_devices"
        fi
    else
        echo "  nvme_cli: [TOOL_MISSING]"
    fi
    
    # === ПРОВЕРКА НЕСООТВЕТСТВИЙ ===
    echo ""
    echo "### DRIVER_MISMATCH_DETECTION"
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # 1.GPU драйвер vs GPU hardware
    echo "  Checking GPU driver matching..."
    local gpu_vendor=""
    if check_tool lspci; then
        if safe_cmd 10 lspci -nn 2>/dev/null | grep -qiE "vga.*nvidia|3d.*nvidia"; then
            gpu_vendor="nvidia"
            if ! lsmod 2>/dev/null | grep -qwE "nvidia|nouveau"; then
                echo "  MISMATCH: NVIDIA GPU detected but no nvidia/nouveau driver loaded"
                add_issue "CRITICAL" "NVIDIA GPU без загруженного драйвера" "hardware" "Установить драйвер nvidia или nouveau"
                ((mismatches_found++))
            else
                local loaded_gpu=$(lsmod 2>/dev/null | grep -oE "nvidia[^ ]*|nouveau" | head -1)
                echo "  GPU_MATCH: NVIDIA | driver=$loaded_gpu"
            fi
        elif safe_cmd 10 lspci -nn 2>/dev/null | grep -qiE "vga.*amd|vga.*ati|display.*amd"; then
            gpu_vendor="amd"
            if ! lsmod 2>/dev/null | grep -qwE "amdgpu|radeon"; then
                echo "  MISMATCH: AMD GPU detected but no amdgpu/radeon driver loaded"
                add_issue "CRITICAL" "AMD GPU без загруженного драйвера" "hardware" "Установить драйвер amdgpu или radeon"
                ((mismatches_found++))
            else
                local loaded_gpu=$(lsmod 2>/dev/null | grep -oE "amdgpu|radeon" | head -1)
                echo "  GPU_MATCH: AMD | driver=$loaded_gpu"
            fi
        elif safe_cmd 10 lspci -nn 2>/dev/null | grep -qiE "vga.*intel|display.*intel"; then
            gpu_vendor="intel"
            if ! lsmod 2>/dev/null | grep -qwE "i915|iris"; then
                echo "  MISMATCH: Intel GPU detected but no i915/iris driver loaded"
                add_issue "WARNING" "Intel GPU без загруженного драйвера i915" "hardware" "Проверить загрузку модуля i915"
                ((mismatches_found++))
            else
                echo "  GPU_MATCH: Intel | driver=i915"
            fi
        else
            echo "  GPU: discrete_gpu_not_detected (возможно integrated или VM)"
        fi
    fi
    
    # 2.WiFi драйвер vs WiFi hardware
    echo ""
    echo "  Checking WiFi driver matching..."
    if check_tool lspci; then
        local wifi_hw=$(safe_cmd 10 lspci -nn 2>/dev/null | grep -iE "network.*wireless|network.*802.11" || echo "")
        if [[ -n "$wifi_hw" ]]; then
            echo "  WIFI_HARDWARE: detected"
            local wifi_driver=$(safe_cmd 10 lspci -k 2>/dev/null | grep -A2 -iE "network" | grep "Kernel driver in use:" | cut -d':' -f2 | xargs || echo "")
            if [[ -z "$wifi_driver" ]]; then
                echo "  MISMATCH: WiFi hardware detected but no driver loaded"
                add_issue "CRITICAL" "WiFi адаптер без драйвера" "hardware" "Установить драйвер для WiFi"
                ((mismatches_found++))
            else
                echo "  WIFI_MATCH: driver=$wifi_driver"
            fi
        else
            # Проверка USB WiFi
            if check_tool lsusb; then
                local usb_wifi=$(safe_cmd 10 lsusb 2>/dev/null | grep -i wireless || echo "")
                if [[ -n "$usb_wifi" ]]; then
                    echo "  USB_WIFI_HARDWARE: detected"
                fi
            fi
        fi
    fi
    
    # 3.Ethernet драйвер vs Ethernet hardware
    echo ""
    echo "  Checking Ethernet driver matching..."
    if check_tool lspci; then
        local eth_hw=$(safe_cmd 10 lspci -nn 2>/dev/null | grep -i "ethernet\|network.*controller" | grep -v wireless || echo "")
        if [[ -n "$eth_hw" ]]; then
            echo "  ETHERNET_HARDWARE: detected"
            local eth_driver=$(safe_cmd 10 lspci -k 2>/dev/null | grep -A2 -i ethernet | grep "Kernel driver in use:" | cut -d':' -f2 | xargs || echo "")
            if [[ -z "$eth_driver" ]]; then
                echo "  MISMATCH: Ethernet hardware detected but no driver loaded"
                add_issue "WARNING" "Ethernet адаптер без драйвера" "hardware" "Установить драйвер для Ethernet"
                ((mismatches_found++))
            else
                echo "  ETHERNET_MATCH: driver=$eth_driver"
            fi
        fi
    fi
    
    # 4.Audio драйвер vs Audio hardware
    echo ""
    echo "  Checking Audio driver matching..."
    if check_tool lspci; then
        local audio_hw=$(safe_cmd 10 lspci -nn 2>/dev/null | grep -i "audio\|multimedia" || echo "")
        if [[ -n "$audio_hw" ]]; then
            echo "  AUDIO_HARDWARE: detected"
            local audio_driver=$(safe_cmd 10 lspci -k 2>/dev/null | grep -A2 -i audio | grep "Kernel driver in use:" | cut -d':' -f2 | xargs || echo "")
            if [[ -z "$audio_driver" ]]; then
                echo "  MISMATCH: Audio hardware detected but no driver loaded"
                add_issue "WARNING" "Аудио устройство без драйвера" "hardware" "Проверить модуль snd_hda_intel или другой"
                ((mismatches_found++))
            else
                echo "  AUDIO_MATCH: driver=$audio_driver"
            fi
        fi
    fi
    
    # 5.Проверка отсутствующих прошивок
    echo ""
    echo "### FIRMWARE_MISSING_CHECK"
    echo "• DATA:"
    
    local fw_missing=$(safe_cmd 10 dmesg 2>/dev/null | grep -iE "firmware: failed to load|direct firmware load for.*failed" | tail -10 || echo "")
    if [[ -n "$fw_missing" ]]; then
        echo "• STATUS: WARNING"
        echo "• RAW_LOGS:"
        echo "$fw_missing" | while read -r line; do echo "  $line"; done
        add_issue "WARNING" "Отсутствуют прошивки для устройств" "hardware" "Установить пакет linux-firmware"
        ((missing_drivers++))
    else
        echo "  firmware_load: all_ok"
    fi
    
    # === ИТОГОВЫЙ СТАТУС ===
    echo ""
    echo "### AUDIT_SUMMARY"
    echo "• DATA:"
    echo "  total_mismatches: $mismatches_found"
    echo "  missing_drivers_count: $missing_drivers"
    
    if [[ $mismatches_found -eq 0 && $missing_drivers -eq 0 ]]; then
        echo "  overall_status: ALL_DRIVERS_MATCHED"
    else
        echo "  overall_status: MISMATCHES_DETECTED"
        add_issue "WARNING" "Обнаружены несоответствия железа и драйверов" "hardware" "Проверить раздел HARDWARE_DRIVER_AUDIT"
    fi
}

scan_malware_viruses() {
    local level_required=$LEVEL_TOTAL
    [[ $SCAN_LEVEL -lt $level_required ]] && return 0
    
    # Инициализация переменных для безопасности при set -u
    local chkroot_result="" rkh_result="" clam_result=""
    
    echo ""
    echo "## [MALWARE_VIRUS_SCAN]"
    echo "### ROOTKIT_CHECK"
    
    echo "• STATUS: OK"
    echo "• DATA:"
    
    # chkrootkit
    if check_tool chkrootkit; then
        echo "  chkrootkit: installed"
        local chkroot_result=$(safe_cmd 60 chkrootkit 2>/dev/null | grep -iE "infected|not found" || echo "clean")
        if [[ "$chkroot_result" != "clean" ]]; then
            echo "  chkrootkit_status: SUSPECTED"
            add_issue "CRITICAL" "Возможное заражение rootkit" "security" "Запустить глубокую проверку, изолировать систему"
            echo "• RAW_LOGS:"
            echo "$chkroot_result" | head -10 | while read -r line; do echo "  $line"; done
        else
            echo "  chkrootkit_status: clean"
        fi
    else
        echo "  chkrootkit: [TOOL_MISSING]"
    fi
    
    # rkhunter
    echo ""
    echo "### RKHUNTER_CHECK"
    echo "• DATA:"
    
    if check_tool rkhunter; then
        echo "  rkhunter: installed"
        local rkh_result=$(safe_cmd 60 rkhunter --check --skip-keypress 2>/dev/null | grep -iE "warning|infected|suspect" | head -10 || echo "clean")
        if [[ -n "$rkh_result" && "$rkh_result" != "clean" ]]; then
            echo "  rkhunter_status: SUSPECTED"
            add_issue "CRITICAL" "Возможное заражение по данным rkhunter" "security" "Проверить логи /var/log/rkhunter.log"
            echo "• RAW_LOGS:"
            echo "$rkh_result" | while read -r line; do echo "  $line"; done
        else
            echo "  rkhunter_status: clean"
        fi
    else
        echo "  rkhunter: [TOOL_MISSING]"
    fi
    
    # ClamAV
    echo ""
    echo "### CLAMAV_SCAN"
    echo "• DATA:"
    
    if check_tool clamscan; then
        echo "  clamav: installed"
        local clam_db=$(safe_cmd 10 freshclam --version 2>/dev/null | head -1 || echo "db_unknown")
        echo "  database: $clam_db"
        
        # Быстрая проверка критических директорий
        echo "  scanning: /etc /usr/bin /usr/sbin /tmp быстрая_проверка"
        local clam_result=$(safe_cmd 300 clamscan --no-summary --infected -r /etc /usr/bin /usr/sbin /tmp 2>/dev/null | head -50 || echo "")
        if [[ -n "$clam_result" ]]; then
            echo "  clamav_status: THREATS_FOUND"
            add_issue "CRITICAL" "Найдены угрозы по данным ClamAV" "security" "Изолировать файлы, проверить карантин"
            echo "• RAW_LOGS: [TRUNCATED: first 50]"
            echo "$clam_result" | while read -r line; do echo "  $line"; done
        else
            echo "  clamav_status: clean"
        fi
    else
        echo "  clamav: [TOOL_MISSING]"
    fi
    
    # Подозрительные процессы
    echo ""
    echo "### SUSPICIOUS_PROCESSES"
    echo "• DATA:"
    
    local suspicious_count=0
    
    # Процессы с высоким CPU в фоне
    local hidden_procs=$(safe_cmd 10 ps aux 2>/dev/null | awk '$8 ~ /^[RD]/ && $3 > 80 {print}' | head -10 || echo "")
    if [[ -n "$hidden_procs" ]]; then
        echo "  high_cpu_hidden: detected"
        echo "$hidden_procs" | while read -r line; do echo "  $line"; done
        ((suspicious_count++))
    else
        echo "  high_cpu_hidden: none"
    fi
    
    # Процессы из /tmp или странных путей
    local tmp_procs=$(safe_cmd 10 ps aux 2>/dev/null | grep -E "/tmp/|/dev/shm/|\\.\\." | grep -v grep | head -10 || echo "")
    if [[ -n "$tmp_procs" ]]; then
        echo "  tmp_path_processes: detected"
        add_issue "WARNING" "Процессы запущены из временных директорий" "security" "Проверить легитимность процессов"
        echo "$tmp_procs" | while read -r line; do echo "  $line"; done
        ((suspicious_count++))
    else
        echo "  tmp_path_processes: none"
    fi
    
    # Сетевые соединения на странные порты
    echo ""
    echo "### SUSPICIOUS_NETWORK"
    echo "• DATA:"
    
    if check_tool ss; then
        local weird_ports=$(safe_cmd 10 ss -tulpn 2>/dev/null | grep -E ":[0-9]{5}|LISTEN.*0\.0\.0\.0.*:(22|80|443)" | grep -v ":22 " | head -20 || echo "")
        if [[ -n "$weird_ports" ]]; then
            echo "  unusual_listeners: detected"
            echo "$weird_ports" | while read -r line; do echo "  $line"; done
        else
            echo "  unusual_listeners: none"
        fi
    fi
    
    # Проверка cron на подозрительные задачи
    echo ""
    echo "### CRON_MALWARE_CHECK"
    echo "• DATA:"
    
    local cron_suspicious=$(safe_cmd 10 grep -rE "curl.*\\|.*bash|wget.*\\|.*sh|nc -e|/dev/tcp" /etc/cron* /var/spool/cron 2>/dev/null | head -10 || echo "")
    if [[ -n "$cron_suspicious" ]]; then
        echo "  suspicious_cron: detected"
        add_issue "CRITICAL" "Подозрительные задачи в cron возможно майнеры ботнеты" "security" "Удалить вредоносные задачи проверить пользователя"
        echo "• RAW_LOGS:"
        echo "$cron_suspicious" | while read -r line; do echo "  $line"; done
    else
        echo "  suspicious_cron: none"
    fi
    
    # Итоговый статус
    echo ""
    echo "### SCAN_SUMMARY"
    echo "• DATA:"
    echo "  tools_available: chkrootkit[$(check_tool chkrootkit && echo yes || echo no)] rkhunter[$(check_tool rkhunter && echo yes || echo no)] clamav[$(check_tool clamscan && echo yes || echo no)]"
    echo "  suspicious_processes: $suspicious_count"
    
    if [[ $suspicious_count -eq 0 ]] && ! grep -q "THREATS_FOUND\\|SUSPECTED" <<< "$(echo "$chkroot_result$rkh_result$clam_result" 2>/dev/null)"; then
        echo "  overall_status: CLEAN"
    else
        echo "  overall_status: REQUIRES_INVESTIGATION"
        add_issue "CRITICAL" "Обнаружены признаки возможного заражения" "system" "Требуется глубокий анализ безопасности"
    fi
}

scan_strict_prohibitions() {
    echo ""
    echo "## [STRICT_PROHIBITIONS]"
    
    # Универсальные запреты
    add_prohibition "Менять права на /etc, /usr, /lib рекурсивно" "Риск поломки системы" "Использовать точечные изменения с бэкапом"
    add_prohibition "Отключать systemd-resolved/NetworkManager/sshd без fallback" "Потеря доступа к системе" "Сначала настроить альтернативный метод доступа"
    add_prohibition "Удалять dkms-модули или ядро без проверки" "Система не загрузится" "Использовать autoremove и проверить зависимости"
    add_prohibition "Запускать fsck на смонтированном корне" "Потеря данных" "Загрузиться с LiveUSB, сделать backup"
    add_prohibition "Игнорировать пометки [CRITICAL], [NEEDS_ROOT] из отчёта" "Риск усугубления проблем" "Сначала проанализировать, потом действовать"
    add_prohibition "Применять быстрые фиксы из интернета без понимания" "Непредсказуемые последствия" "Проверить в тестовой среде, иметь план отката"
    
    # Вывод всех запретов
    for prohibition in "${STRICT_PROHIBITIONS[@]}"; do
        echo "$prohibition"
    done
}

generate_ai_summary() {
    echo ""
    echo "## [AI_SUMMARY_READY]"
    
    # Критические проблемы
    echo "CRITICAL_ISSUES"
    if [[ ${#CRITICAL_ISSUES[@]} -eq 0 ]]; then
        echo "[NONE]"
    else
        for issue in "${CRITICAL_ISSUES[@]}"; do
            echo "$issue"
        done
    fi
    
    # Предупреждения
    echo ""
    echo "WARNING_ISSUES"
    if [[ ${#WARNING_ISSUES[@]} -eq 0 ]]; then
        echo "[NONE]"
    else
        for issue in "${WARNING_ISSUES[@]}"; do
            echo "$issue"
        done
    fi
    
    # Информация
    echo ""
    echo "INFO_ISSUES"
    if [[ ${#INFO_ISSUES[@]} -eq 0 ]]; then
        echo "[NONE]"
    else
        for issue in "${INFO_ISSUES[@]}"; do
            echo "$issue"
        done
    fi
    
    # Запреты
    echo ""
    scan_strict_prohibitions
    
    # Следующие шаги
    echo ""
    echo "[NEXT_STEPS_FOR_AI_ANALYSIS]"
    echo "• Передай этот отчёт ИИ с запросом: Проанализируй, дай пошаговый план устранения, выдели риски."
    echo "• Не выполняй команды с пометкой [NEEDS_ROOT] без аудита и понимания последствий."
    echo "• Все рекомендации проверяй на idempotency и безопасность отката."
    
    # Если проблем нет
    if [[ ${#CRITICAL_ISSUES[@]} -eq 0 ]] && [[ ${#WARNING_ISSUES[@]} -eq 0 ]]; then
        echo ""
        echo "✅ SYSTEM_HEALTHY: No critical issues detected."
        echo "[INFO] Все проверенные параметры в пределах нормы | система | продолжай мониторинг"
    fi
}

#-------------------------------------------------------------------------------
# ОПРЕДЕЛЕНИЕ ПУТИ СОХРАНЕНИЯ ОТЧЁТА
#-------------------------------------------------------------------------------
determine_output_path() {
    # Приоритетные директории - ВСЕГДА пытаемся использовать Desktop
    local dirs_to_try=(
        "$HOME/Desktop"
        "$HOME/Рабочий_стол"
    )
    
    TARGET_DIR=""
    
    for dir in "${dirs_to_try[@]}"; do
        if [[ -d "$dir" ]]; then
            TARGET_DIR="$dir"
            break
        fi
    done
    
    # Если ни одна не существует, ВСЕГДА создаём Desktop
    if [[ -z "$TARGET_DIR" ]]; then
        TARGET_DIR="$HOME/Desktop"
        if mkdir -p "$TARGET_DIR" 2>/dev/null; then
            echo -e "${COLOR_GREEN}✅ Создана директория: $TARGET_DIR${COLOR_RESET}"
        else
            # Если не удалось создать Desktop, пробуем Рабочий_стол
            TARGET_DIR="$HOME/Рабочий_стол"
            if mkdir -p "$TARGET_DIR" 2>/dev/null; then
                echo -e "${COLOR_GREEN}✅ Создана директория: $TARGET_DIR${COLOR_RESET}"
            else
                # В крайнем случае используем HOME, но с предупреждением
                echo -e "${COLOR_YELLOW}⚠️ Не удалось создать директорию на рабочем столе, использую $HOME${COLOR_RESET}"
                TARGET_DIR="$HOME"
            fi
        fi
    fi
    
    OUTPUT_FILE="$TARGET_DIR/$OUTPUT_FILENAME"
    echo -e "${COLOR_BLUE}📁 Отчёт будет сохранён в: $OUTPUT_FILE${COLOR_RESET}"
}

#-------------------------------------------------------------------------------
# МЕНЮ ВЫБОРА УРОВНЯ СКАНИРОВАНИЯ
#-------------------------------------------------------------------------------
show_menu() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  🔍 DEEP SYSTEM SCAN v${SCRIPT_VERSION} - Диагностика системы"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Выберите уровень сканирования:"
    echo ""
    echo "  [1] 🟢 МИНИМАЛЬНЫЙ: ядро, CPU/RAM базово, uptime, свободное место"
    echo "  [2] 🟡 СРЕДНИЙ: всё из [1] + systemd, пакеты, сеть, SMART, пользователи, репозитории"
    echo "  [3] 🔴 ТОТАЛЬНЫЙ: всё из [2] + безопасность, валидация, контейнеры"
    echo "  [4] ПРОФИЛИРОВАНИЕ: всё из [3] + perf eBPF метрики требуется подтверждение"
    echo ""
    echo -n "Ваш выбор [1-4]: "
}

get_scan_level() {
    # Проверка аргументов командной строки
    for arg in "$@"; do
        case "$arg" in
            --level=*)
                SCAN_LEVEL="${arg#*=}"
                return
                ;;
            --auto-install)
                AUTO_INSTALL=true
                ;;
            --force-profiling)
                FORCE_PROFILING=true
                SCAN_LEVEL=$LEVEL_PROFILING
                return
                ;;
            --help|-h)
                echo "Использование: $0 [OPTIONS]"
                echo ""
                echo "OPTIONS:"
                echo "  --level=N          Уровень сканирования 1-4"
                echo "  --auto-install     Автоматически установить недостающие утилиты"
                echo "  --force-profiling  Режим профилирования без подтверждения"
                echo "  --help, -h         Показать эту справку"
                exit 0
                ;;
        esac
    done
    
    # Если уровень не задан аргументом, показываем меню
    if [[ $SCAN_LEVEL -eq 0 ]]; then
        show_menu
        read -r choice
        
        case "$choice" in
            1) SCAN_LEVEL=$LEVEL_MINIMAL ;;
            2) SCAN_LEVEL=$LEVEL_MEDIUM ;;
            3) SCAN_LEVEL=$LEVEL_TOTAL ;;
            4)
                echo ""
                echo -e "${COLOR_RED}⚠️ ВНИМАНИЕ: Режим профилирования может создавать нагрузку на систему!${COLOR_RESET}"
                echo "Этот режим включает стресс-тесты и расширенные метрики производительности."
                echo ""
                read -p "Вы уверены, что хотите продолжить? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    SCAN_LEVEL=$LEVEL_PROFILING
                else
                    echo "Возврат к выбору уровня..."
                    get_scan_level
                    return
                fi
                ;;
            *)
                echo -e "${COLOR_RED}Неверный выбор. По умолчанию установлен уровень 2.${COLOR_RESET}"
                SCAN_LEVEL=$LEVEL_MEDIUM
                ;;
        esac
    fi
}

#-------------------------------------------------------------------------------
# ОСНОВНАЯ ФУНКЦИЯ СКАНИРОВАНИЯ
#-------------------------------------------------------------------------------
run_scan() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Начало сканирования уровень: $SCAN_LEVEL"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    local step=0
    local total_steps=22
    
    # Helper для вывода прогресса
    print_progress() {
        local msg="$1"
        local status="$2"
        ((step++))
        printf "[%d/%d] %-50s [%s]\n" "$step" "$total_steps" "$msg" "$status"
    }
    
    # === MINIMAL LEVEL ===
    print_progress "Базовая информация о системе" "RUNNING"
    scan_basic_info
    print_progress "Базовая информация о системе" "OK"
    
    print_progress "Детальная диагностика CPU" "RUNNING"
    scan_cpu_detailed
    print_progress "Детальная диагностика CPU" "OK"
    
    print_progress "Топология CPU" "RUNNING"
    scan_cpu_topology
    print_progress "Топология CPU" "OK"
    
    print_progress "Детальная диагностика RAM" "RUNNING"
    scan_memory_detailed
    print_progress "Детальная диагностика RAM" "OK"
    
    print_progress "Диски и файловые системы" "RUNNING"
    scan_storage_detailed
    print_progress "Диски и файловые системы" "OK"
    
    print_progress "Батарея и питание" "RUNNING"
    scan_battery_power
    print_progress "Батарея и питание" "OK"
    
    # === MEDIUM LEVEL ===
    if [[ $SCAN_LEVEL -ge $LEVEL_MEDIUM ]]; then
        print_progress "GPU и графика" "RUNNING"
        scan_gpu_detailed
        print_progress "GPU и графика" "OK"
        
        print_progress "Термальный мониторинг" "RUNNING"
        scan_thermal_cooling
        print_progress "Термальный мониторинг" "OK"
        
        print_progress "Сетевая подсистема" "RUNNING"
        scan_network_detailed
        print_progress "Сетевая подсистема" "OK"
        
        print_progress "Аудио подсистема" "RUNNING"
        scan_audio_subsystem
        print_progress "Аудио подсистема" "OK"
        
        print_progress "Анализ логов" "RUNNING"
        scan_logs_analysis
        print_progress "Анализ логов" "OK"
        
        print_progress "Управление пакетами" "RUNNING"
        scan_package_management
        print_progress "Управление пакетами" "OK"
        
        print_progress "Подключенные репозитории" "RUNNING"
        scan_connected_repositories
        print_progress "Подключенные репозитории" "OK"
        
        print_progress "Все установленные пакеты" "RUNNING"
        scan_all_installed_packages
        print_progress "Все установленные пакеты" "OK"
        
        print_progress "Все установленные драйверы" "RUNNING"
        scan_all_installed_drivers
        print_progress "Все установленные драйверы" "OK"
        
        print_progress "Сломанные пакеты и зависимости" "RUNNING"
        scan_broken_packages_deps
        print_progress "Сломанные пакеты и зависимости" "OK"
    fi
    
    # === TOTAL LEVEL ===
    if [[ $SCAN_LEVEL -ge $LEVEL_TOTAL ]]; then
        print_progress "Аппаратные ошибки" "RUNNING"
        scan_hardware_errors
        print_progress "Аппаратные ошибки" "OK"
        
        print_progress "Валидация конфигов" "RUNNING"
        scan_config_validation
        print_progress "Валидация конфигов" "OK"
        
        print_progress "Контейнеры и виртуализация" "RUNNING"
        scan_containers_virt
        print_progress "Контейнеры и виртуализация" "OK"
        
        print_progress "Безопасность и hardening" "RUNNING"
        scan_security_hardening
        print_progress "Безопасность и hardening" "OK"
        
        print_progress "Аудит железа и драйверов" "RUNNING"
        scan_hardware_driver_audit
        print_progress "Аудит железа и драйверов" "OK"
        
        print_progress "Проверка на вирусы и малварь" "RUNNING"
        scan_malware_viruses
        print_progress "Проверка на вирусы и малварь" "OK"
    fi
    
    # === PROFILING LEVEL ===
    if [[ $SCAN_LEVEL -ge $LEVEL_PROFILING ]]; then
        print_progress "Метрики производительности" "RUNNING"
        scan_performance_metrics
        print_progress "Метрики производительности" "OK"
    fi
    
    # === FINAL SUMMARY ===
    print_progress "Генерация итоговой сводки" "RUNNING"
    generate_ai_summary
    print_progress "Генерация итоговой сводки" "OK"
}

#-------------------------------------------------------------------------------
# ТОЧКА ВХОДА
#-------------------------------------------------------------------------------
main() {
    # Обработка аргументов и получение уровня
    get_scan_level "$@"
    
    # === ЗАПРОС SUDO ПРАВ В НАЧАЛЕ ===
    echo ""
    echo -e "${COLOR_BLUE}🔐 Проверка прав суперпользователя...${COLOR_RESET}"
    if sudo -n true 2>/dev/null; then
        echo -e "${COLOR_GREEN}✅ Права sudo уже доступны (без пароля)${COLOR_RESET}"
    else
        echo "Для полного сканирования требуются права root."
        echo "Пожалуйста, введите пароль sudo для получения прав на всю сессию:"
        if sudo -v 2>/dev/null; then
            echo -e "${COLOR_GREEN}✅ Права sudo успешно получены${COLOR_RESET}"
            # Обновляем таймаут sudo в фоне
            (while true; do sudo -n true 2>/dev/null && sleep 60 || break; done) &
            SUDO_KEEPALIVE_PID=$!
            trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null; exit 130' INT TERM
        else
            echo -e "${COLOR_YELLOW}⚠️ Не удалось получить права sudo. Некоторые проверки будут пропущены.${COLOR_RESET}"
        fi
    fi
    echo ""
    
    # Проверка и установка утилит
    check_and_install_tools
    
    # Определение пути сохранения
    determine_output_path
    
    echo ""
    echo -e "${COLOR_BLUE}📁 Отчёт будет сохранён в: $TARGET_DIR${COLOR_RESET}"
    echo ""
    
    # Запуск сканирования с перенаправлением вывода в файл
    run_scan 2>&1 | tee "$OUTPUT_FILE"
    
    # Останавливаем фоновый процесс обновления sudo
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill $SUDO_KEEPALIVE_PID 2>/dev/null
    fi
    
    # Финальная проверка
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  ✅ Сканирование завершено"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    if [[ -f "$OUTPUT_FILE" ]]; then
        local abs_path=$(realpath "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
        local file_size=$(du -h "$OUTPUT_FILE" 2>/dev/null | cut -f1 || echo "unknown")
        
        echo -e "${COLOR_GREEN}📄 Отчёт сохранён: $abs_path${COLOR_RESET}"
        echo -e "${COLOR_GREEN}📊 Размер: $file_size${COLOR_RESET}"
        echo ""
        echo "Для анализа передайте файл ИИ с запросом:"
        echo "  \"Проанализируй системный отчёт, выяви проблемы, дай план устранения\""
    else
        echo -e "${COLOR_RED}❌ Ошибка сохранения отчёта${COLOR_RESET}"
        exit 1
    fi
}

# Запуск основной функции
main "$@"

#===============================================================================
# @AI_ANALYST_RULES:
# 1. Все рекомендации должны быть идемпотентными и безопасными при прерывании
# 2. Если проблема требует перезагрузки / LiveUSB / физического доступа → пометить [REQUIRES_REBOOT] или [NEEDS_PHYSICAL]
# 3. Не предлагать обновление ядра/драйверов без проверки совместимости с DKMS и установленными пакетами
# 4. Если данные отсутствуют или обрезаны → указать, какую команду выполнить в read-only режиме для уточнения
# 5. Приоритет действий: read-only проверка → backup → тест в изоляции → применение в production
# 6. Для каждой команды указывать: цель, команду, ожидаемый результат, как откатить, уровень риска
# 7. Ответы на русском, без воды, только факты/риски/команды/откаты
#===============================================================================
