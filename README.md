# xTB / CREST SLURM Workflow

A set of Bash scripts for studying non-covalent complexes on an HPC cluster managed by **SLURM**:

1. build and optimize a monomer structure, then sample conformers with CREST;
2. dock two monomers with `xtb dock --ensemble`;
3. run CREST non-covalent interaction (NCI) sampling for a selected complex.

> `3_docking.sh` and `4_crest_nci.sh` are interactive. They display the selected settings, ask for confirmation, generate a dedicated SLURM submission script, and submit it with `sbatch` when available.

## Repository contents

| File | Purpose |
|---|---|
| `1_2_monomer_xtb_crest.sh` | Retrieves a compound from PubChem, creates a 3D structure, optimizes it with xTB, and samples conformers with CREST. |
| `3_docking.sh` | Selects two prepared monomers and creates/submits an `xtb dock --ensemble` SLURM job. |
| `4_crest_nci.sh` | Selects a docked complex and creates/submits a CREST NCI SLURM job. |

## Workflow overview

```text
PubChem CID
   |
   +-- 1_2_monomer_xtb_crest.sh
   |      RDKit 3D -> xTB/GFN2 optimization -> CREST/GFN-FF -> CREST/GFN2
   |      output: crest_best.xyz
   |
   +-- 3_docking.sh
   |      xtb dock monomer1 monomer2 --ensemble
   |      output: best.xyz or crest_best.xyz for the complex
   |
   +-- 4_crest_nci.sh
          crest <complex> --nci
          output: crest_best.xyz, crest_ensemble.xyz, crest.energies
```

## Requirements

### Cluster environment

- A SLURM installation with `sbatch`, `squeue`, and `scancel` available. `sinfo` is also recommended.
- Bash 4 or newer.
- Internet access from the compute node for the monomer-preparation script, because it downloads SDF/SMILES data from PubChem.
- Sufficient CPU, memory, and wall-time limits for the systems being studied.

### Software

The compute environment must provide:

- `xtb` with support for `xtb dock`;
- `crest`;
- Python 3;
- RDKit, required only by `1_2_monomer_xtb_crest.sh`;
- Conda/Miniforge if you use `conda activate` in the scripts.

After activating your environment, check the installation:

```bash
xtb --version
crest --version
python3 -c "from rdkit import Chem; print('RDKit OK')"
```

Use compatible xTB and CREST releases. Before starting a large calculation campaign, test the workflow with a small molecule and short SLURM limits.

## Installation

Clone the repository and make the scripts executable:

```bash
git clone <YOUR_REPOSITORY_URL>
cd <YOUR_REPOSITORY_DIRECTORY>
chmod +x 1_2_monomer_xtb_crest.sh 3_docking.sh 4_crest_nci.sh
```

The docking and NCI scripts are launched as ordinary interactive programs from a login node. They create separate SLURM job files and submit them after confirmation.

## 1. Monomer preparation

`1_2_monomer_xtb_crest.sh` is a SLURM script configured for one compound at a time. Edit the user settings near the top before submission:

```bash
NCPU=20
SOLVENT="ethanol"
WORKDIR="$HOME/compchem/ethanol"
MONOMER="quercetin"
CID="5280343"
```

| Parameter | Description |
|---|---|
| `MONOMER` | A short compound identifier used in filenames and folder names. Avoid spaces and shell-special characters. |
| `CID` | PubChem Compound ID for the compound. |
| `SOLVENT` | ALPB solvent name passed directly to xTB/CREST, for example `ethanol` or `h2o`. |
| `WORKDIR` | Main working directory for the calculation. |
| `NCPU` | Number of threads. Keep it consistent with `#SBATCH --cpus-per-task`. |

Also review the SLURM directives at the beginning of the file:

```bash
#SBATCH --cpus-per-task=20
#SBATCH --mem=120G
#SBATCH --time=20-00:00:00
#SBATCH --partition=general
```

Update the Conda initialization commands to match your installation:

```bash
source ~/miniforge3/etc/profile.d/conda.sh
conda activate compchem
```

Submit the calculation:

```bash
sbatch 1_2_monomer_xtb_crest.sh
```

Monitor it with:

```bash
squeue -u "$USER"
tail -f quercetin_<JOB_ID>.out
```

### What the script does

