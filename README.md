# StorageBench

A single Bash script for benchmarking Linux disks, VPS storage and mounted filesystems with [fio](https://fio.readthedocs.io/en/latest/fio_doc.html). Measures sequential throughput, 4K random IOPS, mixed reads/writes and fsync latency. Saves readable TSV summaries and full JSON results.

**Publication pending:** replace `OWNER` below with the GitHub account hosting this repository. The download command will work after publication.

## Quick start

Install dependencies on Debian/Ubuntu:

```bash
sudo apt-get update && sudo apt-get install -y fio jq
```

One-line runner (downloads completely before executing; needs Bash and curl):

```bash
bash -c 'set -e; f=$(mktemp); trap '\''rm -f -- "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/OWNER/storagebench/main/storagebench.sh -o "$f"; bash "$f" --profile quick --yes'
```

This benchmarks the **current directory's filesystem**. It does not need root when that directory is writable. The command executes the current `main` branch; review the script first or substitute a reviewed commit SHA for `main` to pin a specific version.

To inspect before running:

```bash
curl -fsSLO https://raw.githubusercontent.com/OWNER/storagebench/main/storagebench.sh
less storagebench.sh
bash storagebench.sh --profile quick
```

## Usage

```bash
# Benchmark an existing mounted filesystem
bash storagebench.sh --directory /mnt/data --profile standard

# Unattended run with a chosen results directory
bash storagebench.sh --directory /mnt/data --output "$HOME/bench-results" --yes

# Read-only device tests; substitute the correct device from lsblk
sudo bash storagebench.sh --read-only /dev/nvme0n1 --profile quick

# Explicitly install Debian/Ubuntu dependencies and run
sudo bash storagebench.sh --install-deps --directory /mnt/data

bash storagebench.sh --help
```

Linux, Bash 4+, fio 3.x, jq, GNU coreutils and util-linux are required. Other Linux distributions can install these with their package manager. The target must support fio's direct I/O with libaio; unsupported filesystems fail with logs rather than silently switching to cached I/O. macOS and native Windows are not supported.

| Profile | File / device region | Each timed workload | Minimum free space for file tests |
| --- | --- | --- | --- |
| quick | 2 GiB | 10 seconds | 3 GiB |
| standard (default) | 4 GiB | 30 seconds | 5 GiB |
| extended | 8 GiB | 60 seconds | 9 GiB |

Sequential tests transfer the region once. Filesystem mode has six timed workloads plus sequential write/read; read-only mode has two timed workloads plus sequential read. Setup, syncing and slow storage add time. The test file size is **not** a total write limit: timed tests can rewrite the same region many times.

## What gets measured

| Test | Purpose |
| --- | --- |
| Sequential 1 MiB, QD32 | Large-file throughput |
| Random 4 KiB, QD1 | Low-concurrency I/O latency and throughput |
| Random 4 KiB, QD32 × 4 jobs | Heavy random throughput, up to 128 outstanding requests |
| Mixed 70% read / 30% write | Concurrent random read/write workload |
| Buffered 4 KiB write + fsync, QD1 | Synchronous write behavior; separate fsync latency |

Each job shares a single initialized file/region; four jobs do not require four times the listed space. Filesystem reads follow a complete sequential write using refilled buffers. Writes include a final fsync; the dedicated fsync test synchronizes each write. Device reads cover the first profile-sized region, not the entire device, and do not initialize it.

## Results

Every run creates a private, uniquely named folder in `./storagebench-results`:

- `summary.tsv`: throughput in MiB/s, IOPS, mean completion latency in microseconds, and mean fsync latency (zero when not applicable).
- `results.json`: metadata and all fio test reports, including fio latency percentiles.
- `metadata.json`: version, kernel, profile, target and timestamp.
- Individual test `.json` reports and `.log` diagnostics.

A nonzero exit indicates failure or interruption; partial logs remain. Results stay local and are never uploaded automatically. Metadata includes the target path; review it before sharing.

## Scope and precautions

Filesystem mode only writes `workload.bin` inside its unique `.storagebench-*` directory and removes it on normal exit, errors, Ctrl+C and termination. An uncatchable kill or power loss can leave that directory behind. Remove it manually only after confirming no benchmark is still using it. Paths containing colons, backslashes or newlines are rejected because fio treats some characters specially.

There is no partitioning, formatting, mounting, raw-write or destructive mode. Read-only device tests use fio's `--readonly` guard and disable file creation. Results are still written to the output filesystem, even in read-only mode. Disk selection uses an explicit device path, or an explicit/current filesystem directory; no root-disk inference is required.

Benchmarks consume I/O bandwidth and filesystem tests write data. Run during a maintenance window on busy systems. Free-space checks cannot reserve space against concurrent writers or account for all quotas/thin-provisioning limits. Direct I/O bypasses the usual page cache where supported, but controller caches, virtualization, compression and storage tiers still influence results. These are workload measurements, not hardware health checks or full-device steady-state endurance tests.

## Changes from the original script

Version 2 replaces the interactive disk-discovery/destructive workflow with filesystem and raw read-only modes. It removes automatic package installation, cached `dd`/`hdparm` measurements, and formatting commands. It adds explicit options, opt-in dependency installation, machine-readable reporting, initialized read workloads and reliable cleanup. This avoids reliance on single-disk root detection, which does not cover every LVM/RAID layout.

## Development

```bash
bash -n storagebench.sh
shellcheck storagebench.sh tests/*.sh
bash tests/cli.sh
```

CI runs these checks and a real quick-profile filesystem benchmark on an Ubuntu runner. It checks cleanup and fio results. No CI job targets a raw device. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
