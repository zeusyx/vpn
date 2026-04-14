#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="AWS Menu Root Auto Lite"
LOG_FILE="/var/log/aws-menu-root-auto-lite.log"

# =========================================================
# CONFIGURAÇÕES FIXAS
# O menu só pede a senha do root quando você escolher a opção
# de liberar root, ou quando executar tudo.
# =========================================================
CONFIG_HOSTNAME="aws-server"
CONFIG_TIMEZONE="America/Fortaleza"
CONFIG_AUTO_REBOOT="false"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

OS_ID=""
OS_NAME=""
PKG_UPDATE=""
PKG_UPGRADE=""
PKG_INSTALL=""
TOTAL_STEPS=0
CURRENT_STEP=0

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

ok() {
  echo -e "${GREEN}✔${NC} $*"
  log "OK: $*"
}

warn() {
  echo -e "${YELLOW}⚠${NC} $*"
  log "WARN: $*"
}

err() {
  echo -e "${RED}✘${NC} $*"
  log "ERROR: $*"
}

line() {
  printf "%b\n" "${DIM}────────────────────────────────────────────────────────────${NC}"
}

header() {
  clear
  echo -e "${MAGENTA}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${MAGENTA}${BOLD}║${NC} ${WHITE}${BOLD}${APP_NAME}${NC}$(printf '%*s' $((53-${#APP_NAME})) '')${MAGENTA}${BOLD}║${NC}"
  echo -e "${MAGENTA}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo -e "${DIM}${OS_NAME:-Detectando sistema...}${NC}"
  echo
}

pause() {
  echo
  read -r -p "Pressione Enter para voltar ao menu..."
}

need_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}Execute como root: sudo bash $0${NC}"
    exit 1
  fi
}

check_command() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_NAME="${PRETTY_NAME:-unknown}"
  else
    err "Não foi possível detectar o sistema operacional."
    exit 1
  fi

  case "$OS_ID" in
    ubuntu|debian)
      export DEBIAN_FRONTEND=noninteractive
      PKG_UPDATE="apt update -y"
      PKG_UPGRADE="apt full-upgrade -y"
      PKG_INSTALL="apt install -y"
      ;;
    amzn|amazon)
      if check_command dnf; then
        PKG_UPDATE="dnf makecache -y"
        PKG_UPGRADE="dnf upgrade -y --refresh"
        PKG_INSTALL="dnf install -y"
      else
        PKG_UPDATE="yum makecache -y"
        PKG_UPGRADE="yum update -y"
        PKG_INSTALL="yum install -y"
      fi
      ;;
    *)
      err "Sistema não suportado: $OS_NAME"
      exit 1
      ;;
  esac
}

progress_start() {
  TOTAL_STEPS="$1"
  CURRENT_STEP=0
}

progress_step() {
  CURRENT_STEP=$((CURRENT_STEP+1))
  local msg="$1"
  local width=34
  local filled=$(( CURRENT_STEP * width / TOTAL_STEPS ))
  local empty=$(( width - filled ))
  printf "\r${CYAN}["
  if (( filled > 0 )); then printf "%0.s█" $(seq 1 "$filled"); fi
  if (( empty > 0 )); then printf "%0.s·" $(seq 1 "$empty"); fi
  printf "] ${BOLD}%d/%d${NC} %s   " "$CURRENT_STEP" "$TOTAL_STEPS" "$msg"
  if [[ "$CURRENT_STEP" -eq "$TOTAL_STEPS" ]]; then
    echo
  fi
}

run_quiet() {
  local cmd="$1"
  log "RUN: $cmd"
  bash -c "$cmd" >> "$LOG_FILE" 2>&1
}

install_base_tools() {
  case "$OS_ID" in
    ubuntu|debian)
      run_quiet "$PKG_INSTALL curl wget ca-certificates tzdata nano vim htop jq git unzip sudo openssh-server"
      ;;
    amzn|amazon)
      run_quiet "$PKG_INSTALL curl wget ca-certificates tzdata nano vim htop jq git unzip shadow-utils util-linux sudo openssh-server"
      ;;
  esac
}