1. Downloads a 2D SDF file from PubChem using the provided CID.
2. Generates 3D coordinates with RDKit ETKDGv3 and performs an MMFF94/UFF pre-optimization.
3. Runs coarse and refined `xTB/GFN2-xTB` geometry optimization with the selected ALPB solvent.
4. Performs CREST conformational sampling in two stages: `GFN-FF`, then `GFN2-xTB`.
5. Runs an xTB single-point calculation for the best conformer.

### Main outputs

For `WORKDIR="$HOME/compchem/ethanol"`, the expected files are:

```text
$HOME/compchem/ethanol/
├── monomers/
│   ├── quercetin.xyz
│   ├── quercetin_opt.xyz
│   └── quercetin_best.xyz
├── crest_monomers/
│   └── quercetin/
│       ├── crest_best.xyz
│       ├── crest_ensemble.xyz
│       └── crest_*.log
└── results/
    └── quercetin_sp.log
```

The important input for the next step is:

```text
<monomer-directory>/<monomer-name>/crest_best.xyz
```

`3_docking.sh` looks for monomers as subdirectories containing `crest_best.xyz`, with `best_ff.xyz` accepted as a fallback. For example:

```text
ethanol_crest_monomers/
├── quercetin/
│   └── crest_best.xyz
└── caffeine/
    └── crest_best.xyz
```

The preparation script keeps its result in `WORKDIR/crest_monomers/<MONOMER>/`. Point the ethanol directory in `3_docking.sh` to the appropriate parent folder, or collect the monomer folders in a common directory. For example:

```bash
mkdir -p "$HOME/compchem/ethanol_crest_monomers"
ln -s "$HOME/compchem/ethanol/crest_monomers/quercetin" \
      "$HOME/compchem/ethanol_crest_monomers/quercetin"
```

## 2. Monomer docking

Start the interactive docking script from a login node:

```bash
bash 3_docking.sh
```

### Interactive procedure

1. Review the saved monomer and output directories. Enter `y` to modify them; leave an input blank to retain the current value.
2. Select the solvent:
   - `1` — ethanol;
   - `2` — water, passed as `--alpb h2o`;
   - `3` — gas phase (`none`).
3. Select the method:
   - `1` — `GFN2-xTB`;
   - `2` — `GFN-FF`.
4. Select the first and second monomer. Selecting the same monomer twice creates a homodimer.
5. Review or edit the SLURM resources.
6. Confirm submission with `y`.

Default resource settings are:

```text
partition: general
nodes:     1
CPUs:      32
memory:    64G
time:      30-00:00:00
```

The script also asks for the environment `bin` directory, which is added to `PATH` in the generated job. It must contain the `xtb` executable and any needed runtime environment.

### Generated command

A docking job uses a command of the following form:

```bash
xtb dock monomer1.xyz monomer2.xyz --ensemble --gfn2 --alpb ethanol
```

For water, the script uses `--alpb h2o`. In the gas phase, no ALPB option is added.

### Docking outputs

```text
docking/
└── <solvent>_crest_monomers/
    └── <GFN2-xTB|GFN-FF>/
        └── <complex_name>/
            ├── submit.sh
            ├── slurm_<JOB_ID>.out
            └── ... xTB docking output files ...
```

Complex names are generated as follows:

- identical monomers: `<monomer>_homodimer`;
- two different monomers: `<monomer_A>_<monomer_B>_complex`, with monomer names sorted alphabetically.

The NCI script uses `best.xyz` first. If it is unavailable, it falls back to `crest_best.xyz`.

Monitor, cancel, or inspect a job using:

```bash
squeue -j <JOB_ID>
tail -f docking/<...>/slurm_<JOB_ID>.out
scancel <JOB_ID>
```

### Configuration file

After the first run, the script stores the selected directories in `.xtb_docking.conf` next to the script. This is a user-local configuration file and should normally not be committed to Git:

```gitignore
.xtb_docking.conf
.xtb_nci.conf
```

## 3. CREST NCI analysis

After the docking job has finished, run:

```bash
bash 4_crest_nci.sh
```

### Interactive procedure

1. Review or modify the docking and NCI output directories.
2. Select the **same solvent** and **same method** used for docking.
3. Choose a complex from the discovered output folders.
4. Select CREST options:
   - `--fast` for a faster calculation with fewer iterations;
   - `--ewin <kcal/mol>` to set an energy window for structure selection. Use `0` to disable this limit.
