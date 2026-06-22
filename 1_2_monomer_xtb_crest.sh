#!/bin/bash
# ============================================================
# Quercetin — CID 5280343, C15H10O7, ~32 atoms
# Flavonoid polyphenol
# In ethanol
# Run: sbatch quercetin_cluster.sh
# Estimated time: ~2-6 часов на 60 ядрах
# ============================================================

#SBATCH --job-name=quercetin
#SBATCH --output=quercetin_%j.out
#SBATCH --error=quercetin_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=20
#SBATCH --mem=120G
#SBATCH --time=20-00:00:00
#SBATCH --partition=general

NCPU=20
SOLVENT="ethanol"
WORKDIR="$HOME/compchem/ethanol"
MONOMER="quercetin"
CID="5280343"

source ~/miniforge3/etc/profile.d/conda.sh
conda activate compchem

export OMP_NUM_THREADS=$NCPU
export OMP_STACKSIZE=4G
export OPENBLAS_NUM_THREADS=1
ulimit -s unlimited

echo "=========================================="
echo " $MONOMER (CID $CID)"
echo " C15H10O7, ~32 atoms"
echo " Ядра: $NCPU | Хост: $(hostname)"
echo " Старт: $(date)"
echo "=========================================="

command -v xtb >/dev/null 2>&1 || { echo "ОШИБКА: xtb не найден!"; exit 1; }
command -v crest >/dev/null 2>&1 || { echo "ОШИБКА: crest не найден!"; exit 1; }

mkdir -p "$WORKDIR/monomers"
mkdir -p "$WORKDIR/crest_monomers/$MONOMER"
mkdir -p "$WORKDIR/results"

# ============================================================
# ЭТАП 1: Генерация 3D через RDKit
# ============================================================
echo ""
echo ">>> ЭТАП 1: Генерация 3D-структуры..."

cd "$WORKDIR/monomers"

python3 << 'PYTHON_SCRIPT'
import urllib.request
from rdkit import Chem
from rdkit.Chem import AllChem

monomer = "quercetin"
cid = "5280343"
sdf_2d = f"{monomer}_2d.sdf"
xyz_out = f"{monomer}.xyz"

print(f"  Скачиваю 2D SDF (CID {cid})...")
url_2d = f"https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/{cid}/SDF?record_type=2d"
urllib.request.urlretrieve(url_2d, sdf_2d)

print("  Загружаю в RDKit...")
mol = None
supplier = Chem.SDMolSupplier(sdf_2d, removeHs=False)
for m in supplier:
    if m is not None:
        mol = m
        break

if mol is None:
    print("  SDF не прочитался, пробую SMILES...")
    url_smiles = f"https://pubchem.ncbi.nlm.nih.gov/rest/pug/compound/cid/{cid}/property/IsomericSMILES/TXT"
    response = urllib.request.urlopen(url_smiles)
    smiles = response.read().decode().strip()
    mol = Chem.MolFromSmiles(smiles)

mol = Chem.AddHs(mol)

print("  Генерирую 3D координаты...")
params = AllChem.ETKDGv3()
params.randomSeed = 42
params.maxIterations = 10000
result = AllChem.EmbedMolecule(mol, params)

if result == -1:
    params.useRandomCoords = True
    params.maxIterations = 20000
    result = AllChem.EmbedMolecule(mol, params)

if result == -1:
    print("  ОШИБКА: 3D не сгенерировались!")
    exit(1)

print("  Оптимизирую (MMFF94)...")
try:
    AllChem.MMFFOptimizeMolecule(mol, maxIters=5000)
except:
    AllChem.UFFOptimizeMolecule(mol, maxIters=5000)

conf = mol.GetConformer()
natoms = mol.GetNumAtoms()
with open(xyz_out, 'w') as f:
    f.write(f"{natoms}\n")
    f.write(f"RDKit from PubChem CID {cid}\n")
    for i in range(natoms):
        atom = mol.GetAtomWithIdx(i)
        pos = conf.GetAtomPosition(i)
        f.write(f"{atom.GetSymbol():2s}  {pos.x:12.6f}  {pos.y:12.6f}  {pos.z:12.6f}\n")

print(f"  Готово: {xyz_out} — {natoms} атомов")
PYTHON_SCRIPT

NATOMS=$(head -1 "$WORKDIR/monomers/${MONOMER}.xyz")
echo "    Файл: ${MONOMER}.xyz — $NATOMS атомов"

# ============================================================
# ЭТАП 2: Оптимизация GFN2-xTB
# ============================================================
echo ""
echo ">>> ЭТАП 2: Оптимизация GFN2-xTB..."
echo "    Начало: $(date)"

cd "$WORKDIR/monomers"