get_ssh_service_name() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
    echo "sshd"
  else
    echo "ssh"
  fi
}

validate_and_restart_ssh() {
  local svc
  svc="$(get_ssh_service_name)"
  if check_command sshd && sshd -t >> "$LOG_FILE" 2>&1; then
    systemctl enable "$svc" >> "$LOG_FILE" 2>&1 || true
    systemctl restart "$svc" >> "$LOG_FILE" 2>&1
    return 0
  fi
  return 1
}

ensure_ssh_setting() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -qE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i -E "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|" "$file"
  else
    printf '\n%s %s\n' "$key" "$value" >> "$file"
  fi
}

ask_root_password() {
  local p1 p2
  while true; do
    echo
    read -r -s -p "Digite a nova senha do root: " p1
    echo
    read -r -s -p "Confirme a nova senha do root: " p2
    echo

    if [[ -z "$p1" ]]; then
      warn "A senha não pode ficar vazia."
      continue
    fi

    if [[ "$p1" != "$p2" ]]; then
      warn "As senhas não conferem. Tente novamente."
      continue
    fi

    ROOT_PASSWORD="$p1"
    break
  done
}

update_system_auto() {
  header
  echo -e "${BOLD}Atualização automática do sistema${NC}"
  line
  progress_start 3
  progress_step "Atualizando repositórios"
  run_quiet "$PKG_UPDATE"
  progress_step "Atualizando pacotes"
  run_quiet "$PKG_UPGRADE"
  progress_step "Instalando utilitários base"
  install_base_tools
  echo
  ok "Sistema atualizado."
  pause
}

enable_root_auto() {
  header
  echo -e "${BOLD}Liberação do root com senha${NC}"
  line

  ask_root_password

  progress_start 6
  progress_step "Desbloqueando conta root"
  passwd -u root >> "$LOG_FILE" 2>&1 || true

  progress_step "Aplicando nova senha"
  echo "root:${ROOT_PASSWORD}" | chpasswd >> "$LOG_FILE" 2>&1
  unset ROOT_PASSWORD

  progress_step "Ajustando SSH para root"
  ensure_ssh_setting "PermitRootLogin" "yes"
  ensure_ssh_setting "PasswordAuthentication" "yes"
  ensure_ssh_setting "PubkeyAuthentication" "yes"
  ensure_ssh_setting "ChallengeResponseAuthentication" "no"
  ensure_ssh_setting "UsePAM" "yes"

  progress_step "Garantindo diretório do root"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh

  progress_step "Validando e reiniciando SSH"
  if ! validate_and_restart_ssh; then
    err "Falha ao validar/reiniciar o SSH. Verifique $LOG_FILE"
    pause
    return
  fi

  progress_step "Concluindo"
  sleep 0.2

  echo
  ok "Root liberado com senha e SSH pronto para login como root."
  warn "Confirme no Security Group da AWS se a porta SSH está liberada."
  pause
}

set_hostname_auto() {
  header
  echo -e "${BOLD}Configuração automática de hostname${NC}"
  line

  if [[ -z "$CONFIG_HOSTNAME" ]]; then
    err "Defina CONFIG_HOSTNAME no topo do script."
    pause
    return
  fi

  progress_start 3
  progress_step "Aplicando hostname"
  hostnamectl set-hostname "$CONFIG_HOSTNAME" >> "$LOG_FILE" 2>&1

  progress_step "Ajustando /etc/hosts"
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $CONFIG_HOSTNAME/" /etc/hosts
  elif ! grep -qE "(^|[[:space:]])$CONFIG_HOSTNAME([[:space:]]|$)" /etc/hosts; then
    echo "127.0.1.1 $CONFIG_HOSTNAME" >> /etc/hosts
  fi

  progress_step "Concluindo"
  sleep 0.2

  echo
  ok "Hostname definido: $CONFIG_HOSTNAME"
  pause
}

