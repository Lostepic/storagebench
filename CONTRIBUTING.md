# Contributing

Open an issue with the Linux distribution, fio version, command and relevant diagnostics. Redact private paths and machine details before posting results.

Keep the default workflow file-based and the device workflow read-only. Do not add automatic formatting, wiping, mounting or raw writes. Use Bash arrays for arguments, preserve failure exit codes, and test cleanup on errors and interruption. Avoid changes that silently fall back from direct to buffered I/O.

Run the checks documented in the README. `tests/integration.sh` performs a real quick-profile filesystem benchmark in a temporary directory and needs at least 3 GiB free, Linux, fio and jq. Run it on disposable development storage. New behavior should include focused regression coverage.