5. Choose SLURM resources and confirm submission.

The generated command has the form:

```bash
crest best_input.xyz --nci --gfn2 --alpb ethanol --ewin 6 -T 16
```

### NCI outputs

By default, NCI results are stored under:

```text
nci/
└── <solvent>_crest_monomers/
    └── <GFN2-xTB|GFN-FF>/
        └── <complex_name>/
            ├── submit_nci.sh
            ├── slurm_nci_<JOB_ID>.out
            ├── best_input.xyz
            ├── crest_best.xyz
            ├── crest_ensemble.xyz
            ├── crest_conformers.xyz
            └── crest.energies
```

| File | Description |
|---|---|
| `crest_best.xyz` | Lowest-energy complex structure found during the NCI run. |
| `crest_ensemble.xyz` | Ensemble of sampled structures. |
| `crest_conformers.xyz` | Unique conformers retained by CREST. |
| `crest.energies` | Energies of the sampled structures. |
| `slurm_nci_<JOB_ID>.out` | Full standard-output log for the SLURM job. |

## Recommended directory layout

Example for two monomers in ethanol:

```text
project/
├── 1_2_monomer_xtb_crest.sh
├── 3_docking.sh
├── 4_crest_nci.sh
├── ethanol_crest_monomers/
│   ├── quercetin/
│   │   └── crest_best.xyz
│   └── caffeine/
│       └── crest_best.xyz
├── docking/
│   └── ethanol_crest_monomers/
│       └── GFN2-xTB/
│           └── quercetin_caffeine_complex/
└── nci/
    └── ethanol_crest_monomers/
        └── GFN2-xTB/
            └── quercetin_caffeine_complex/
```

## Quick start

```bash
# 1. Prepare each monomer: set MONOMER, CID, SOLVENT, and WORKDIR.
sbatch 1_2_monomer_xtb_crest.sh

# 2. Confirm that monomer folders contain crest_best.xyz.
find "$HOME/compchem/ethanol_crest_monomers" -name crest_best.xyz

# 3. Create and submit a docking job.
bash 3_docking.sh

# 4. After docking completes, create and submit an NCI job.
bash 4_crest_nci.sh
```

## Troubleshooting

### `xtb` or `crest` is not found

For the monomer-preparation script, check your Conda activation:

```bash
source ~/miniforge3/etc/profile.d/conda.sh
conda activate compchem
command -v xtb
command -v crest
```

For the interactive scripts, provide the correct environment `bin` path, for example:

```text
$HOME/anaconda3/envs/compchem/bin
```

### No monomers are shown in `3_docking.sh`

The selected solvent directory must contain monomer subdirectories, each with `crest_best.xyz` or `best_ff.xyz`:

```text
<monomer-base-directory>/<monomer-name>/crest_best.xyz
```

Check the files with:

```bash
find <monomer-base-directory> -maxdepth 2 \( -name crest_best.xyz -o -name best_ff.xyz \)
```

### No complex is found in `4_crest_nci.sh`

Verify that this directory exists:

```text
<docking-directory>/<solvent>_crest_monomers/<method>/<complex-name>/
```

It must contain either `best.xyz` or `crest_best.xyz`.

### The job was not submitted automatically

If `sbatch` is not available on the current node, the script still writes `submit.sh` or `submit_nci.sh`. Move to a login node and submit the generated script manually:

```bash
sbatch /full/path/to/submit.sh
# or
sbatch /full/path/to/submit_nci.sh
```

### The calculation reaches memory or time limits

Increase `Memory` or `Time` in the interactive script, or modify the corresponding `#SBATCH` directives in the monomer script. Do not request more CPU threads than the cluster can allocate to the job.

## Practical notes

- Use the same solvent and method in the docking and NCI stages. This is important for a consistent computational protocol.
- `GFN-FF` is generally useful for a fast preliminary stage, whereas `GFN2-xTB` provides a more detailed treatment. Select the method according to the system, scientific objective, and available resources.
- These scripts do not replace structure validation. Check protonation state, charge, stereochemistry, final geometries, and calculation logs before drawing scientific conclusions.
- Test one monomer and one complex with conservative resource limits before launching a batch of production jobs.

## Citation and licensing

When publishing results, report the exact versions of the software used and cite xTB, CREST, RDKit, PubChem, and the underlying methods according to their official citation guidance.
