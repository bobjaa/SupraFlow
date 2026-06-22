#!/usr/bin/env bash

# ============================================================
#  CREST NCI Script — SLURM version
#  Анализ некovalentных взаимодействий для результатов
#  XTB docking (xtb dock --ensemble)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
#  КОНФИГ-ФАЙЛ
# ============================================================
CONFIG_FILE="$SCRIPT_DIR/.xtb_nci.conf"

DEFAULT_DIR_DOCKING="$SCRIPT_DIR/docking"
DEFAULT_DIR_OUTPUT="$SCRIPT_DIR/nci"

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
        DIR_DOCKING="${SAVED_DIR_DOCKING:-$DEFAULT_DIR_DOCKING}"
        DIR_OUTPUT="${SAVED_DIR_OUTPUT:-$DEFAULT_DIR_OUTPUT}"
    else
        DIR_DOCKING="$DEFAULT_DIR_DOCKING"
        DIR_OUTPUT="$DEFAULT_DIR_OUTPUT"
    fi
}

save_config() {
    cat > "$CONFIG_FILE" << CONF
# XTB NCI — сохранённые пути
# Файл обновляется автоматически при каждом запуске скрипта
# Последнее сохранение: $(date)
SAVED_DIR_DOCKING="$DIR_DOCKING"
SAVED_DIR_OUTPUT="$DIR_OUTPUT"
CONF
}

load_config

# ============================================================
#  SLURM — ЗНАЧЕНИЯ ПО УМОЛЧАНИЮ
# ============================================================
DEFAULT_PARTITION="general"
DEFAULT_NODES="1"
DEFAULT_CPUS="16"
DEFAULT_MEM="32G"
DEFAULT_TIME="7-00:00:00"
DEFAULT_ENV="$HOME/anaconda3/envs/compchem/bin"

prompt_with_default() {
    local prompt="$1"
    local default="$2"
    local result
    read -rp "$prompt [$default]: " result
    echo "${result:-$default}"
}

# ── Заголовок ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       CREST NCI  —  SLURM               ║"
echo "╚══════════════════════════════════════════╝"
echo ""

if [ -f "$CONFIG_FILE" ]; then
    echo "💾 Пути загружены из: $CONFIG_FILE"
else
    echo "ℹ️  Конфиг не найден — используются пути по умолчанию."
fi

echo ""
echo "Текущие папки:"
printf "  docking : %s\n" "$DIR_DOCKING"
printf "  output  : %s\n" "$DIR_OUTPUT"
echo ""
read -rp "Изменить пути к папкам? [y/N]: " change_dirs

if [[ "$change_dirs" =~ ^[Yy]$ ]]; then
    echo "Оставь пустым чтобы не менять."
    read -rp "Папка с результатами докинга [$DIR_DOCKING]: " input
    [ -n "$input" ] && DIR_DOCKING="$input"
    read -rp "Папка для NCI результатов   [$DIR_OUTPUT]: " input
    [ -n "$input" ] && DIR_OUTPUT="$input"
fi

save_config
echo "💾 Пути сохранены в: $CONFIG_FILE"

# ── 1. Выбор растворителя / папки докинга ───────────────────
echo ""
echo "Выберите растворитель (должен совпадать с докингом):"
echo "  1) ethanol"
echo "  2) water"
echo "  3) none (газовая фаза)"
read -rp "Введите номер [1-3]: " solvent_choice

case $solvent_choice in
    1)
        SOLVENT_NAME="ethanol"
        SOLVENT_DIR="ethanol_crest_monomers"
        ALPB_FLAG="--alpb ethanol"
        ;;
    2)
        SOLVENT_NAME="water"
        SOLVENT_DIR="water_crest_monomers"
        ALPB_FLAG="--alpb h2o"
        ;;
    3)
        SOLVENT_NAME="none (газовая фаза)"
        SOLVENT_DIR="none_crest_monomers"
        ALPB_FLAG=""
        ;;
    *)
        echo "❌ Неверный выбор. Выход."
        exit 1
        ;;
esac

# ── 2. Выбор метода расчёта ─────────────────────────────────
echo ""
echo "Выберите метод расчёта (должен совпадать с докингом):"
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

# ── 3. Список доступных комплексов из докинга ───────────────
DOCKING_SOLVENT_DIR="$DIR_DOCKING/$SOLVENT_DIR/$METHOD_NAME"

echo ""
echo "Поиск комплексов в: $DOCKING_SOLVENT_DIR"
echo ""

