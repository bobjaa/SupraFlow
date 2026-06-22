#!/usr/bin/env bash

# ============================================================
#  XTB Docking Script — SLURM version
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
#  КОНФИГ-ФАЙЛ (сохранение путей между запусками)
# ============================================================
CONFIG_FILE="$SCRIPT_DIR/.xtb_docking.conf"

# Значения по умолчанию (используются только если конфига нет)
DEFAULT_DIR_ETHANOL="$SCRIPT_DIR/ethanol_crest_monomers"
DEFAULT_DIR_WATER="$SCRIPT_DIR/water_crest_monomers"
DEFAULT_DIR_NONE="$SCRIPT_DIR/none_crest_monomers"
DEFAULT_DIR_OUTPUT="$SCRIPT_DIR/docking"

# Загрузка сохранённых путей из конфига
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        # Если переменные из конфига пустые — подставляем дефолты
        DIR_ETHANOL="${SAVED_DIR_ETHANOL:-$DEFAULT_DIR_ETHANOL}"
        DIR_WATER="${SAVED_DIR_WATER:-$DEFAULT_DIR_WATER}"
        DIR_NONE="${SAVED_DIR_NONE:-$DEFAULT_DIR_NONE}"
        DIR_OUTPUT="${SAVED_DIR_OUTPUT:-$DEFAULT_DIR_OUTPUT}"
    else
        DIR_ETHANOL="$DEFAULT_DIR_ETHANOL"
        DIR_WATER="$DEFAULT_DIR_WATER"
        DIR_NONE="$DEFAULT_DIR_NONE"
        DIR_OUTPUT="$DEFAULT_DIR_OUTPUT"
    fi
}

# Сохранение текущих путей в конфиг
save_config() {
    cat > "$CONFIG_FILE" << CONF
# XTB Docking — сохранённые пути
# Файл обновляется автоматически при каждом запуске скрипта
# Последнее сохранение: $(date)
SAVED_DIR_ETHANOL="$DIR_ETHANOL"
SAVED_DIR_WATER="$DIR_WATER"
SAVED_DIR_NONE="$DIR_NONE"
SAVED_DIR_OUTPUT="$DIR_OUTPUT"
CONF
}

load_config

# ============================================================
#  SLURM — ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ
# ============================================================
DEFAULT_PARTITION="general"
DEFAULT_NODES="1"
DEFAULT_CPUS="32"
DEFAULT_MEM="64G"
DEFAULT_TIME="30-00:00:00"
DEFAULT_ENV="$HOME/anaconda3/envs/compchem/bin"

prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result
    read -rp "$prompt [$default]: " result
    echo "${result:-$default}"
}

# ── 1. Папки ────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║        XTB DOCKING  —  SLURM            ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Показываем источник путей
if [ -f "$CONFIG_FILE" ]; then
    echo "💾 Пути загружены из: $CONFIG_FILE"
else
    echo "ℹ️  Конфиг не найден — используются пути по умолчанию."
fi

echo ""
echo "Текущие папки мономеров:"
printf "  ethanol : %s\n" "$DIR_ETHANOL"
printf "  water   : %s\n" "$DIR_WATER"
printf "  none    : %s\n" "$DIR_NONE"
echo ""
echo "Папка для результатов расчётов:"
printf "  output  : %s\n" "$DIR_OUTPUT"
echo ""
read -rp "Изменить пути к папкам? [y/N]: " change_dirs

if [[ "$change_dirs" =~ ^[Yy]$ ]]; then
    echo "Оставь пустым чтобы не менять."
    read -rp "Папка для ethanol [$DIR_ETHANOL]: " input
    [ -n "$input" ] && DIR_ETHANOL="$input"
    read -rp "Папка для water   [$DIR_WATER]: " input
    [ -n "$input" ] && DIR_WATER="$input"
    read -rp "Папка для none    [$DIR_NONE]: " input
    [ -n "$input" ] && DIR_NONE="$input"
    read -rp "Папка для результатов [$DIR_OUTPUT]: " input
    [ -n "$input" ] && DIR_OUTPUT="$input"
