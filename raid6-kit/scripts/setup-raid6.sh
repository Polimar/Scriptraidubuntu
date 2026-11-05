#!/usr/bin/env bash
# setup-raid6.sh - installazione offline di mdadm e creazione interattiva di un array.
# Il nome del file resta setup-raid6.sh: lo scenario previsto e RAID6, ma lo script
# chiede il livello e accetta tutti quelli che mdadm sa creare su dischi dati.
# Target: Ubuntu 24.04 LTS (noble) amd64, senza internet.
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_DIR="${KIT_DIR}/packages"
MD_DEVICE="${MD_DEVICE:-/dev/md0}"
CHUNK_KIB="${CHUNK_KIB:-512}"
# Se esporti MOUNT_POINT o ARRAY_NAME, diventano il default del prompt, non un valore fisso.
ENV_MOUNT_POINT="${MOUNT_POINT:-}"
ENV_ARRAY_NAME="${ARRAY_NAME:-}"

RED=$'\033[1;31m'
YEL=$'\033[1;33m'
GRN=$'\033[1;32m'
BLU=$'\033[1;34m'
RST=$'\033[0m'

# Messaggi sempre su stderr: lo stdout di alcune funzioni e un percorso device.
die() { echo "${RED}ERRORE:${RST} $*" >&2; exit 1; }
info() { echo "${BLU}->${RST} $*" >&2; }
ok() { echo "${GRN}OK${RST} $*" >&2; }
warn() { echo "${YEL}ATTENZIONE:${RST} $*" >&2; }

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Lancia come root: sudo bash $0"
}

confirm_yes() {
  local prompt="${1:-Confermi?}"
  local ans
  read -r -p "${prompt} Digita YES in maiuscolo per continuare: " ans || die "Input interrotto."
  [[ "${ans}" == "YES" ]] || die "Annullato."
}

check_arch() {
  local arch
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  [[ "${arch}" == "amd64" ]] || die "Architettura '${arch:-sconosciuta}' non supportata da questo kit (serve amd64)."
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${VERSION_CODENAME:-}" != "noble" && "${VERSION_ID:-}" != "24.04" ]]; then
      warn "OS rilevato: ${PRETTY_NAME:-sconosciuto}. Il kit e per Ubuntu 24.04 (noble)."
      if [[ "${RAID6_PLAN_ONLY:-}" != "1" ]]; then
        confirm_yes "Vuoi continuare lo stesso?"
      fi
    fi
  fi
}

is_protected_pkg() {
  case "$1" in
    libc6|libudev1|udev|systemd|systemd-dev|libsystemd0|libsystemd-shared|dpkg|tar|gcc-14-base|libgcc-s1|libstdc++6)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_installed() {
  local st
  st="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)"
  [[ "${st}" == "install ok installed" ]]
}

installed_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

version_satisfies() {
  local have="$1" op="$2" need="$3" cmp
  [[ -z "${op}" ]] && return 0
  case "${op}" in
    '>=') cmp=ge ;;
    '>>'|'>') cmp=gt ;;
    '=') cmp=eq ;;
    '<=') cmp=le ;;
    '<<'|'<') cmp=lt ;;
    *) die "Operatore di versione non gestito: ${op}" ;;
  esac
  dpkg --compare-versions "${have}" "${cmp}" "${need}"
}