set_timezone_auto() {
  header
  echo -e "${BOLD}Configuração automática de timezone${NC}"
  line

  if [[ -z "$CONFIG_TIMEZONE" ]]; then
    err "Defina CONFIG_TIMEZONE no topo do script."
    pause
    return
  fi

  progress_start 2
  progress_step "Aplicando timezone"
  timedatectl set-timezone "$CONFIG_TIMEZONE" >> "$LOG_FILE" 2>&1
  progress_step "Concluindo"
  sleep 0.2

  echo
  ok "Timezone definida: $CONFIG_TIMEZONE"
  pause
}

get_total_ram_mb() {
  awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo
}

get_total_swap_mb() {
  if check_command swapon; then
    swapon --show --bytes --noheadings 2>/dev/null | awk '{sum+=$3} END {print int(sum/1024/1024)}'
  else
    echo 0
  fi
}

recommended_swap_mb() {
  local ram_mb="$1"
  if (( ram_mb <= 1024 )); then
    echo 2048
  elif (( ram_mb <= 2048 )); then
    echo 4096
  elif (( ram_mb <= 4096 )); then
    echo 4096
  elif (( ram_mb <= 8192 )); then
    echo 8192
  elif (( ram_mb <= 16384 )); then
    echo 8192
  else
    echo 4096
  fi
}

configure_swap_auto() {
  header
  echo -e "${BOLD}Configuração automática de swap${NC}"
  line

  local ram_mb current_swap_mb rec_mb
  ram_mb="$(get_total_ram_mb)"
  current_swap_mb="$(get_total_swap_mb)"
  rec_mb="$(recommended_swap_mb "$ram_mb")"

  progress_start 5
  progress_step "Detectando memória do servidor"
  log "RAM=${ram_mb}MB SWAP_ATUAL=${current_swap_mb}MB SWAP_RECOMENDADO=${rec_mb}MB"

  progress_step "Ajustando swap recomendado"
  if (( current_swap_mb < rec_mb )); then
    if [[ -f /swapfile ]]; then
      swapoff /swapfile >> "$LOG_FILE" 2>&1 || true
      rm -f /swapfile
    fi
    if check_command fallocate; then
      fallocate -l "${rec_mb}M" /swapfile >> "$LOG_FILE" 2>&1
    else
      dd if=/dev/zero of=/swapfile bs=1M count="$rec_mb" status=none >> "$LOG_FILE" 2>&1
    fi
    chmod 600 /swapfile
    mkswap /swapfile >> "$LOG_FILE" 2>&1
    swapon /swapfile >> "$LOG_FILE" 2>&1
    if ! grep -q '^/swapfile ' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi

  progress_step "Aplicando tuning de swap"
  cat > /etc/sysctl.d/99-swap-tuning.conf <<'EOSWAP'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOSWAP

  progress_step "Recarregando parâmetros"
  sysctl --system >> "$LOG_FILE" 2>&1 || true

  progress_step "Concluindo"
  sleep 0.2

  echo
  ok "Swap ajustado automaticamente."
  echo -e "${DIM}RAM: ${ram_mb} MB | Swap atual: $(get_total_swap_mb) MB${NC}"
  pause
}

update_kernel_auto() {
  header
  echo -e "${BOLD}Atualização automática de kernel otimizado${NC}"
  line

  progress_start 4
  progress_step "Atualizando índices"
  run_quiet "$PKG_UPDATE"

  progress_step "Instalando linha de kernel ideal"
  case "$OS_ID" in
    ubuntu)
      run_quiet "$PKG_INSTALL linux-aws linux-headers-aws"
      ;;
    debian)
      if apt-cache show linux-image-cloud-amd64 >/dev/null 2>&1; then
        run_quiet "$PKG_INSTALL linux-image-cloud-amd64 linux-headers-cloud-amd64"
      else
        run_quiet "$PKG_INSTALL linux-image-amd64 linux-headers-amd64"
      fi
      ;;
    amzn|amazon)
      if check_command dnf; then
        run_quiet "dnf upgrade -y --refresh kernel kernel-tools kernel-tools-libs"
      else
        run_quiet "yum update -y kernel kernel-tools kernel-tools-libs"
      fi
      ;;
  esac

  progress_step "Finalizando atualização"
  run_quiet "$PKG_UPGRADE"

  progress_step "Concluindo"
  sleep 0.2

  echo
  ok "Kernel otimizado atualizado."
  warn "Reinicie o servidor depois para carregar o kernel novo."
  pause
}