fi

# Сохраняем пути (даже если не менялись — обновляет дату в комментарии)
save_config
echo "💾 Пути сохранены в: $CONFIG_FILE"

# ── 2. Растворитель ─────────────────────────────────────────
echo ""
echo "Выберите растворитель:"
echo "  1) ethanol"
echo "  2) water"
echo "  3) none (газовая фаза)"
read -rp "Введите номер [1-3]: " solvent_choice

case $solvent_choice in
    1)
        SOLVENT_NAME="ethanol"
        SOLVENT_DIR="ethanol_crest_monomers"
        MONOMER_BASE_DIR="$DIR_ETHANOL"
        ALPB_FLAG="--alpb ethanol"
        ;;
    2)
        SOLVENT_NAME="water"
        SOLVENT_DIR="water_crest_monomers"
        MONOMER_BASE_DIR="$DIR_WATER"
        ALPB_FLAG="--alpb h2o"
        ;;
    3)
        SOLVENT_NAME="none (газовая фаза)"
        SOLVENT_DIR="none_crest_monomers"
        MONOMER_BASE_DIR="$DIR_NONE"
        ALPB_FLAG=""
        ;;
    *)
        echo "❌ Неверный выбор. Выход."
        exit 1
        ;;
esac

if [ ! -d "$MONOMER_BASE_DIR" ]; then
    echo "❌ Папка не найдена: $MONOMER_BASE_DIR"
    exit 1
fi

# ── 3. Метод ────────────────────────────────────────────────
echo ""
echo "Выберите метод расчёта:"
echo "  1) GFN2-xTB"
echo "  2) GFN-FF"
read -rp "Введите номер [1-2]: " method_choice

case $method_choice in
    1)
        METHOD_FLAG="--gfn2"
        METHOD_NAME="GFN2-xTB"
        ;;
    2)
        METHOD_FLAG="--gff"
        METHOD_NAME="GFN-FF"
        ;;
    *)
        echo "❌ Неверный выбор. Выход."
        exit 1
        ;;
esac

# ── 4. Список мономеров ─────────────────────────────────────
echo ""
echo "Доступные мономеры для растворителя [$SOLVENT_NAME]:"
echo "  (из папки: $MONOMER_BASE_DIR)"
echo ""

MONOMER_DIRS=()
while IFS= read -r d; do
    MONOMER_DIRS+=("$d")
done < <(find "$MONOMER_BASE_DIR" -maxdepth 1 -mindepth 1 -type d ! -name "results" | sort)

