# StorageBench

A single Bash script for benchmarking Linux disks, VPS storage and mounted filesystems with [fio](https://fio.readthedocs.io/en/latest/fio_doc.html). Measures sequential throughput, 4K random IOPS, mixed reads/writes and fsync latency. Saves readable TSV summaries and full JSON results.

[![Check and benchmark](https://github.com/Lostepic/storagebench/actions/workflows/ci.yml/badge.svg)](https://github.com/Lostepic/storagebench/actions/workflows/ci.yml)

## Quick start

Install dependencies on Debian/Ubuntu:

```bash
sudo apt-get update && sudo apt-get install -y fio jq
```

One-line runner (downloads completely before executing; needs Bash and curl):

```bash
bash -c 'set -e; f=$(mktemp); trap '\''rm -f -- "$f"'\'' EXIT; curl -fsSL https://raw.githubusercontent.com/Lostepic/storagebench/main/storagebench.sh -o "$f"; bash "$f" --profile quick'
```

This opens an **interactive target picker**, then asks for confirmation. Choose the current directory, OS/root filesystem, another mounted filesystem, a custom directory, or a block device. File tests do not need root when the chosen directory is writable; testing `/` or a raw device usually requires running the downloaded script with `sudo`. Prompts use `/dev/tty`, so they also work when the script is downloaded through a pipe. The command executes the current `main` branch; review the script first or substitute a reviewed commit SHA for `main` to pin a specific version.

To inspect before running:

```bash
curl -fsSLO https://raw.githubusercontent.com/Lostepic/storagebench/main/storagebench.sh
less storagebench.sh
bash storagebench.sh --profile quick
```

## Usage

```bash
# Interactive target picker, including OS and unmounted disks
sudo bash storagebench.sh

# Benchmark an existing mounted filesystem
bash storagebench.sh --directory /mnt/data --profile standard

# Unattended run with a chosen results directory
bash storagebench.sh --directory /mnt/data --output "$HOME/bench-results" --yes

# Read-only device tests; substitute the correct device from lsblk
sudo bash storagebench.sh --read-only /dev/nvme0n1 --profile quick

# Explicitly install Debian/Ubuntu dependencies and run
sudo bash storagebench.sh --install-deps --directory /mnt/data

bash storagebench.sh --help

# Reformat an existing run (also works with v2.0/v2.1 results)
bash storagebench.sh --show-results /root/storagebench-results/RUN_DIRECTORY

# Plain output without terminal colour
bash storagebench.sh --directory /mnt/data --no-color
```

| Target | How it is tested |
| --- | --- |
| Disk used by the running OS | Choose OS/root or a writable directory on that filesystem; read/write tests use a temporary file |
| Other mounted filesystem | Choose its mount from the menu or use `--directory` |
| Unmounted disk or partition | Choose its device from the menu or use `--read-only`; raw reads require no mount |
| Blank disk with no filesystem | Read-only device tests work without formatting |
| Existing unmounted filesystem needing write tests | Mount it yourself, then select its mounted directory |

Device entries always run read-only, even if the device is currently mounted. Filesystem entries run read/write tests. The picker never guesses which physical disk contains the OS, so LVM/RAID-backed root filesystems can be tested through `/` as well. Mounted filesystem entries show the source and filesystem type; device entries show size and type. A final confirmation shows the selected target and workload.

For unattended use, specify exactly one of `--directory` or `--read-only` and add `--yes`. Bare `--yes` is rejected to prevent accidentally testing an unintended filesystem. Without a controlling terminal, the script requires these explicit options.

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

- `summary.txt`: readable table with automatically scaled units, also shown in the terminal.
- `summary.tsv`: throughput in MiB/s, IOPS, mean completion latency in microseconds, and mean fsync latency (zero when not applicable).
- `results.json`: metadata and all fio test reports, including fio latency percentiles.
- `metadata.json`: version, kernel, profile, target and timestamp.
- Individual test `.json` reports and `.log` diagnostics.

A nonzero exit indicates failure or interruption; partial logs remain. Results stay local and are never uploaded automatically. Metadata includes the target path; review it before sharing.

The terminal shows a numbered stage for each workload and total elapsed time. Throughput scales from B/s through KiB/s, MiB/s, GiB/s and TiB/s; IOPS uses `k`/`M`; latency scales from ns through us, ms and seconds. These are **bytes per second**, not Mbps (megabits per second). Values are rounded for display only: JSON and TSV retain the original precision. Fsync shows `-` for workloads where it is not measured. Colour is automatic on supported terminals and disabled for redirected output, `--no-color`, or the `NO_COLOR` environment variable.

For example, a result of `1600 MiB/s` appears as `1.56 GiB/s`, and `3963.23 us` appears as `3.96 ms`. Use `--show-results PATH` to display older saved TSV results in the new format without running fio or modifying the saved files.

## Scope and precautions

Filesystem mode only writes `workload.bin` inside its unique `.storagebench-*` directory and removes it on normal exit, errors, Ctrl+C and termination. An uncatchable kill or power loss can leave that directory behind. Remove it manually only after confirming no benchmark is still using it. Paths containing colons, backslashes or newlines are rejected because fio treats some characters specially.

There is no partitioning, formatting, mounting, raw-write or destructive mode. Read-only device tests use fio's `--readonly` guard and disable file creation. Results are still written to the output filesystem, even in read-only mode. Target selection uses the interactive picker or explicit command-line options; no root-disk inference is required.

Benchmarks consume I/O bandwidth and filesystem tests write data. Run during a maintenance window on busy systems. Free-space checks cannot reserve space against concurrent writers or account for all quotas/thin-provisioning limits. Direct I/O bypasses the usual page cache where supported, but controller caches, virtualization, compression and storage tiers still influence results. These are workload measurements, not hardware health checks or full-device steady-state endurance tests.

## Changes from the original script

Version 2 replaces the destructive workflow with filesystem and raw read-only modes. It removes automatic package installation, cached `dd`/`hdparm` measurements, and formatting commands. It adds explicit options, opt-in dependency installation, machine-readable reporting, initialized read workloads and reliable cleanup. Version 2.1 adds interactive target discovery, OS filesystem selection, unmounted device selection and terminal-based prompts. This avoids reliance on single-disk root detection, which does not cover every LVM/RAID layout.

## Development

```bash
bash -n storagebench.sh
shellcheck storagebench.sh tests/*.sh
bash tests/cli.sh
```

CI runs these checks and a real quick-profile filesystem benchmark on an Ubuntu runner. It checks cleanup, fio results, interactive prompts, OS selection/cancellation and a read-only benchmark against a disposable loop device. It never benchmarks a host's physical raw disk. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE).