apply_connection_improvements_auto() {
  header
  echo -e "${BOLD}Melhorias automáticas de conexão${NC}"
  line

  progress_start 4
  progress_step "Aplicando parâmetros de rede"
  cat > /etc/sysctl.d/99-aws-network-tuning.conf <<'EONET'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_tw_reuse=1
fs.file-max=2097152
EONET

  progress_step "Ajustando limites do sistema"
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-aws-limits.conf <<'EOLIMITS'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOLIMITS

  progress_step "Recarregando sysctl"
  sysctl --system >> "$LOG_FILE" 2>&1 || true

  progress_step "Concluindo"
  sleep 0.2

  echo
  ok "Melhorias de conexão aplicadas."
  echo -e "${DIM}TCP congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo desconhecido)${NC}"
  pause
}

run_all_auto() {
  header
  echo -e "${BOLD}Execução automática completa${NC}"
  line

  ask_root_password

  progress_start 7
  progress_step "Atualizando sistema"
  run_quiet "$PKG_UPDATE"
  run_quiet "$PKG_UPGRADE"
  install_base_tools

  progress_step "Liberando root com senha"
  passwd -u root >> "$LOG_FILE" 2>&1 || true
  echo "root:${ROOT_PASSWORD}" | chpasswd >> "$LOG_FILE" 2>&1
  unset ROOT_PASSWORD
  ensure_ssh_setting "PermitRootLogin" "yes"
  ensure_ssh_setting "PasswordAuthentication" "yes"
  ensure_ssh_setting "PubkeyAuthentication" "yes"
  ensure_ssh_setting "ChallengeResponseAuthentication" "no"
  ensure_ssh_setting "UsePAM" "yes"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  validate_and_restart_ssh

  progress_step "Definindo hostname"
  hostnamectl set-hostname "$CONFIG_HOSTNAME" >> "$LOG_FILE" 2>&1
  if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $CONFIG_HOSTNAME/" /etc/hosts
  elif ! grep -qE "(^|[[:space:]])$CONFIG_HOSTNAME([[:space:]]|$)" /etc/hosts; then
    echo "127.0.1.1 $CONFIG_HOSTNAME" >> /etc/hosts
  fi

  progress_step "Definindo timezone"
  timedatectl set-timezone "$CONFIG_TIMEZONE" >> "$LOG_FILE" 2>&1

  progress_step "Configurando swap"
  local ram_mb current_swap_mb rec_mb
  ram_mb="$(get_total_ram_mb)"
  current_swap_mb="$(get_total_swap_mb)"
  rec_mb="$(recommended_swap_mb "$ram_mb")"
  if (( current_swap_mb < rec_mb )); then
    if [[ -f /swapfile ]]; then
      swapoff /swapfile >> "$LOG_FILE" 2>&1 || true
      rm -f /swapfile
    fi
    if check_command fallocate; then
      fallocate -l "${rec_mb}M" /swapfile >> "$LOG_FILE" 2>&1
    else
      dd if=/dev/zero of=/swapfile bs=1M count="$rec_mb" status=none >> "$LOG_FILE" 2>&1
    fi
    chmod 600 /swapfile
    mkswap /swapfile >> "$LOG_FILE" 2>&1
    swapon /swapfile >> "$LOG_FILE" 2>&1
    if ! grep -q '^/swapfile ' /etc/fstab; then
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
  fi
  cat > /etc/sysctl.d/99-swap-tuning.conf <<'EOSWAPALL'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOSWAPALL

  progress_step "Atualizando kernel otimizado"
  case "$OS_ID" in
    ubuntu)
      run_quiet "$PKG_INSTALL linux-aws linux-headers-aws"
      ;;
    debian)
      if apt-cache show linux-image-cloud-amd64 >/dev/null 2>&1; then
        run_quiet "$PKG_INSTALL linux-image-cloud-amd64 linux-headers-cloud-amd64"
      else
        run_quiet "$PKG_INSTALL linux-image-amd64 linux-headers-amd64"
      fi
      ;;
    amzn|amazon)
      if check_command dnf; then
        run_quiet "dnf upgrade -y --refresh kernel kernel-tools kernel-tools-libs"
      else
        run_quiet "yum update -y kernel kernel-tools kernel-tools-libs"
      fi
      ;;
  esac

  progress_step "Aplicando melhorias de conexão"
  cat > /etc/sysctl.d/99-aws-network-tuning.conf <<'EONETALL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 65536 33554432