if [ ${#MONOMER_DIRS[@]} -eq 0 ]; then
    echo "❌ Нет папок мономеров в $MONOMER_BASE_DIR"
    exit 1
fi

declare -A MONOMER_MAP
declare -A MONOMER_FILE_MAP
IDX=1
for d in "${MONOMER_DIRS[@]}"; do
    name=$(basename "$d")
    if [ -f "$d/crest_best.xyz" ]; then
        MONOMER_MAP[$IDX]="$name"
        MONOMER_FILE_MAP[$IDX]="$d/crest_best.xyz"
        echo "  $IDX) $name"
        ((IDX++))
    elif [ -f "$d/best_ff.xyz" ]; then
        MONOMER_MAP[$IDX]="$name"
        MONOMER_FILE_MAP[$IDX]="$d/best_ff.xyz"
        echo "  $IDX) $name  ⚠️  (используется best_ff.xyz — нет crest_best.xyz)"
        ((IDX++))
    else
        echo "  ✖  $name — нет ни crest_best.xyz ни best_ff.xyz, пропускаем"
    fi
done

MONOMER_COUNT=$((IDX - 1))

if [ "$MONOMER_COUNT" -eq 0 ]; then
    echo "❌ Ни один мономер не содержит подходящего xyz файла. Выход."
    exit 1
fi

# ── 5. Выбор мономеров ──────────────────────────────────────
echo ""
echo "Выберите ПЕРВЫЙ мономер [1-$MONOMER_COUNT]:"
read -rp "Номер: " m1_idx
echo "Выберите ВТОРОЙ мономер [1-$MONOMER_COUNT] (тот же номер = гомодимер):"
read -rp "Номер: " m2_idx

if [[ -z "${MONOMER_MAP[$m1_idx]}" || -z "${MONOMER_MAP[$m2_idx]}" ]]; then
    echo "❌ Неверный выбор мономера. Выход."
    exit 1
fi

MONOMER1_NAME="${MONOMER_MAP[$m1_idx]}"
MONOMER2_NAME="${MONOMER_MAP[$m2_idx]}"
MONOMER1_FILE="${MONOMER_FILE_MAP[$m1_idx]}"
MONOMER2_FILE="${MONOMER_FILE_MAP[$m2_idx]}"

# ── 6. Имя комплекса ────────────────────────────────────────
if [ "$MONOMER1_NAME" == "$MONOMER2_NAME" ]; then
    COMPLEX_NAME="${MONOMER1_NAME}_homodimer"
else
    SORTED=$(printf "%s\n%s" "$MONOMER1_NAME" "$MONOMER2_NAME" | sort | tr '\n' '_' | sed 's/_$//')
    COMPLEX_NAME="${SORTED}_complex"
fi

OUTPUT_DIR="$DIR_OUTPUT/$SOLVENT_DIR/$METHOD_NAME/$COMPLEX_NAME"

# ── 7. SLURM параметры ──────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║         НАСТРОЙКА SLURM ЗАДАНИЯ          ║"
echo "╚══════════════════════════════════════════╝"
echo "Нажми Enter чтобы оставить значение по умолчанию."
echo ""

# Показываем доступные разделы если sinfo доступен
if command -v sinfo &>/dev/null; then
    echo "Доступные разделы (partitions):"
    sinfo -h -o "  %P  nodes=%D  state=%a  timelimit=%l" 2>/dev/null || true
    echo ""
fi

SLURM_PARTITION=$(prompt_with_default "Partition" "$DEFAULT_PARTITION")
SLURM_NODES=$(prompt_with_default "Nodes" "$DEFAULT_NODES")
SLURM_CPUS=$(prompt_with_default "CPUs per task" "$DEFAULT_CPUS")
SLURM_MEM=$(prompt_with_default "Memory (напр. 64G, 128G)" "$DEFAULT_MEM")
SLURM_TIME=$(prompt_with_default "Время (формат: D-HH:MM:SS)" "$DEFAULT_TIME")
SLURM_ENV=$(prompt_with_default "Путь к conda env/bin" "$DEFAULT_ENV")

# Короткое имя для job-name (макс 15 символов)
SHORT_SOLVENT="${SOLVENT_NAME:0:3}"
SHORT_COMPLEX="${COMPLEX_NAME:0:10}"
JOB_NAME="dock_${SHORT_SOLVENT}_${SHORT_COMPLEX}"
JOB_NAME="${JOB_NAME:0:30}"

# Имена файлов
SLURM_SCRIPT="$OUTPUT_DIR/submit.sh"
SLURM_LOG="$OUTPUT_DIR/slurm_%j.out"

# ── 8. Предпросмотр ─────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   ПРЕДПРОСМОТР ЗАДАНИЯ                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-60s ║\n" "Растворитель : $SOLVENT_NAME"
printf "║  %-60s ║\n" "Метод        : $METHOD_NAME"
printf "║  %-60s ║\n" "Мономер 1    : $MONOMER1_NAME"
printf "║  %-60s ║\n" "  файл: $MONOMER1_FILE"
printf "║  %-60s ║\n" "Мономер 2    : $MONOMER2_NAME"
printf "║  %-60s ║\n" "  файл: $MONOMER2_FILE"
printf "║  %-60s ║\n" "Комплекс     : $COMPLEX_NAME"
printf "║  %-60s ║\n" "Вывод в      : $OUTPUT_DIR"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-60s ║\n" "SLURM job    : $JOB_NAME"
printf "║  %-60s ║\n" "Partition    : $SLURM_PARTITION"
printf "║  %-60s ║\n" "Nodes        : $SLURM_NODES"
printf "║  %-60s ║\n" "CPUs         : $SLURM_CPUS"
printf "║  %-60s ║\n" "Memory       : $SLURM_MEM"
printf "║  %-60s ║\n" "Time limit   : $SLURM_TIME"
printf "║  %-60s ║\n" "Conda env    : $SLURM_ENV"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  XTB команда:                                                ║"
printf "║  xtb dock monomer1.xyz monomer2.xyz --ensemble %-13s ║\n" "$METHOD_FLAG $ALPB_FLAG"
echo "╚══════════════════════════════════════════════════════════════╝"

echo ""
read -rp "▶ Создать и отправить задание в SLURM? [y/N]: " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Отменено."
    exit 0
fi

# ── 9. Создаём папку и SLURM скрипт ────────────────────────
mkdir -p "$OUTPUT_DIR"

cat > "$SLURM_SCRIPT" << EOF
#!/bin/bash
#SBATCH --job-name=${JOB_NAME}
#SBATCH --output=${SLURM_LOG}
#SBATCH --nodes=${SLURM_NODES}
#SBATCH --cpus-per-task=${SLURM_CPUS}
#SBATCH --mem=${SLURM_MEM}
#SBATCH --time=${SLURM_TIME}
#SBATCH --partition=${SLURM_PARTITION}

export PATH="${SLURM_ENV}:\$PATH"
export OMP_NUM_THREADS=${SLURM_CPUS}

##export OMP_NUM_THREADS=1
export OMP_STACKSIZE=4G
export OPENBLAS_NUM_THREADS=1
ulimit -s unlimited
##ulimit -v unlimited

echo "========================================"
echo "  XTB DOCKING JOB"
echo "  Job ID    : \$SLURM_JOB_ID"
echo "  Node      : \$SLURMD_NODENAME"
echo "  Started   : \$(date)"
echo "  Complex   : ${COMPLEX_NAME}"
echo "  Solvent   : ${SOLVENT_NAME}"
echo "  Method    : ${METHOD_NAME}"
echo "========================================"

cd "${OUTPUT_DIR}"

xtb dock \\
    "${MONOMER1_FILE}" \\
    "${MONOMER2_FILE}" \\
    --ensemble \\
    ${METHOD_FLAG} \\
    ${ALPB_FLAG}

echo ""
echo "========================================"
echo "  Finished  : \$(date)"
echo "========================================"
EOF

chmod +x "$SLURM_SCRIPT"

echo ""
echo "📄 SLURM скрипт создан: $SLURM_SCRIPT"
echo ""

# ── 10. Отправка ────────────────────────────────────────────
if command -v sbatch &>/dev/null; then
    JOB_ID=$(sbatch "$SLURM_SCRIPT" | awk '{print $NF}')
    echo "🚀 Задание отправлено! Job ID: $JOB_ID"
    echo ""
    echo "Полезные команды:"
    echo "  squeue -j $JOB_ID          # статус задания"
    echo "  scancel $JOB_ID            # отменить"
    echo "  tail -f $OUTPUT_DIR/slurm_${JOB_ID}.out  # лог в реальном времени"
else
    echo "⚠️  sbatch не найден — скрипт создан но не отправлен."
    echo "   Отправь вручную:"
    echo "   sbatch $SLURM_SCRIPT"
fi

echo ""
echo "📁 Рабочая папка: $OUTPUT_DIR"