#!/usr/bin/env bash
# Called by SSM as root on a temporary Amazon Linux 2023 instance.
set -euo pipefail
TOOLCHAIN=${1:?Exact Rust release required}
REPEATS=${2:?Repeat count required}
mkdir -p results
date -u > results/started.txt
uname -a > results/uname.txt
lscpu > results/lscpu.txt
cat /proc/cpuinfo > results/cpuinfo.txt
cat /etc/os-release > results/os-release.txt
cp Cargo.toml Cargo.lock results/
sha256sum Cargo.toml Cargo.lock benches/*.rs > results/source-sha256.txt
dnf install -y gcc gcc-c++ make perl python3 util-linux tar gzip
curl --proto '=https' --tlsv1.2 -fsS https://sh.rustup.rs -o rustup-init.sh
# Use an explicit path rather than loading shell startup files under SSM.
export CARGO_HOME="$PWD/.cargo" RUSTUP_HOME="$PWD/.rustup"
export PATH="$CARGO_HOME/bin:$PATH"
bash rustup-init.sh -y --profile minimal --default-toolchain "$TOOLCHAIN" --no-modify-path
rustc -Vv > results/rustc.txt
cargo -V > results/cargo.txt
gcc --version > results/gcc.txt
env | sort | grep -E '^(CARGO|RUST|LANG|LC_)' > results/build-env.txt || true

# Use one logical CPU. The benchmark remains single-threaded; builds can use
# the other cores. Record the selection and CPU flags for later comparison.
CPU=$(python3 -c 'import os; print(min(os.sched_getaffinity(0)))')
echo "$CPU" > results/cpu-affinity.txt
variants=(generic native)
if [[ $(uname -m) == x86_64 ]]; then variants+=(native-no-avx512); fi
for variant in "${variants[@]}"; do
    features=()
    export RUSTFLAGS=""
    if [[ $variant != generic ]]; then export RUSTFLAGS='-C target-cpu=native'; fi
    if [[ $variant == native-no-avx512 ]]; then features=(--features blake3/no_avx512); fi
    export CARGO_TARGET_DIR="$PWD/target/$variant"
    printf 'RUSTFLAGS=%s\nCargo options: %s\nCPU=%s\n' "$RUSTFLAGS" "${features[*]}" "$CPU" > "results/options-$variant.txt"
    cargo bench --locked --bench hashing "${features[@]}" --no-run > "results/build-$variant.txt" 2>&1
    # Discard one warmup. Keep compile work outside all measured runs.
    taskset -c "$CPU" cargo bench --locked --bench hashing "${features[@]}" -- --test > /dev/null 2>&1
    for ((repeat=1; repeat<=REPEATS; repeat++)); do
        echo "$(date -u +%FT%TZ) $variant constant repeat=$repeat"
        taskset -c "$CPU" cargo bench --locked --bench hashing "${features[@]}" -- \
            --color never --sample-count 100 --min-time 0.2 --max-time 0.5 \
            > "results/$variant-constant-$repeat.txt" 2>&1
    done
done
date -u > results/finished.txt