load_deb_index() {
  [[ -d "${PKG_DIR}" ]] || die "Cartella pacchetti non trovata: ${PKG_DIR}"
  shopt -s nullglob
  local debs=( "${PKG_DIR}"/*.deb )
  [[ ${#debs[@]} -gt 0 ]] || die "Nessun .deb in ${PKG_DIR}"
  declare -gA DEB_OF=()
  declare -gA VER_OF=()
  local deb pkg ver arch
  for deb in "${debs[@]}"; do
    pkg="$(dpkg-deb -f "${deb}" Package 2>/dev/null)" || die "Deb illeggibile: ${deb}"
    ver="$(dpkg-deb -f "${deb}" Version)"
    arch="$(dpkg-deb -f "${deb}" Architecture)"
    [[ -n "${pkg}" && -n "${ver}" ]] || die "Controllo incompleto: ${deb}"
    [[ "${arch}" == "amd64" || "${arch}" == "all" ]] || die "Architettura ${arch} in ${deb} (atteso amd64 o all)."
    if [[ -n "${DEB_OF[${pkg}]:-}" ]]; then
      die "Pacchetto duplicato nel kit: ${pkg}"
    fi
    DEB_OF["${pkg}"]="${deb}"
    VER_OF["${pkg}"]="${ver}"
  done
  if [[ -f "${PKG_DIR}/MANIFEST.txt" ]]; then
    local manifest_n="${#debs[@]}"
    local listed
    listed="$(awk -F'\t' '!/^#/ && NF >= 2 { c++ } END { print c + 0 }' "${PKG_DIR}/MANIFEST.txt")"
    if [[ "${listed}" != "${manifest_n}" ]]; then
      warn "MANIFEST.txt elenca ${listed} pacchetti, nella cartella ci sono ${manifest_n} .deb. La copia su USB potrebbe essere incompleta."
    fi
  fi
}

# Stampa le dipendenze di primo livello (Depends + Pre-Depends), una per riga,
# gia spezzate sulle virgole fuori dalle parentesi.
relation_groups() {
  local pkg="$1" deb raw depends pre
  deb="${DEB_OF[${pkg}]:-}"
  [[ -n "${deb}" ]] || return 0
  depends="$(dpkg-deb -f "${deb}" Depends 2>/dev/null || true)"
  pre="$(dpkg-deb -f "${deb}" Pre-Depends 2>/dev/null || true)"
  raw="${depends}, ${pre}"
  raw="${raw//$'\n'/ }"
  local -a parts=()
  local cur="" depth=0 i ch
  for (( i=0; i<${#raw}; i++ )); do
    ch="${raw:i:1}"
    if [[ "${ch}" == "(" ]]; then
      depth=$((depth + 1))
      cur+="${ch}"
    elif [[ "${ch}" == ")" ]]; then
      depth=$((depth - 1))
      cur+="${ch}"
    elif [[ "${ch}" == "," && "${depth}" -eq 0 ]]; then
      parts+=( "${cur}" )
      cur=""
    else
      cur+="${ch}"
    fi
  done
  [[ -n "${cur}" ]] && parts+=( "${cur}" )
  local part
  for part in "${parts[@]}"; do
    part="$(sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"${part}")"
    [[ -n "${part}" ]] || continue
    printf '%s\n' "${part}"
  done
}

split_alts() {
  local group="$1"
  local -a alts=()
  local cur="" depth=0 i ch
  for (( i=0; i<${#group}; i++ )); do
    ch="${group:i:1}"
    if [[ "${ch}" == "(" ]]; then
      depth=$((depth + 1))
      cur+="${ch}"
    elif [[ "${ch}" == ")" ]]; then
      depth=$((depth - 1))
      cur+="${ch}"
    elif [[ "${ch}" == "|" && "${depth}" -eq 0 ]]; then
      alts+=( "${cur}" )
      cur=""
    else
      cur+="${ch}"
    fi
  done
  [[ -n "${cur}" ]] && alts+=( "${cur}" )
  local alt
  for alt in "${alts[@]}"; do
    printf '%s\n' "${alt}"
  done
}

# Scrive "nome<TAB>op<TAB>versione" per un'alternativa. op e versione vuoti se assenti.
parse_alt() {
  local alt="$1" op="" need="" name
  if [[ "${alt}" =~ \([[:space:]]*([\<\>=]+)[[:space:]]*([^\)]+)[[:space:]]*\) ]]; then
    op="${BASH_REMATCH[1]}"
    need="${BASH_REMATCH[2]//[[:space:]]/}"
  fi
  name="${alt%%(*}"
  name="${name%%\[*}"
  name="${name//[[:space:]]/}"
  name="${name%%:*}"
  [[ "${name}" =~ ^[a-zA-Z0-9][a-zA-Z0-9.+-]*$ ]] || return 1
  printf '%s\t%s\t%s\n' "${name}" "${op}" "${need}"
}

# Decide cosa fare di un gruppo "a | b | c".
# Stampa "ok" se gia soddisfatto, oppure "add <pkg>" se va installato/aggiornato.
satisfy_group() {
  local group="$1"
  local -a alts=()
  mapfile -t alts < <(split_alts "${group}")
  local alt parsed name op need have kitver
  local -a install_fallback=()
  local -a upgrade_fallback=()

  for alt in "${alts[@]}"; do
    parsed="$(parse_alt "${alt}")" || continue
    IFS=$'\t' read -r name op need <<<"${parsed}"
    if is_installed "${name}"; then
      have="$(installed_version "${name}")"
      if version_satisfies "${have}" "${op}" "${need}"; then
        printf 'ok\n'
        return 0
      fi
      kitver="${VER_OF[${name}]:-}"
      if [[ -n "${kitver}" ]] && version_satisfies "${kitver}" "${op}" "${need}" && dpkg --compare-versions "${kitver}" gt "${have}"; then
        upgrade_fallback+=( "${name}" )
      fi
    elif [[ -n "${VER_OF[${name}]:-}" ]]; then
      kitver="${VER_OF[${name}]}"
      if version_satisfies "${kitver}" "${op}" "${need}"; then
        install_fallback+=( "${name}" )
      fi
    fi
  done

  if [[ ${#upgrade_fallback[@]} -gt 0 ]]; then
    name="${upgrade_fallback[0]}"
    if is_protected_pkg "${name}"; then
      local have_ver
      have_ver="$(installed_version "${name}")"
      die "Serve ${name} versione ${VER_OF[${name}]} ma sul sistema c'e ${have_ver}. Non aggiorno ${name} in automatico: aggiornalo prima dal sistema, poi rilancia."
    fi
    printf 'add %s\n' "${name}"
    return 0
  fi
  if [[ ${#install_fallback[@]} -gt 0 ]]; then
    printf 'add %s\n' "${install_fallback[0]}"
    return 0
  fi
  die "Dipendenza non soddisfatta e non presente nel kit: ${group}"
}

resolve_install_set() {
  load_deb_index
  local -A seen=()
  local -a queue=()
  local -A want=()
  local seeds=( mdadm parted gdisk xfsprogs e2fsprogs finalrd kmod )
  local seed pkg action dep_pkg group qi=0
  for seed in "${seeds[@]}"; do
    [[ -n "${DEB_OF[${seed}]:-}" ]] || die "Il kit non contiene ${seed}"
    if is_installed "${seed}"; then
      continue
    fi
    if [[ -z "${seen[${seed}]:-}" ]]; then
      seen["${seed}"]=1
      queue+=( "${seed}" )
    fi
  done

  while (( qi < ${#queue[@]} )); do
    pkg="${queue[qi]}"
    qi=$((qi + 1))
    want["${pkg}"]=1
    while IFS= read -r group; do
      [[ -n "${group}" ]] || continue
      action="$(satisfy_group "${group}")" || exit 1
      if [[ "${action}" == "ok" ]]; then
        continue
      fi
      dep_pkg="${action#add }"
      [[ "${dep_pkg}" != "${action}" ]] || die "Risposta interna inattesa: ${action}"
      if [[ -z "${seen[${dep_pkg}]:-}" ]]; then
        seen["${dep_pkg}"]=1
        queue+=( "${dep_pkg}" )
      fi
    done < <(relation_groups "${pkg}")
  done

  INSTALL_DEBS=()
  local name
  if (( ${#want[@]} > 0 )); then
    for name in "${!want[@]}"; do
      INSTALL_DEBS+=( "${DEB_OF[${name}]}" )
    done
    mapfile -t INSTALL_DEBS < <(printf '%s\n' "${INSTALL_DEBS[@]}" | sort)
  fi
}

preseed_mdadm() {
  command -v debconf-set-selections >/dev/null 2>&1 || return 0
  debconf-set-selections <<'EOF' || true
mdadm mdadm/autocheck boolean true
mdadm mdadm/autoscan boolean true
mdadm mdadm/start_daemon boolean true
mdadm mdadm/mail_to string root
EOF
}

apply_install() {
  export DEBIAN_FRONTEND=noninteractive
  export DEBCONF_NONINTERACTIVE_SEEN=true
  export DEBIAN_PRIORITY=critical
  export UCF_FORCE_CONFFOLD=1
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none

  if [[ ${#INSTALL_DEBS[@]} -eq 0 ]]; then
    ok "Nessun pacchetto da installare."
  else
    info "Installo ${#INSTALL_DEBS[@]} pacchetto/i mancanti (non aggiorno il resto del sistema):"
    local deb
    for deb in "${INSTALL_DEBS[@]}"; do
      echo "  - $(dpkg-deb -f "${deb}" Package) $(dpkg-deb -f "${deb}" Version)" >&2
    done
    preseed_mdadm
    dpkg --force-confdef --force-confold -i "${INSTALL_DEBS[@]}" || true
    dpkg --configure -a || true
    dpkg --force-confdef --force-confold -i "${INSTALL_DEBS[@]}" \
      || die "dpkg ha fallito. Nessun disco e stato modificato. Leggi i messaggi sopra."
  fi
  hash -r
  command -v mdadm >/dev/null 2>&1 || die "mdadm ancora assente dopo l'installazione."
  command -v sgdisk >/dev/null 2>&1 || command -v parted >/dev/null 2>&1 || die "Manca sia sgdisk sia parted."
  ok "mdadm pronto: $(mdadm --version 2>&1 | head -1)"
}

is_candidate_name() {
  [[ "$1" =~ ^(sd[a-z]+|hd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+)$ ]]
}

is_system_disk() {
  local disk="$1" base root_src root_disk line
  base="$(basename "${disk}")"
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  root_src="${root_src%%\[*}"
  if [[ -n "${root_src}" ]]; then
    root_disk="$(lsblk -no PKNAME "${root_src}" 2>/dev/null | head -1 || true)"
    if [[ -z "${root_disk}" ]]; then
      root_disk="$(basename "${root_src}")"
      root_disk="$(sed -E 's/p?[0-9]+$//' <<<"${root_disk}")"
    fi
    [[ "${base}" == "${root_disk}" ]] && return 0
  fi
  # Qualsiasi mount, swap o holder aperto sul disco o sulle sue partizioni.
  while IFS= read -r line; do
    [[ "${line}" == /* ]] && return 0
    [[ "${line}" == "[SWAP]" ]] && return 0
    [[ "${line}" == "swap" ]] && return 0
  done < <(lsblk -ln -o MOUNTPOINT,FSTYPE "${disk}" 2>/dev/null | awk '{print $1; print $2}')
  return 1
}

list_candidate_disks() {
  local line name size type model tran
  while IFS= read -r line; do
    name="$(awk '{print $1}' <<<"${line}")"
    size="$(awk '{print $2}' <<<"${line}")"
    type="$(awk '{print $3}' <<<"${line}")"
    [[ "${type}" == "disk" || "${type}" == "loop" ]] || continue
    is_candidate_name "${name}" || continue
    if is_system_disk "/dev/${name}"; then
      continue
    fi
    model="$(lsblk -dno MODEL "/dev/${name}" 2>/dev/null | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//' || true)"
    tran="$(lsblk -dno TRAN "/dev/${name}" 2>/dev/null | tr -d ' ' || true)"
    model="${model//|/\/}"
    printf '%s|%s|%s|%s\n' "/dev/${name}" "${size}" "${model:-?}" "${tran:-?}"
  done < <(LC_ALL=C lsblk -dn -o NAME,SIZE,TYPE)
}

prompt_uint() {
  local prompt="$1" default="$2" min="$3" ans
  while true; do
    read -r -p "${prompt} [${default}]: " ans || die "Input interrotto."
    if [[ -z "${ans//[[:space:]]/}" ]]; then
      ans="${default}"
    elif [[ "${ans}" =~ [[:space:]] ]]; then
      echo "Un solo numero, senza spazi. I dischi si scelgono dopo." >&2
      continue
    fi
    if [[ "${ans}" =~ ^[0-9]+$ ]] && (( 10#${ans} >= min )); then
      printf '%s\n' "$((10#${ans}))"
      return 0
    fi
    echo "Serve un numero intero >= ${min}." >&2
  done
}

pick_indices() {
  local count="$1" label="$2" dest_name="$3"
  shift 3
  local -a rows=( "$@" )
  local -n _dest_ref="${dest_name}"
  local max="${#rows[@]}"
  if (( count == 0 )); then
    _dest_ref=()
    return 0
  fi
  local raw n path ok_pick
  local -a nums=() chosen=()
  local -A seen=()
  while true; do
    read -r -p "Seleziona ${count} dischi per ${label} (numeri separati da spazio, es. 1 2 3): " raw || die "Input interrotto."
    nums=()
    read -r -a nums <<<"${raw}"
    if [[ ${#nums[@]} -ne ${count} ]]; then
      echo "Servono esattamente ${count} numeri." >&2
      continue
    fi
    chosen=()
    seen=()
    ok_pick=1
    for n in "${nums[@]}"; do
      if ! [[ "${n}" =~ ^[0-9]+$ ]] || (( 10#${n} < 1 || 10#${n} > max )); then
        echo "Indice non valido: ${n}" >&2
        ok_pick=0
        break
      fi
      n=$((10#${n}))
      if [[ -n "${seen[${n}]:-}" ]]; then
        echo "Duplicato: ${n}" >&2
        ok_pick=0
        break
      fi
      seen[${n}]=1
      path="${rows[$((n - 1))]%%|*}"
      [[ -b "${path}" ]] || die "Il device ${path} non esiste piu."
      chosen+=( "${path}" )
    done
    [[ "${ok_pick}" -eq 1 ]] || continue
    _dest_ref=( "${chosen[@]}" )
    return 0
  done
}

# Un disco gia membro di md127/md0 e "busy": wipefs e --create falliscono.
# Dopo il YES si ferma solo l'array che tiene quel disco, non gli altri.
# Ferma solo l'array che tiene il disco. Non azzera nulla: il superblocco
# va cancellato una volta sola, prima della GPT, altrimenti si cancella la tabella.
stop_holders() {
  local disk="$1" base glob node holder dev mounted syspart round changed
  base="$(basename "${disk}")"
  glob="$(shopt -p nullglob)"
  shopt -s nullglob
  local -a nodes=()
  for (( round=0; round<6; round++ )); do
    nodes=( "/sys/block/${base}" )
    for syspart in /sys/block/"${base}"/"${base}"*; do
      [[ -d "${syspart}" ]] && nodes+=( "${syspart}" )
    done
    changed=0
    for node in "${nodes[@]}"; do
      [[ -d "${node}/holders" ]] || continue
      for holder in "${node}/holders/"*; do
        [[ -e "${holder}" ]] || continue
        dev="/dev/$(basename "${holder}")"
        [[ -b "${dev}" ]] || continue
        while IFS= read -r mounted; do
          [[ -n "${mounted}" ]] || continue
          umount "${mounted}" 2>/dev/null || umount -l "${mounted}" 2>/dev/null || true
        done < <(findmnt -rn -o TARGET -S "${dev}" 2>/dev/null || true)
        if mdadm --stop "${dev}" >&2; then
          info "Fermato ${dev}: teneva ${disk}"
          changed=1
        fi
      done
    done
    (( changed == 0 )) && break
  done
  for node in /sys/block/"${base}" /sys/block/"${base}"/"${base}"*; do
    [[ -d "${node}/holders" ]] || continue
    for holder in "${node}/holders/"*; do
      [[ -e "${holder}" ]] || continue
      eval "${glob}"
      die "${disk} e ancora usato da /dev/$(basename "${holder}"). Smontalo e rilancia."
    done
  done
  eval "${glob}"
}

# Stampa SOLO il percorso della partizione su stdout.
wipe_and_partition() {
  local disk="$1"
  warn "Azzero firme e creo 1 partizione GPT tipo Linux RAID su ${disk}"
  stop_holders "${disk}"
  if command -v mdadm >/dev/null 2>&1; then
    mdadm --zero-superblock --force "${disk}" >/dev/null 2>&1 || true
  fi
  wipefs -a "${disk}" >&2 || die "wipefs non riesce a pulire ${disk}."
  if command -v sgdisk >/dev/null 2>&1; then
    sgdisk --zap-all "${disk}" >&2 || warn "sgdisk --zap-all ha segnalato un errore su ${disk}, continuo"
    sgdisk -o "${disk}" >&2 || warn "sgdisk -o ha segnalato un errore su ${disk}, continuo"
    sgdisk -n 1:1MiB:0 -t 1:FD00 -c 1:raid "${disk}" >&2 || warn "sgdisk -n ha segnalato un errore su ${disk}, verifico se la partizione esiste"
  else
    parted -s "${disk}" mklabel gpt >&2
    parted -s "${disk}" mkpart primary 1MiB 100% >&2
    parted -s "${disk}" set 1 raid on >&2
  fi

  local part="" i
  for (( i=1; i<=40; i++ )); do
    blockdev --rereadpt "${disk}" >/dev/null 2>&1 || true
    partprobe "${disk}" >/dev/null 2>&1 || true
    partx -a "${disk}" >/dev/null 2>&1 || true
    partx -u "${disk}" >/dev/null 2>&1 || true
    if command -v udevadm >/dev/null 2>&1; then
      udevadm settle --timeout=2 >/dev/null 2>&1 || true
    fi
    if [[ -b "${disk}1" ]]; then
      part="${disk}1"
      break
    fi
    if [[ -b "${disk}p1" ]]; then
      part="${disk}p1"
      break
    fi
    sleep 0.2
  done
  [[ -n "${part}" ]] || die "Non trovo la partizione 1 su ${disk} dopo il partizionamento."
  # udev puo riassemblare il superblocco vecchio e far sparire il device un attimo.
  # Non si riazzera il disco intero: la GPT e gia scritta.
  local wiped=0 w
  for (( w=1; w<=30; w++ )); do
    stop_holders "${disk}"
    if [[ -b "${part}" ]] && wipefs -a "${part}" >&2; then
      wiped=1
      break
    fi
    if [[ ! -b "${disk}1" && ! -b "${disk}p1" ]]; then
      blockdev --rereadpt "${disk}" >/dev/null 2>&1 || true
      partx -u "${disk}" >/dev/null 2>&1 || true
      if [[ -b "${disk}1" ]]; then
        part="${disk}1"
      elif [[ -b "${disk}p1" ]]; then
        part="${disk}p1"
      fi
    fi
    sleep 0.3
  done
  (( wiped == 1 )) || die "wipefs non riesce a pulire ${part}."
  if command -v mdadm >/dev/null 2>&1; then
    mdadm --zero-superblock --force "${part}" >/dev/null 2>&1 || true
  fi
  stop_holders "${disk}"
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=2 >/dev/null 2>&1 || true
  fi
  printf '%s\n' "${part}"
}

describe_disk() {
  local disk="$1" size model
  size="$(LC_ALL=C lsblk -dno SIZE "${disk}" 2>/dev/null | tr -d ' ' || true)"
  model="$(lsblk -dno MODEL "${disk}" 2>/dev/null | sed 's/[[:space:]]\+/ /g;s/^ //;s/ $//' || true)"
  printf '%-12s %8s  %s' "${disk}" "${size:-?}" "${model:-}"
}

warn_small_disks() {
  local d bytes
  for d in "$@"; do
    bytes="$(lsblk -bno SIZE "${d}" 2>/dev/null | head -1 || true)"
    if [[ "${bytes}" =~ ^[0-9]+$ ]] && (( bytes < 1000000000000 )); then
      warn "${d} e piu piccolo di 1 TB. I dischi previsti per questo kit sono da circa 7 TB: controlla di non aver incluso la chiavetta USB."
    fi
  done
}

apply_level_profile() {
  local level="$1"
  RAID_LEVEL="${level}"
  RAID_LAYOUT=""
  ALLOW_SPARE=1
  USE_CHUNK=1
  USE_BITMAP=1
  MIN_ACTIVE=2
  case "${RAID_LEVEL}" in
    linear)
      ALLOW_SPARE=0
      USE_CHUNK=0
      USE_BITMAP=0
      MIN_ACTIVE=2
      ;;
    0)
      ALLOW_SPARE=0
      USE_CHUNK=1
      USE_BITMAP=0
      MIN_ACTIVE=2
      ;;
    1)
      ALLOW_SPARE=1
      USE_CHUNK=0
      USE_BITMAP=1
      MIN_ACTIVE=2
      ;;
    4|5)
      ALLOW_SPARE=1
      USE_CHUNK=1
      USE_BITMAP=1
      MIN_ACTIVE=3
      ;;
    6)
      ALLOW_SPARE=1
      USE_CHUNK=1
      USE_BITMAP=1
      MIN_ACTIVE=4
      ;;
    10)
      ALLOW_SPARE=1
      USE_CHUNK=1
      USE_BITMAP=1
      MIN_ACTIVE=2
      ;;
    *)
      die "Livello interno non gestito: ${RAID_LEVEL}"
      ;;
  esac
}

normalize_level() {
  local ans="${1,,}"
  ans="${ans//[[:space:]]/}"
  ans="${ans#raid}"
  case "${ans}" in
    0|stripe) printf '0\n' ;;
    1|mirror) printf '1\n' ;;
    4) printf '4\n' ;;
    5) printf '5\n' ;;
    6) printf '6\n' ;;
    10) printf '10\n' ;;
    linear) printf 'linear\n' ;;
    *) return 1 ;;
  esac
}

level_title() {
  case "${RAID_LEVEL}" in
    linear) printf 'linear (concatenazione, nessuna ridondanza)' ;;
    0) printf 'RAID0 (stripe, nessuna ridondanza)' ;;
    1) printf 'RAID1 (mirror)' ;;
    4) printf 'RAID4 (parita dedicata)' ;;
    5) printf 'RAID5 (parita distribuita)' ;;
    6) printf 'RAID6 (doppia parita)' ;;
    10) printf 'RAID10 layout %s' "${RAID_LAYOUT:-n2}" ;;
    *) printf 'RAID%s' "${RAID_LEVEL}" ;;
  esac
}

# md-linear e stato tolto nel kernel 6.8 e rimesso dal 6.12.
# Su Ubuntu 24.04 col kernel GA non esiste: non va offerto come se funzionasse.
probe_linear() {
  if [[ -n "${LINEAR_OK:-}" ]]; then
    return 0
  fi
  if modprobe linear >/dev/null 2>&1; then
    LINEAR_OK=1
  else
    LINEAR_OK=0
  fi
}

level_module() {
  case "${1}" in
    linear) printf 'linear\n' ;;
    0) printf 'raid0\n' ;;
    1) printf 'raid1\n' ;;
    10) printf 'raid10\n' ;;
    4|5|6) printf 'raid456\n' ;;
    *) return 1 ;;
  esac
}

print_level_menu() {
  probe_linear
  cat <<'EOF'
Livelli che mdadm sa creare su dischi dati. Invio = 6 (RAID6).
  0        RAID0     stripe, nessuna ridondanza. Minimo 2 dischi. Niente spare.
  1        RAID1     mirror. Minimo 2. Spare ammessi.
  4        RAID4     parita dedicata su un disco. Minimo 3. Spare ammessi.
  5        RAID5     parita distribuita. Minimo 3. Spare ammessi.
  6        RAID6     doppia parita. Minimo 4. Spare ammessi.
  10       RAID10    stripe e mirror. Minimo 2, poi scegli il layout.
EOF
  if (( LINEAR_OK == 1 )); then
    echo "  linear   concatenazione, nessuna ridondanza. Minimo 2. Niente spare."
  else
    echo "  linear   non disponibile: questo kernel non ha md-linear (tolto nel 6.8, torna dal 6.12)."
  fi
  cat <<'EOF'
Accetta anche raid0, raid1, stripe, mirror. Fuori menu, di proposito:
  multipath  non e un RAID di dischi diversi
  faulty     serve solo a simulare guasti, non a conservare dati
EOF
}

choose_level() {
  local n_total="$1" ans lvl mod
  probe_linear
  while true; do
    echo
    print_level_menu
    echo
    if (( LINEAR_OK == 1 )); then
      read -r -p "Livello RAID [0,1,4,5,6,10,linear] (default 6): " ans || die "Input interrotto."
    else
      read -r -p "Livello RAID [0,1,4,5,6,10] (default 6): " ans || die "Input interrotto."
    fi
    if [[ -z "${ans//[[:space:]]/}" ]]; then
      ans="6"
    fi
    if ! lvl="$(normalize_level "${ans}")"; then
      echo "Livello non riconosciuto: ${ans}" >&2
      continue
    fi
    apply_level_profile "${lvl}"
    if [[ "${lvl}" == "linear" && "${LINEAR_OK}" -ne 1 ]]; then
      echo "linear non si puo creare: il kernel in uso non include md-linear." >&2
      echo "E stato rimosso nel kernel 6.8 e reintrodotto dal 6.12. Il kernel GA di Ubuntu 24.04 e il 6.8." >&2
      echo "Scegli un altro livello. Non ho toccato nessun disco." >&2
      continue
    fi
    mod="$(level_module "${lvl}")" || die "Livello interno non gestito: ${lvl}"
    if ! modprobe "${mod}" >/dev/null 2>&1; then
      echo "Il kernel non carica il modulo ${mod}. Scegli un altro livello. Nessun disco e stato toccato." >&2
      continue
    fi
    if (( n_total < MIN_ACTIVE )); then
      echo "Per questo livello servono almeno ${MIN_ACTIVE} dischi e ne vedo ${n_total}. Scegline un altro." >&2
      continue
    fi
    return 0
  done
}

choose_layout() {
  local n_total="$1" ans copies
  echo
  echo "Layout RAID10 (Invio = n2, il piu comune):"
  echo "  n2   near, 2 copie. Letture buone, scrittura normale. Consigliato."
  echo "  f2   far, 2 copie. Letture sequenziali piu veloci, scritture piu lente."
  echo "  o2   offset, 2 copie. Compromesso tra near e far."
  echo "Puoi alzare le copie (n3, f3, ...) se hai abbastanza dischi."
  while true; do
    read -r -p "Layout RAID10 [n2/f2/o2] (default n2): " ans || die "Input interrotto."
    if [[ -z "${ans//[[:space:]]/}" ]]; then
      ans="n2"
    fi
    ans="${ans,,}"
    ans="${ans//[[:space:]]/}"
    if [[ "${ans}" =~ ^[nfo][2-9]$ ]]; then
      copies="${ans:1}"
      if (( n_total < 10#${copies} )); then
        echo "Il layout ${ans} richiede almeno ${copies} dischi, ne vedo ${n_total}." >&2
        continue
      fi
      RAID_LAYOUT="${ans}"
      MIN_ACTIVE="${copies}"
      return 0
    fi
    echo "Layout non valido. Esempi: n2, f2, o2." >&2
  done
}

default_mount_for_level() {
  if [[ -n "${ENV_MOUNT_POINT}" ]]; then
    printf '%s\n' "${ENV_MOUNT_POINT}"
    return 0
  fi
  if [[ "${RAID_LEVEL}" == "linear" ]]; then
    printf '/mnt/linear\n'
  else
    printf '/mnt/raid%s\n' "${RAID_LEVEL}"
  fi
}

default_name_for_level() {
  if [[ -n "${ENV_ARRAY_NAME}" ]]; then
    printf '%s\n' "${ENV_ARRAY_NAME}"
    return 0
  fi
  if [[ "${RAID_LEVEL}" == "linear" ]]; then
    printf 'lineardata\n'
  else
    printf 'raid%sdata\n' "${RAID_LEVEL}"
  fi
}

prompt_text() {
  local prompt="$1" default="$2" ans
  while true; do
    read -r -p "${prompt} [${default}]: " ans || die "Input interrotto."
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    if [[ -z "${ans}" ]]; then
      ans="${default}"
    fi
    if [[ "${ans}" =~ [[:space:]] ]]; then
      echo "Niente spazi." >&2
      continue
    fi
    printf '%s\n' "${ans}"
    return 0
  done
}

mount_point_ok() {
  local mp="$1"
  [[ "${mp}" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [[ "${mp}" != "/" ]] || return 1
  [[ "${mp}" != */ ]] || return 1
  [[ "${mp}" != *//* ]] || return 1
  case "${mp}" in
    /boot|/boot/*|/etc|/etc/*|/usr|/usr/*|/bin|/bin/*|/sbin|/sbin/*|/lib|/lib/*|/lib64|/lib64/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*|/root|/root/*|/home|/home/*)
      return 1
      ;;
  esac
  return 0
}

array_name_ok() {
  [[ "$1" =~ ^[A-Za-z0-9._-]{1,32}$ ]]
}

print_disk_menu() {
  local -a rows=( "$@" )
  local i=1 r path size model tran
  echo
  echo "Dischi candidati (sistema, mount e swap esclusi):"
  echo "------------------------------------------------------------"
  for r in "${rows[@]}"; do
    IFS='|' read -r path size model tran <<<"${r}"
    printf '  [%2d]  %-16s %8s  %-24s %s\n' "${i}" "${path}" "${size}" "${model}" "${tran}"
    i=$((i + 1))
  done
  echo "------------------------------------------------------------"
}

stripe_disks() {
  local n="${#active_parts[@]}" copies
  case "${RAID_LEVEL}" in
    0) printf '%s\n' "${n}" ;;
    4|5) printf '%s\n' "$((n - 1))" ;;
    6) printf '%s\n' "$((n - 2))" ;;
    10)
      copies="${RAID_LAYOUT:1}"
      if [[ "${copies}" =~ ^[0-9]+$ ]] && (( copies > 0 && n % copies == 0 )); then
        printf '%s\n' "$((n / copies))"
      fi
      ;;
  esac
}

stop_existing_array() {
  local md_base mounted
  md_base="$(basename "${MD_DEVICE}")"
  if [[ -b "${MD_DEVICE}" ]] || grep -qE "^${md_base} :" /proc/mdstat 2>/dev/null; then
    warn "${MD_DEVICE} esiste gia"
    confirm_yes "Vuoi fermarlo e ricrearlo?"
    while IFS= read -r mounted; do
      [[ -n "${mounted}" ]] || continue
      umount "${mounted}" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET -S "${MD_DEVICE}" 2>/dev/null || true)
    umount "${MD_DEVICE}" 2>/dev/null || true
    mdadm --stop "${MD_DEVICE}" || true
  fi
}

create_array() {
  local -a cmd=(
    mdadm --create "${MD_DEVICE}"
    --name="${ARRAY_NAME}"
    --level="${RAID_LEVEL}"
    --raid-devices="${#active_parts[@]}"
    --metadata=1.2
    --run
  )
  if (( USE_CHUNK == 1 )); then
    cmd+=( --chunk="${CHUNK_KIB}" )
  fi
  if (( USE_BITMAP == 1 )); then
    cmd+=( --bitmap=internal )
  fi
  if [[ -n "${RAID_LAYOUT}" ]]; then
    cmd+=( --layout="${RAID_LAYOUT}" )
  fi
  if (( ${#spare_parts[@]} > 0 )); then
    cmd+=( --spare-devices="${#spare_parts[@]}" )
  fi
  cmd+=( "${active_parts[@]}" "${spare_parts[@]}" )
  info "Creo $(level_title). Su dischi da 7 TB la sync iniziale puo durare molte ore."
  info "Comando: ${cmd[*]}"
  "${cmd[@]}"
}

mkfs_on_array() {
  local fstype="$1" detail chunk ndata stride stripe
  case "${fstype}" in
    xfs)
      command -v mkfs.xfs >/dev/null 2>&1 || die "mkfs.xfs mancante (pacchetto xfsprogs)."
      detail="$(mdadm --detail "${MD_DEVICE}" 2>/dev/null || true)"
      chunk="$(sed -n 's/^[[:space:]]*Chunk Size[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)K.*/\1/p' <<<"${detail}" | head -1)"
      ndata="$(stripe_disks || true)"
      if [[ "${chunk}" =~ ^[0-9]+$ && "${ndata}" =~ ^[0-9]+$ ]] && (( ndata > 0 )); then
        info "mkfs.xfs allineato allo stripe (su=${chunk}k, sw=${ndata})"
        if mkfs.xfs -f -d "su=${chunk}k,sw=${ndata}" "${MD_DEVICE}"; then
          return 0
        fi
        warn "mkfs.xfs allineato fallito, riprovo senza opzioni di stripe"
      fi
      mkfs.xfs -f "${MD_DEVICE}"
      ;;
    ext4)
      command -v mkfs.ext4 >/dev/null 2>&1 || die "mkfs.ext4 mancante (pacchetto e2fsprogs)."
      detail="$(mdadm --detail "${MD_DEVICE}" 2>/dev/null || true)"
      chunk="$(sed -n 's/^[[:space:]]*Chunk Size[[:space:]]*:[[:space:]]*\([0-9][0-9]*\)K.*/\1/p' <<<"${detail}" | head -1)"
      ndata="$(stripe_disks || true)"
      if [[ "${chunk}" =~ ^[0-9]+$ && "${ndata}" =~ ^[0-9]+$ ]] && (( ndata > 0 )); then
        stride=$(( chunk * 1024 / 4 ))
        stripe=$(( stride * ndata ))
        info "mkfs.ext4 allineato allo stripe (stride=${stride}, stripe_width=${stripe})"
        mkfs.ext4 -F -E "stride=${stride},stripe_width=${stripe}" "${MD_DEVICE}"
      else
        mkfs.ext4 -F "${MD_DEVICE}"
      fi
      ;;
    *)
      die "Filesystem non supportato: ${fstype} (usa xfs o ext4)"
      ;;
  esac
}