if [ ! -d "$DOCKING_SOLVENT_DIR" ]; then
    echo "❌ Папка не найдена: $DOCKING_SOLVENT_DIR"
    echo "   Убедитесь, что докинг был выполнен с этим растворителем и методом."
    exit 1
fi

# Ищем папки комплексов, в которых есть xtbdock.xyz или crest_ensemble.xyz
COMPLEX_DIRS=()
while IFS= read -r d; do
    COMPLEX_DIRS+=("$d")
done < <(find "$DOCKING_SOLVENT_DIR" -maxdepth 1 -mindepth 1 -type d | sort)

if [ ${#COMPLEX_DIRS[@]} -eq 0 ]; then
    echo "❌ Нет папок комплексов в $DOCKING_SOLVENT_DIR"
    exit 1
fi

declare -A COMPLEX_MAP
declare -A BEST_FILE_MAP
IDX=1

echo "Доступные комплексы:"
for d in "${COMPLEX_DIRS[@]}"; do
    name=$(basename "$d")

    # Ищем best.xyz (результат докинга) в порядке приоритета
    if [ -f "$d/best.xyz" ]; then
        BEST_FILE="$d/best.xyz"
        BEST_TAG="best.xyz"
    elif [ -f "$d/crest_best.xyz" ]; then
        BEST_FILE="$d/crest_best.xyz"
        BEST_TAG="crest_best.xyz ⚠️"
    else
        echo "  ✖  $name — нет best.xyz, пропускаем"
        continue
    fi

    COMPLEX_MAP[$IDX]="$name"
    BEST_FILE_MAP[$IDX]="$BEST_FILE"
    echo "  $IDX) $name  ($BEST_TAG)"
    ((IDX++))
done

COMPLEX_COUNT=$((IDX - 1))

if [ "$COMPLEX_COUNT" -eq 0 ]; then
    echo "❌ Ни один комплекс не содержит подходящего xyz файла. Выход."
    exit 1
fi

# ── 4. Выбор комплекса ──────────────────────────────────────
echo ""
read -rp "Выберите комплекс [1-$COMPLEX_COUNT]: " c_idx

if [[ -z "${COMPLEX_MAP[$c_idx]}" ]]; then
    echo "❌ Неверный выбор. Выход."
    exit 1
fi

COMPLEX_NAME="${COMPLEX_MAP[$c_idx]}"
BEST_FILE="${BEST_FILE_MAP[$c_idx]}"

# ── 5. Параметры CREST NCI ──────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ПАРАМЕТРЫ CREST NCI               ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Быстрый режим
read -rp "Быстрый режим --fast? (меньше итераций, быстрее) [y/N]: " fast_choice
if [[ "$fast_choice" =~ ^[Yy]$ ]]; then
    FAST_FLAG="--fast"
    FAST_NAME="да"
else
    FAST_FLAG=""
    FAST_NAME="нет"
fi

# Порог энергии (окно над минимумом), kcal/mol
read -rp "Энергетическое окно для отбора структур, kcal/mol (0 = без ограничений) [0]: " EWIN
EWIN="${EWIN:-0}"

# ── 6. SLURM параметры ──────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       НАСТРОЙКА SLURM ЗАДАНИЯ           ║"
echo "╚══════════════════════════════════════════╝"
echo "Нажми Enter чтобы оставить значение по умолчанию."
echo ""

if command -v sinfo &>/dev/null; then
    echo "Доступные разделы (partitions):"
    sinfo -h -o "  %P  nodes=%D  state=%a  timelimit=%l" 2>/dev/null || true
    echo ""
fi

SLURM_PARTITION=$(prompt_with_default "Partition" "$DEFAULT_PARTITION")
SLURM_NODES=$(prompt_with_default "Nodes" "$DEFAULT_NODES")
SLURM_CPUS=$(prompt_with_default "CPUs per task" "$DEFAULT_CPUS")
SLURM_MEM=$(prompt_with_default "Memory (напр. 32G, 64G)" "$DEFAULT_MEM")
SLURM_TIME=$(prompt_with_default "Время (формат: D-HH:MM:SS)" "$DEFAULT_TIME")
SLURM_ENV=$(prompt_with_default "Путь к conda env/bin" "$DEFAULT_ENV")

# Имя задания
SHORT_COMPLEX="${COMPLEX_NAME:0:20}"
JOB_NAME="nci_${SHORT_COMPLEX}"
JOB_NAME="${JOB_NAME:0:30}"

# Папка и файлы вывода
OUTPUT_DIR="$DIR_OUTPUT/$SOLVENT_DIR/$METHOD_NAME/$COMPLEX_NAME"
SLURM_SCRIPT="$OUTPUT_DIR/submit_nci.sh"
SLURM_LOG="$OUTPUT_DIR/slurm_nci_%j.out"

# ── 7. Составляем строки команды ────────────────────────────
CREST_CMD="crest \"$BEST_FILE\" --nci"

# Быстрый режим
[ -n "$FAST_FLAG" ] && CREST_CMD="$CREST_CMD $FAST_FLAG"

# Добавляем метод
CREST_CMD="$CREST_CMD $METHOD_FLAG"

# Добавляем растворитель
[ -n "$ALPB_FLAG" ] && CREST_CMD="$CREST_CMD $ALPB_FLAG"

# Добавляем окно энергии если указано
[ "$EWIN" != "0" ] && CREST_CMD="$CREST_CMD --ewin $EWIN"

# Параллелизм
CREST_CMD="$CREST_CMD -T $SLURM_CPUS"

# ── 8. Предпросмотр ─────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   ПРЕДПРОСМОТР NCI ЗАДАНИЯ                  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-60s ║\n" "Растворитель : $SOLVENT_NAME"
printf "║  %-60s ║\n" "Метод        : $METHOD_NAME"
printf "║  %-60s ║\n" "Комплекс     : $COMPLEX_NAME"
printf "║  %-60s ║\n" "Структура    : $BEST_FILE"
printf "║  %-60s ║\n" "Быстрый режим: $FAST_NAME"
if [ "$EWIN" != "0" ]; then
    printf "║  %-60s ║\n" "Энергет. окно: $EWIN kcal/mol"
fi
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
echo "║  CREST команда:                                              ║"
printf "║  %-60s ║\n" "$CREST_CMD"
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
export OMP_STACKSIZE=4G
export OPENBLAS_NUM_THREADS=1
ulimit -s unlimited

echo "========================================"
echo "  CREST NCI JOB"
echo "  Job ID    : \$SLURM_JOB_ID"
echo "  Node      : \$SLURMD_NODENAME"
echo "  Started   : \$(date)"
echo "  Complex   : ${COMPLEX_NAME}"
echo "  Solvent   : ${SOLVENT_NAME}"
echo "  Method    : ${METHOD_NAME}"
echo "  Input     : ${BEST_FILE}"
echo "  Fast mode : ${FAST_NAME}"
echo "========================================"

cd "${OUTPUT_DIR}"

# Копируем структуру в рабочую папку
cp "${BEST_FILE}" ./best_input.xyz

# Собираем аргументы
CREST_ARGS="./best_input.xyz --nci"
[ -n "${FAST_FLAG}" ]     && CREST_ARGS="\$CREST_ARGS ${FAST_FLAG}"
CREST_ARGS="\$CREST_ARGS ${METHOD_FLAG}"
[ -n "${ALPB_FLAG}" ]     && CREST_ARGS="\$CREST_ARGS ${ALPB_FLAG}"
[ "${EWIN}" != "0" ]      && CREST_ARGS="\$CREST_ARGS --ewin ${EWIN}"
CREST_ARGS="\$CREST_ARGS -T ${SLURM_CPUS}"

# shellcheck disable=SC2086
crest \$CREST_ARGS

EXIT_CODE=\$?

echo ""
echo "========================================"
echo "  Finished  : \$(date)"
echo "  Exit code : \$EXIT_CODE"
echo "========================================"

# Краткий отчёт о результатах
if [ -f "crest_best.xyz" ]; then
    echo ""
    echo "  ✅ crest_best.xyz найден"
fi
if [ -f "crest_ensemble.xyz" ]; then
    N_STRUCTS=\$(grep -c '^\s*[0-9]' crest_ensemble.xyz 2>/dev/null || echo "?")
    echo "  ✅ crest_ensemble.xyz  (\$N_STRUCTS блоков)"
fi
if [ -f "crest_conformers.xyz" ]; then
    echo "  ✅ crest_conformers.xyz найден"
fi
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
    echo "  tail -f $OUTPUT_DIR/slurm_nci_${JOB_ID}.out  # лог в реальном времени"
    echo ""
    echo "Ожидаемые выходные файлы в $OUTPUT_DIR:"
    echo "  crest_best.xyz         — лучшая структура NCI кластера"
    echo "  crest_ensemble.xyz     — все найденные структуры"
    echo "  crest_conformers.xyz   — уникальные конформеры"
    echo "  crest.energies         — энергии структур"
else
    echo "⚠️  sbatch не найден — скрипт создан но не отправлен."
    echo "   Отправь вручную:"
    echo "   sbatch $SLURM_SCRIPT"
fi

echo ""
echo "📁 Рабочая папка: $OUTPUT_DIR"