net.ipv4.ip_local_port_range=10240 65535
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=60
net.ipv4.tcp_keepalive_probes=5
net.ipv4.tcp_tw_reuse=1
fs.file-max=2097152
EONETALL
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-aws-limits.conf <<'EOLIMITSALL'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOLIMITSALL
  sysctl --system >> "$LOG_FILE" 2>&1 || true

  echo
  ok "Execução completa finalizada."
  warn "Reinício recomendado para ativar o kernel novo."

  if [[ "$CONFIG_AUTO_REBOOT" == "true" ]]; then
    warn "Reiniciando automaticamente em 5 segundos..."
    sleep 5
    reboot
  else
    pause
  fi
}

show_summary() {
  header
  echo -e "${BOLD}Resumo do servidor${NC}"
  line
  echo -e "${CYAN}Sistema:${NC} $OS_NAME"
  echo -e "${CYAN}Kernel atual:${NC} $(uname -r)"
  echo -e "${CYAN}Hostname:${NC} $(hostname)"
  echo -e "${CYAN}Timezone:${NC} $(timedatectl show --property=Timezone --value 2>/dev/null || echo desconhecida)"
  echo -e "${CYAN}PermitRootLogin:${NC} $(grep -E '^[#[:space:]]*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -n1 | awk '{print $2}' || echo desconhecido)"
  echo -e "${CYAN}PasswordAuthentication:${NC} $(grep -E '^[#[:space:]]*PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | tail -n1 | awk '{print $2}' || echo desconhecido)"
  echo -e "${CYAN}Memória:${NC}"
  free -h
  echo
  echo -e "${CYAN}TCP congestion control:${NC} $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo desconhecido)"
  echo -e "${CYAN}Swap atual:${NC} $(get_total_swap_mb) MB"
  echo
  echo -e "${DIM}Log: $LOG_FILE${NC}"
  pause
}

main_menu() {
  while true; do
    header
    echo -e "${WHITE}${BOLD}Config atual fixa:${NC}"
    echo -e "  Hostname      : ${CYAN}${CONFIG_HOSTNAME}${NC}"
    echo -e "  Timezone      : ${CYAN}${CONFIG_TIMEZONE}${NC}"
    echo -e "  Auto reboot   : ${CYAN}${CONFIG_AUTO_REBOOT}${NC}"
    echo
    line
    echo -e "${BOLD}1)${NC} Atualizar sistema"
    echo -e "${BOLD}2)${NC} Liberar root e pedir senha"
    echo -e "${BOLD}3)${NC} Definir hostname"
    echo -e "${BOLD}4)${NC} Definir timezone"
    echo -e "${BOLD}5)${NC} Configurar swap automático"
    echo -e "${BOLD}6)${NC} Atualizar kernel otimizado"
    echo -e "${BOLD}7)${NC} Aplicar melhorias de conexão"
    echo -e "${BOLD}8)${NC} Executar tudo automático"
    echo -e "${BOLD}9)${NC} Ver resumo"
    echo -e "${BOLD}0)${NC} Sair"
    echo
    read -r -p "Escolha somente a opção: " opt

    case "$opt" in
      1) update_system_auto ;;
      2) enable_root_auto ;;
      3) set_hostname_auto ;;
      4) set_timezone_auto ;;
      5) configure_swap_auto ;;
      6) update_kernel_auto ;;
      7) apply_connection_improvements_auto ;;
      8) run_all_auto ;;
      9) show_summary ;;
      0) exit 0 ;;
      *) warn "Opção inválida."; pause ;;
    esac
  done
}

need_root
detect_os
main_menu