persist_config() {
  local fstype="$1" uuid tmp scan_line md_uuid
  mkdir -p /etc/mdadm
  md_uuid="$(mdadm --detail --export "${MD_DEVICE}" | sed -n 's/^MD_UUID=//p' | head -1)"
  [[ -n "${md_uuid}" ]] || die "UUID dell'array non trovato. ${MD_DEVICE} resta montato, ma non ho aggiornato mdadm.conf."
  scan_line="$(mdadm --detail --scan | grep -F "${md_uuid}" | head -1 || true)"
  [[ -n "${scan_line}" ]] || die "mdadm --detail --scan non riporta l'array. ${MD_DEVICE} resta montato, ma non ho aggiornato mdadm.conf."

  tmp="$(mktemp)"
  if [[ -f /etc/mdadm/mdadm.conf ]]; then
    awk -v dev="${MD_DEVICE}" -v name="${ARRAY_NAME}" -v uuid="${md_uuid}" '
      index($0, uuid) { next }
      $1 == "ARRAY" && $2 == dev { next }
      {
        n = index($0, "name=")
        if (n > 0) {
          rest = substr($0, n + 5)
          sub(/[[:space:]].*/, "", rest)
          short = rest
          sub(/^.*[:\/]/, "", short)
          if (short == name) next
        }
        print
      }
    ' /etc/mdadm/mdadm.conf > "${tmp}"
  fi
  printf '%s\n' "${scan_line}" >> "${tmp}"
  mv "${tmp}" /etc/mdadm/mdadm.conf
  ok "Aggiornato /etc/mdadm/mdadm.conf"

  if command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u || warn "update-initramfs non riuscito. L'array e gia montato; al riavvio controlla che si riassembli."
  else
    warn "update-initramfs non e installato. L'array si assembla comunque tramite udev/systemd se mdadm.conf e corretto."
  fi

  uuid="$(blkid -s UUID -o value "${MD_DEVICE}" || true)"
  [[ -n "${uuid}" ]] || die "UUID del filesystem non trovato per ${MD_DEVICE}. Non ho modificato fstab."
  tmp="$(mktemp)"
  if [[ -f /etc/fstab ]]; then
    awk -v mp="${MOUNT_POINT}" '($1 ~ /^#/) || ($2 != mp) { print }' /etc/fstab > "${tmp}"
  fi
  printf 'UUID=%s  %s  %s  defaults,nofail,x-systemd.device-timeout=120  0  2\n' \
    "${uuid}" "${MOUNT_POINT}" "${fstype}" >> "${tmp}"
  mv "${tmp}" /etc/fstab
  ok "fstab aggiornato per ${MOUNT_POINT} (UUID=${uuid})"
}

