# Hash throughput

Running the benchmark:

```sh
cargo bench --bench hashing
```

The two benchmarks measure BLAKE3 and SHA-256 at range of  block sizes.

BLAKE3 has only its `std` feature enabled. SHA-256 has its `asm`
feature enabled to allow CPU SHA instructions on supported ARM64 systems.

Divan reports time per hash and byte throughput under the fastest, slowest,
median, and mean columns. Throughput is block size divided by time, shown in
scaled bytes per second (for example, MB/s or GB/s).

## Best measured throughput at 1 MiB

Results from September 9, 2026. Each value is the highest throughput measured for both hash
functions across different EC2 instance types:

| EC2 instance type | CPU | Block size | BLAKE3 constant (GB/sec) | SHA-256 constant (GB/sec) |
| --- | --- | --- | ---: | ---: |
| Dev Laptop   | Apple M4 Max  | 1 MiB | 2.635 | 2.971 |
| `c8a.xlarge` | AMD EPYC 9R45 | 1 MiB | 10.93 | 2.233 |
| `c8i.xlarge` | Intel Xeon 6975P-C | 1 MiB | 7.624 | 1.905 |
| `c8g.xlarge` | AWS Graviton4 | 1 MiB | 1.452 | 1.544 |

AWS runs used Amazon Linux 2023 and Rust 1.95.0, with one repetition per
constant-input build. The local Mac runs used shorter measurement periods,
so this table is an initial comparison, not a controlled performance study.

## Run on AWS through SSM

Requires Bash 3.2 or later, AWS CLI v2, Python 3, and a local stable Rust
installation. The script uses AWS profile `default` unless you supply `--profile`.
It reads the selected profile's region from your AWS config, unless you supply
`--region`. It does not copy AWS
credentials to an instance.

```sh
aws sso login --profile default
scripts/aws-hash-bench.sh --plan
scripts/aws-hash-bench.sh
```

To use another AWS CLI profile:

```sh
aws sso login --profile my-profile
scripts/aws-hash-bench.sh --profile my-profile --plan
scripts/aws-hash-bench.sh --profile my-profile
```

The default test machines are:

| Instance | Processor | Builds |
| --- | --- | --- |
| `c8i.xlarge` | Intel Xeon 6 | Generic, native, native without BLAKE3 AVX-512 |
| `c8a.xlarge` | AMD EPYC 9005 | Generic, native, native without BLAKE3 AVX-512 |
| `c8g.xlarge` | AWS Graviton4 | Generic, native |

One-time Spot instances run one at a time. If capacity is unavailable, the
script tries other suitable default subnets for the same CPU type. With
`--subnet-id`, it uses only that subnet. It does not fall back to
On-Demand or change the CPU type. To select
On-Demand or run one machine with fewer repetitions:

```sh
scripts/aws-hash-bench.sh --on-demand
scripts/aws-hash-bench.sh --types c8g.xlarge --repeats 1
```

Each instance uses Amazon Linux 2023 with SSM Agent. It installs the compiler
tools and the exact local `rustc` release; use `--rust-toolchain 1.95.0` to set
that release explicitly. The script sends the local `Cargo.toml`, `Cargo.lock`,
`src`, and `benches`, including uncommitted edits. Builds use `--locked`.
It runs the constant-input benchmark three times per build and binds each
benchmark process to one logical CPU. `native` uses
`-C target-cpu=native`; the x86 comparison also enables `blake3/no_avx512`.
An unused sibling hardware thread can still affect cloud results. These runs
do not measure branch misses or guarantee an isolated physical host.

Results go to `results/<run-id>/`, which Git ignores. Each instance has a
`results.tar.gz` archive with benchmark output, setup/build logs, CPU details,
compiler versions, and source checksums. Transfer chunks stay below the SSM
output limit, and SHA-256 checksums verify both transfers. Extract an archive:

```sh
tar -xzf results/<run-id>/c8g.xlarge/results.tar.gz -C /tmp
```

By default, the script creates a temporary IAM role and instance profile with
`AmazonSSMManagedInstanceCore`. The caller needs EC2, SSM Run Command, public SSM
parameter read, and IAM creation/removal permissions, including `iam:PassRole`.
To use an existing EC2 instance profile instead:

```sh
scripts/aws-hash-bench.sh --instance-profile YOUR_SSM_INSTANCE_PROFILE
```

The existing profile must trust EC2 and grant the SSM core permissions. The
caller needs `iam:GetInstanceProfile` and `iam:PassRole` for it. The script does
not modify or delete that profile. `--plan` checks resource availability but
does not prove launch/IAM permissions or Spot capacity.

The script terminates instances and removes its security group and temporary
IAM resources on exit, including on errors or Ctrl-C. Instances also get a
two-hour shutdown timer with EC2 shutdown behavior set to terminate. If the
controller is killed or loses AWS access, use `resources.txt` and the
`HashBenchRun` tag to find any resources that remain. The timer cannot remove
IAM roles or security groups. A Spot interruption can prevent result retrieval;
rerun the failed type if needed. EC2, EBS, and public IPv4 usage incur AWS charges.

Run `scripts/aws-hash-bench.sh --help` for all options.