xtb "${MONOMER}.xyz" --opt crude --alpb $SOLVENT --gfn 2 -P $NCPU > "${MONOMER}_crude.log" 2>&1
if [ -f "xtbopt.xyz" ]; then
    cp xtbopt.xyz "${MONOMER}_crude.xyz"
    echo "    Грубая оптимизация — ОК"
    rm -f wbo charges xtbrestart xtbtopo.mol .xtboptok gradient energy
else
    echo "    ОШИБКА грубой оптимизации!"
    tail -20 "${MONOMER}_crude.log"
    exit 1
fi

xtb "${MONOMER}_crude.xyz" --opt tight --alpb $SOLVENT --gfn 2 -P $NCPU > "${MONOMER}_opt.log" 2>&1
if [ -f "xtbopt.xyz" ]; then
    cp xtbopt.xyz "${MONOMER}_opt.xyz"
    E_OPT=$(grep "TOTAL ENERGY" "${MONOMER}_opt.log" | tail -1 | awk '{print $4}')
    echo "    Точная оптимизация — ОК. E = $E_OPT Eh"
    rm -f wbo charges xtbrestart xtbtopo.mol .xtboptok gradient energy
else
    echo "    ОШИБКА точной оптимизации!"
    tail -20 "${MONOMER}_opt.log"
    exit 1
fi

# ============================================================
# ЭТАП 3: CREST
# ============================================================
echo ""
echo ">>> ЭТАП 3: CREST конформационный поиск..."
echo "    Начало: $(date)"

cd "$WORKDIR/crest_monomers/$MONOMER"
cp "$WORKDIR/monomers/${MONOMER}_opt.xyz" .

echo "    3а: CREST/GFN-FF..."
crest "${MONOMER}_opt.xyz" --gfnff --alpb $SOLVENT -T $NCPU > crest_ff.log 2>&1

if [ -f "crest_best.xyz" ]; then
    NCONF_FF=$(grep "number of unique" crest_ff.log | tail -1 | awk '{print $NF}')
    echo "    GFN-FF: $NCONF_FF конформеров"
    cp crest_best.xyz best_ff.xyz
else
    echo "    GFN-FF не сработал"
    cp "${MONOMER}_opt.xyz" best_ff.xyz
fi

echo "    3б: CREST/GFN2-xTB..."
echo "    Начало: $(date)"
crest best_ff.xyz --gfn2 --alpb $SOLVENT -T $NCPU > crest_gfn2.log 2>&1

if [ -f "crest_best.xyz" ]; then
    cp crest_best.xyz "$WORKDIR/monomers/${MONOMER}_best.xyz"
    NCONF=$(grep "number of unique" crest_gfn2.log | tail -1 | awk '{print $NF}')
    echo "    GFN2: $NCONF конформеров"
else
    echo "    GFN2 не сработал, пробуем --xnam xtb..."
    crest best_ff.xyz --xnam xtb --gfn2 --alpb $SOLVENT -T $NCPU > crest_v2.log 2>&1
    if [ -f "crest_best.xyz" ]; then
        cp crest_best.xyz "$WORKDIR/monomers/${MONOMER}_best.xyz"
        NCONF=$(grep "number of unique" crest_v2.log | tail -1 | awk '{print $NF}')
        echo "    --xnam xtb: $NCONF конформеров"
    else
        cp best_ff.xyz "$WORKDIR/monomers/${MONOMER}_best.xyz"
        NCONF="N/A"
    fi
fi

# ============================================================
# ЭТАП 4: Одноточечный расчёт
# ============================================================
echo ""
echo ">>> ЭТАП 4: Одноточечный расчёт..."

cd "$WORKDIR/results"
cp "$WORKDIR/monomers/${MONOMER}_best.xyz" .

xtb "${MONOMER}_best.xyz" --sp --alpb $SOLVENT --gfn 2 -P $NCPU > "${MONOMER}_sp.log" 2>&1

E_FINAL=$(grep "TOTAL ENERGY" "${MONOMER}_sp.log" | awk '{print $4}')
HOMO=$(grep "HOMO-LUMO GAP" "${MONOMER}_sp.log" | awk '{print $4}')

rm -f wbo charges xtbrestart xtbtopo.mol gradient energy

echo ""
echo "=========================================="
echo " ИТОГИ: $MONOMER"
echo "=========================================="
echo " Энергия:            $E_FINAL Eh"
echo " HOMO-LUMO gap:      $HOMO eV"
echo " Конформеры (GFN-FF): ${NCONF_FF:-N/A}"
echo " Конформеры (GFN2):   ${NCONF:-N/A}"
echo " Лучший конформер:   $WORKDIR/monomers/${MONOMER}_best.xyz"
echo " Завершено: $(date)"
echo "=========================================="