main() {
  [[ "${CHUNK_KIB}" =~ ^[0-9]+$ ]] || die "CHUNK_KIB non valido: ${CHUNK_KIB}"
  (( CHUNK_KIB >= 4 && CHUNK_KIB <= 65536 )) || die "CHUNK_KIB deve essere tra 4 e 65536."

  check_arch
  echo
  echo "=============================================="
  echo "  Setup RAID interattivo (Ubuntu 24.04 offline)"
  echo "  Kit: ${KIT_DIR}"
  echo "=============================================="
  echo
  info "Invio accetta il valore tra parentesi. Per cancellare i dischi servira YES maiuscolo."
  info "Scenario previsto del kit: 7 dischi, RAID6, 5 attivi + 2 spare. Puoi cambiare livello e numeri."

  resolve_install_set
  if [[ "${RAID6_PLAN_ONLY:-}" == "1" ]]; then
    if [[ ${#INSTALL_DEBS[@]} -eq 0 ]]; then
      ok "Piano: nessun pacchetto da installare."
    else
      info "Piano installazione (${#INSTALL_DEBS[@]} pacchetti, nessun disco verra toccato):"
      local deb
      for deb in "${INSTALL_DEBS[@]}"; do
        echo "  - $(dpkg-deb -f "${deb}" Package) $(dpkg-deb -f "${deb}" Version)"
      done
    fi
    exit 0
  fi

  need_root
  apply_install

  local -a rows=()
  mapfile -t rows < <(list_candidate_disks)
  if [[ ${#rows[@]} -eq 0 ]]; then
    die "Nessun disco candidato (esclusi sistema, mount e swap). Controlla: lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL"
  fi
  print_disk_menu "${rows[@]}"
  if grep -qE '^md[0-9]+ :' /proc/mdstat 2>/dev/null; then
    info "Un array e gia attivo: i suoi dischi non compaiono finche sono montati."
    info "Per riusarli: umount <punto di mount> && mdadm --stop /dev/md0"
  fi

  local n_total="${#rows[@]}"
  choose_level "${n_total}"
  if [[ "${RAID_LEVEL}" == "10" ]]; then
    choose_layout "${n_total}"
  fi

  local def_active def_spare room n_active n_spare n_need
  if [[ "${RAID_LEVEL}" == "6" && "${n_total}" -ge 7 ]]; then
    def_active=5
  else
    def_active="${n_total}"
  fi
  if (( def_active < MIN_ACTIVE )); then
    def_active="${MIN_ACTIVE}"
  fi

  echo
  info "Livello scelto: $(level_title). Minimo attivi: ${MIN_ACTIVE}. Dischi visibili: ${n_total}."
  while true; do
    n_active="$(prompt_uint "Quanti dischi ATTIVI?" "${def_active}" "${MIN_ACTIVE}")" || exit 1
    if (( ALLOW_SPARE == 1 )); then
      if [[ "${RAID_LEVEL}" == "6" && "${n_active}" -eq 5 && "${n_total}" -ge 7 ]]; then
        def_spare=2
      else
        def_spare=0
      fi
      room=$(( n_total - n_active ))
      if (( def_spare > room )); then
        def_spare="${room}"
      fi
      if (( room < 0 )); then
        echo "Gli attivi (${n_active}) sono piu dei dischi visibili (${n_total})." >&2
        continue
      fi
      n_spare="$(prompt_uint "Quanti dischi SPARE (hot spare)?" "${def_spare}" 0)" || exit 1
    else
      n_spare=0
      info "Questo livello non usa hot spare: un disco in piu non sostituisce un disco rotto."
    fi
    n_need=$(( n_active + n_spare ))
    if (( n_active > n_total || n_need > n_total )); then
      echo "Servono ${n_need} dischi e ne vedo ${n_total}." >&2
      continue
    fi
    break
  done

  echo
  print_disk_menu "${rows[@]}"
  info "Seleziona i ${n_active} dischi ATTIVI"
  ACTIVE=()
  pick_indices "${n_active}" "ATTIVI" ACTIVE "${rows[@]}"
  SPARES=()
  if (( n_spare > 0 )); then
    echo
    info "Seleziona i ${n_spare} dischi SPARE, diversi dagli attivi"
    pick_indices "${n_spare}" "SPARE" SPARES "${rows[@]}"
  fi

  local a s def_mount def_name
  for a in "${ACTIVE[@]}"; do
    for s in "${SPARES[@]+"${SPARES[@]}"}"; do
      [[ "${a}" == "${s}" ]] && die "Disco selezionato sia come attivo sia come spare: ${a}"
    done
    is_system_disk "${a}" && die "Rifiuto di cancellare il disco di sistema ${a}"
  done
  for s in "${SPARES[@]+"${SPARES[@]}"}"; do
    is_system_disk "${s}" && die "Rifiuto di cancellare il disco di sistema ${s}"
  done

  def_mount="$(default_mount_for_level)"
  while true; do
    MOUNT_POINT="$(prompt_text "Punto di mount" "${def_mount}")" || exit 1
    if mount_point_ok "${MOUNT_POINT}"; then
      break
    fi
    echo "Mount non accettato. Usa un percorso dati, per esempio /mnt/raid6." >&2
  done
  def_name="$(default_name_for_level)"
  while true; do
    ARRAY_NAME="$(prompt_text "Nome array (massimo 32 caratteri)" "${def_name}")" || exit 1
    if array_name_ok "${ARRAY_NAME}"; then
      break
    fi
    echo "Nome non valido. Lettere, numeri, punto, trattino e underscore." >&2
  done

  echo
  echo "Riepilogo:"
  echo "  Device:    ${MD_DEVICE}"
  echo "  Nome:      ${ARRAY_NAME}"
  echo "  Livello:   $(level_title)"
  if (( USE_CHUNK == 1 )); then
    echo "  Chunk:     ${CHUNK_KIB} KiB"
  else
    echo "  Chunk:     non usato da questo livello"
  fi
  if (( USE_BITMAP == 1 )); then
    echo "  Bitmap:    interna"
  else
    echo "  Bitmap:    no (questo livello non la supporta)"
  fi
  echo "  Metadata:  1.2"
  echo "  Attivi (${#ACTIVE[@]}):"
  for a in "${ACTIVE[@]}"; do
    printf '    %s\n' "$(describe_disk "${a}")"
  done
  echo "  Spare (${#SPARES[@]}):"
  if (( ${#SPARES[@]} == 0 )); then
    echo "    (nessuno)"
  else
    for s in "${SPARES[@]}"; do
      printf '    %s\n' "$(describe_disk "${s}")"
    done
  fi
  echo "  Mount:     ${MOUNT_POINT}"
  case "${RAID_LEVEL}" in
    0|linear)
      warn "Questo livello NON sopravvive al guasto di un disco. I dati si perdono."
      ;;
    4)
      warn "RAID4 tiene la parita su un solo disco, che diventa il collo di bottiglia. RAID5 di solito e la scelta migliore."
      ;;
  esac
  warn "TUTTI i dati sui dischi elencati verranno DISTRUTTI."
  warn_small_disks "${ACTIVE[@]}" ${SPARES[@]+"${SPARES[@]}"}
  confirm_yes "Procedo con partizionamento e creazione dell'array?"

  stop_existing_array

  active_parts=()
  spare_parts=()
  local d p i
  for d in "${ACTIVE[@]}"; do
    p="$(wipe_and_partition "${d}")" || exit 1
    [[ -b "${p}" ]] || die "Partizione non valida per ${d}: '${p}'"
    active_parts+=( "${p}" )
    ok "Attivo: ${d} -> ${p}"
  done
  for d in "${SPARES[@]+"${SPARES[@]}"}"; do
    p="$(wipe_and_partition "${d}")" || exit 1
    [[ -b "${p}" ]] || die "Partizione non valida per ${d}: '${p}'"
    spare_parts+=( "${p}" )
    ok "Spare: ${d} -> ${p}"
  done

  create_array
  for (( i=1; i<=40; i++ )); do
    [[ -b "${MD_DEVICE}" ]] && break
    sleep 0.25
  done
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=10 >/dev/null 2>&1 || true
  fi
  [[ -b "${MD_DEVICE}" ]] || die "Array non creato: manca ${MD_DEVICE}"
  ok "Array creato"
  cat /proc/mdstat >&2 || true
  mdadm --detail "${MD_DEVICE}" >&2 || true

  echo
  local fstype tmp
  while true; do
    read -r -p "Filesystem? [xfs/ext4] (default xfs): " tmp || die "Input interrotto."
    tmp="${tmp//[[:space:]]/}"
    fstype="${tmp:-xfs}"
    case "${fstype}" in
      xfs|ext4) break ;;
      *) echo "Scrivi xfs oppure ext4." >&2 ;;
    esac
  done
  mkfs_on_array "${fstype}"

  if findmnt -rn "${MOUNT_POINT}" >/dev/null 2>&1; then
    die "${MOUNT_POINT} e gia montato. Non ci monto l'array sopra."
  fi
  mkdir -p "${MOUNT_POINT}"
  mount "${MD_DEVICE}" "${MOUNT_POINT}"
  ok "Montato su ${MOUNT_POINT}"
  persist_config "${fstype}"
  sync

  echo
  echo "=============================================="
  ok "FATTO"
  echo "  Livello:   $(level_title)" >&2
  echo "  Device:    ${MD_DEVICE}" >&2
  echo "  Mount:     ${MOUNT_POINT}" >&2
  echo "  Stato:     cat /proc/mdstat" >&2
  echo "  Dettaglio: mdadm --detail ${MD_DEVICE}" >&2
  echo "La ricostruzione/resync puo continuare in background." >&2
  echo "=============================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
