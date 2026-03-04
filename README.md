# Ubuntu-Parity-Upgrade

**Deterministic Ubuntu package upgrades with pre-production validation.**

Parity-Upgrade is a single Bash script that implements a controlled, multi-stage workflow for upgrading Ubuntu servers. It simulates the upgrade on production first, replicates the exact post-upgrade package state onto a dev/staging server for testing, and only then applies the real upgrade to production — all pinned to the same Ubuntu snapshot timestamp for full reproducibility.

> **No software rollback is included.** Always take a VM-level snapshot before running `apply-prod`.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Compatible Distributions](#compatible-distributions)
- [Requirements](#requirements)
- [Commands](#commands)
  - [baseline](#baseline)
  - [simulate](#simulate-snapshot_id)
  - [apply-dev](#apply-dev-upgrade_bundletargz)
  - [verify-dev](#verify-dev-work_dir)
  - [apply-prod](#apply-prod-work_dir)
  - [verify-prod](#verify-prod-work_dir)
  - [resume](#resume)
- [Options](#options)
- [Pre-Flight Checks](#pre-flight-checks)
- [Platform Divergence Handling](#platform-divergence-handling)
- [Kernel Reboot Gate](#kernel-reboot-gate)
- [Progress Bar](#progress-bar)
- [Dpkg Configuration Handling](#dpkg-configuration-handling)
- [File Structure](#file-structure)
- [Usage Examples](#usage-examples)
- [Disclaimer](#disclaimer)
- [License](#license)

---

## How It Works

The script uses [Ubuntu Snapshot Service](https://snapshot.ubuntu.com) repositories to pin every `apt` operation to a specific point-in-time package index. This guarantees that the simulation, the dev install, and the production upgrade all resolve the same package versions — regardless of when each step is executed.

The workflow spans two machines (Prod and Dev) and six sequential commands:

```
[ PRODUCTION ]                        [ DEV / STAGING ]

1. baseline
2. simulate ─────────────────────►  (copy bundle.tar.gz)
                                    3. apply-dev
                                    4. verify-dev
                                    5. (run your QA / test suite)
6. apply-prod  ◄─────────────────── (if tests pass)
7. verify-prod
```

Each command persists its state into a working directory (`upgrade_YYYYMMDD/`), so the process can be interrupted and resumed at any stage. A `.upgrade_config` file in the script directory tracks the active session.

---

## Compatible Distributions

Parity-Upgrade is built for **Ubuntu** (server and desktop) on releases that support the Ubuntu Snapshot Service. It depends on:

- `apt-get`, `dpkg`, `dpkg-query`, `apt-mark` (Debian/Ubuntu package management)
- `snapshot.ubuntu.com` (Ubuntu-specific snapshot infrastructure)
- `/etc/os-release` with `VERSION_CODENAME` (Ubuntu's release metadata)
- `systemd` (for the resume service and failed-unit checks)
- `systemd-detect-virt` (virtualization detection)

It is **not compatible** with Debian, RHEL/CentOS, Fedora, Arch, or other distributions. Within Ubuntu, it targets **intra-release upgrades** (security and package updates within the same Ubuntu version, e.g., 22.04.x → 22.04.y). It is not a replacement for `do-release-upgrade` and will refuse to operate if the dev and prod servers are on different Ubuntu versions.

Tested cloud platforms (detected and handled): AWS, GCP, Azure, DigitalOcean, Hetzner. Also supports on-premises VMs (KVM, VMware, Hyper-V) and bare metal.

---

## Requirements

- Root access (`sudo`)
- Bash 4.0+
- Network connectivity to `snapshot.ubuntu.com`
- `curl` or `wget` (for connectivity pre-flight; script warns if neither is present)
- Standard Ubuntu utilities: `awk`, `sed`, `sort`, `comm`, `diff`, `tar`, `fuser`, `lscpu`, `df`, `tput`

---

## Commands

All commands require root privileges. Run with `sudo`.

### `baseline`

**Where:** Production server

Captures the current system state as the reference point for simulation. Records:

- Full package manifest (`dpkg-query` output, `package=version` format)
- Running kernel version
- `apt-mark` manual/auto package designations
- Platform profile (CPU vendor, virtualization type, cloud provider, boot method, kernel flavor, architecture, OS version)

Output is stored in `./upgrade_YYYYMMDD/`. A snapshot ID is generated automatically from the current date (`YYYYMMDDT120000Z`).

```bash
sudo ./Parity-Upgrade.sh baseline
```

### `simulate [SNAPSHOT_ID]`

**Where:** Production server (after `baseline`)

Simulates a `dist-upgrade` against the snapshot-pinned package index. Does not modify the system. Produces:

- `simulation.txt` — raw `apt-get -s dist-upgrade` output
- `post_upgrade.txt` — computed post-upgrade package manifest (baseline + installs − removals)
- `sim_installs.txt` — packages that would be installed or upgraded, with target versions
- `sim_removals.txt` — packages that would be removed
- An upgrade bundle (`.tar.gz`) containing everything `apply-dev` needs

The snapshot ID defaults to the one created by `baseline`. An optional argument overrides it, allowing simulation against a different point in time.

A sanity check detects when the simulation produces zero changes (typically caused by stale apt cache or connectivity failure) and warns before creating the bundle.

```bash
sudo ./Parity-Upgrade.sh simulate
sudo ./Parity-Upgrade.sh simulate 20260301T120000Z   # override snapshot
```

### `apply-dev <UPGRADE_BUNDLE.tar.gz>`

**Where:** Dev/staging server

Installs the exact post-upgrade package state from the simulation onto the dev server. This is not a `dist-upgrade` — it is a targeted install to reach parity with what production will look like after upgrading.

The process runs through six internal phases:

1. **Platform Compatibility Check** — Detects the dev platform profile and compares it against the production profile from the bundle. If the platforms diverge (different cloud provider, CPU vendor, kernel flavor, etc.), platform-specific packages are protected from modification and a coverage report is generated at the end.

2. **Analyze Differences** — Computes the diff between the dev server's current packages and the target post-upgrade manifest. Determines which packages to install/upgrade and which to remove. Running kernel packages and platform-specific packages are excluded from removal.

3. **Configure Sources** — Adds snapshot repository sources for the same snapshot ID, verifies connectivity to `snapshot.ubuntu.com`, and updates the package index.

4. **Install Packages** — Executes a single bulk `apt-get install` with `--allow-downgrades` for proper dependency resolution. If the bulk operation fails, it retries each remaining package individually and reports failures.

5. **Restore Auto/Manual Marks** — `apt-get install` marks all installed packages as `manual`. This step resets them to `auto`, then re-marks only those packages that were marked `manual` on production. This preserves `autoremove` behavior for accurate parity.

6. **Remove Extra Packages** — Purges packages present on dev but absent from the target manifest. Protected packages (running kernel, platform-specific) are kept. Orphaned dependencies are cleaned up via `autoremove`.

7. **Verify** — Compares the dev server's live package state against the target, excluding protected/platform packages. Reports any remaining differences.

If a kernel upgrade occurred, the script installs a systemd oneshot service to handle post-reboot cleanup (old kernel purge, orphan removal) automatically.

```bash
sudo ./Parity-Upgrade.sh apply-dev ./upgrade_20260301T120000Z.tar.gz
```

### `verify-dev [WORK_DIR]`

**Where:** Dev/staging server (after `apply-dev` and optional reboot)

`WORK_DIR` is optional if you are running the command from the same directory as an active `.upgrade_config` session — the script will read the work directory from that config file automatically.

Runs a health check:

- Reports current kernel version
- Lists failed systemd units
- Checks for broken/half-configured dpkg packages
- Runs `apt-get check` for dependency consistency
- Compares live package state against the target manifest, reporting version mismatches and missing packages (with exclusions for kernel and platform-protected packages)

```bash
sudo ./Parity-Upgrade.sh verify-dev ./upgrade_20260301/
```

### `apply-prod <WORK_DIR>`

**Where:** Production server (after dev testing passes)

Executes the actual `dist-upgrade` on production, pinned to the same snapshot used during simulation. Requires typing `upgrade-prod` as confirmation.

The process:

1. Pins apt to the snapshot via `/etc/apt/apt.conf.d/50snapshot`
2. Runs `apt-get dist-upgrade` against the snapshot index
3. Compares the result against the simulated `post_upgrade.txt` and reports whether they match exactly
4. Runs `autoremove`
5. If a new kernel was installed, presents a reboot gate with the same systemd resume service as `apply-dev`

```bash
sudo ./Parity-Upgrade.sh apply-prod ./upgrade_20260301/
```

### `verify-prod [WORK_DIR]`

**Where:** Production server (after `apply-prod` and optional reboot)

`WORK_DIR` is optional if you are running the command from the same directory as an active `.upgrade_config` session — the script will read the work directory from that config file automatically.

Same health checks as `verify-dev`, plus a comparison of the live package state against the simulated post-upgrade target to confirm the actual dist-upgrade matches what the simulation predicted.

```bash
sudo ./Parity-Upgrade.sh verify-prod ./upgrade_20260301/
```

### `resume`

**Where:** Either server (called automatically by systemd after reboot)

Not typically invoked manually. Handles post-reboot kernel cleanup:

- Verifies the system booted into the target kernel (provides GRUB instructions if not)
- Purges old kernel packages (image, modules, modules-extra, headers, tools, cloud-tools — both signed and unsigned variants)
- Runs `autoremove` for orphaned dependencies
- Removes snapshot sources and restores normal apt configuration
- Cleans up the systemd resume service and state file

Can also be run manually as a fallback if the systemd service fails:

```bash
sudo ./Parity-Upgrade.sh resume ./upgrade_20260301/
```

---

## Options

| Flag | Description |
|---|---|
| `-v`, `--verbose` | Show full apt output instead of the condensed single-line progress bar. Useful for debugging failed installs. Can be combined with any command. |

---

## Pre-Flight Checks

The script performs several safety checks before any package operation:

**Snapshot Connectivity** — Probes `snapshot.ubuntu.com` via `curl` or `wget` before proceeding. Ubuntu's `apt-get update` returns exit code 0 even when it cannot reach remote repositories (fetch failures are warnings, not errors). Combined with `-qq` suppression, this would cause the script to silently operate against stale cached data. The pre-flight check catches this.

**Apt Lock Wait** — Checks `/var/lib/dpkg/lock-frontend`, `/var/lib/dpkg/lock`, and `/var/lib/apt/lists/lock` using `fuser`. If another process (typically `unattended-upgrades`) holds a lock, the script waits up to 300 seconds with periodic status messages, identifying the holding process by PID and name.

**Disk Space** — Checks three mount points independently:
- `/boot` (if on a separate partition): warns below 100 MB, with a command to purge old kernels
- `/` (root filesystem): warns below 500 MB
- `/var` (if on a separate partition): warns below 500 MB

**Simulation Sanity** — After simulation, checks whether `post_upgrade.txt` is identical to `baseline.txt`. If zero changes were detected, the user is warned that the snapshot index likely was not fetched correctly.

**Script Location Validation** — Before installing the systemd resume service, verifies the script is not on a tmpfs filesystem (which is cleared on reboot) and warns if it is under an encrypted home directory (inaccessible before user login, when the systemd service runs).

---

## Platform Divergence Handling

When the dev server differs from production in hardware or cloud configuration, the script detects and manages the divergence rather than failing.

**Detected attributes:**
- Architecture (critical — blocks if mismatched)
- CPU vendor (Intel vs. AMD — affects microcode packages)
- Virtualization type (KVM, Xen, VMware, Hyper-V, none, etc.)
- Cloud provider (AWS, GCP, Azure, DigitalOcean, Hetzner, detected via DMI board/sys vendor)
- Boot method (BIOS vs. EFI)
- Kernel flavor (generic, aws, azure, gcp, kvm, oracle, etc.)

**Protected package categories** (excluded from removal on the non-matching dev server):
- Running kernel and all associated packages (image, modules, modules-extra, headers, tools, cloud-tools, meta-packages)
- CPU microcode (intel-microcode, amd64-microcode)
- Bootloader packages (grub-efi, grub-pc, shim-signed)
- Cloud agent packages (amazon-ssm-agent, ec2-instance-connect, cloud-init, walinuxagent, google-guest-agent, droplet-agent, open-vm-tools, qemu-guest-agent, hyperv-daemons)
- Cloud kernel meta-packages (linux-aws, linux-azure, linux-gcp, linux-kvm, linux-oracle)
- All firmware packages
- Networking stack (netplan.io, networkd-dispatcher, systemd-networkd, ifupdown, network-manager)
- initramfs tooling

A **coverage report** is generated listing what could not be tested on dev due to platform differences, with a recommendation to use matching hardware for full coverage.

---

## Kernel Reboot Gate

When a kernel upgrade is detected (the highest installed kernel for the running flavor differs from the currently booted kernel), the script:

1. Displays the running and target kernel versions
2. Writes resume state to `.install_complete`
3. Installs a systemd oneshot service (`upgrade-manager-resume.service`) conditioned on the existence of the state file
4. Installs a dynamic MOTD script (`/etc/update-motd.d/99-upgrade-resume`) that shows resume status on SSH login
5. Prompts to reboot

After reboot, the systemd service runs `resume` automatically, which purges the old kernel, cleans orphans, removes snapshot sources, deletes the state file, and uninstalls itself. The MOTD shows either "IN PROGRESS" or "COMPLETED" until the verify command cleans it up.

---

## Progress Bar

All apt operations run behind a single in-place terminal progress bar that overwrites the same line. The bar parses apt output in real time and displays per-package status:

```
[████████████░░░░░░░░]  60% ─ ⚙ Setting up libssl3
```

Status indicators:
- `↓ package (N/M) [size]` — downloading
- `⚙ Unpacking package` — extracting
- `⚙ Setting up package` — configuring
- `✕ package` — removing

Downloads are weighted at 40% of the allocated progress range, with unpack/setup at 60%. The bar is hard-truncated to terminal width to prevent line wrapping, which would break the `\r` carriage-return overwrite.

All apt output is simultaneously written to `apt_output.log` in the work directory. On failure, the last 25 lines of the log are surfaced automatically — this is critical because the progress bar parser drops unrecognized lines.

In verbose mode (`-v`), the progress bar is disabled and full apt output passes through unchanged.

---

## Dpkg Configuration Handling

The script passes `--force-confdef` and `--force-confold` to dpkg via apt options. This prevents interactive configuration file prompts from blocking unattended operation:

- `confdef`: accept the package maintainer's default if the local config was never modified
- `confold`: keep the local version if the config was modified by the user

---

## File Structure

After a full run, the work directory contains:

```
upgrade_20260301/
├── snapshot_id.txt              # Snapshot timestamp
├── baseline.txt                 # Pre-upgrade package manifest (Prod)
├── manual_packages.txt          # apt-mark manual list (Prod)
├── platform_profile.txt         # Prod platform attributes
├── running_kernel.txt           # Prod kernel version at baseline
├── simulation.txt               # Raw apt simulation output
├── sim_installs.txt             # Packages to install/upgrade
├── sim_removals.txt             # Packages to remove
├── post_upgrade.txt             # Computed post-upgrade target manifest
├── upgrade_<SID>.tar.gz         # Bundle for transfer to Dev
├── dev_platform_profile.txt     # Dev platform attributes
├── dev_current.txt              # Dev package state before apply
├── dev_after.txt                # Dev package state after apply
├── dev_verify_live.txt          # Dev state at verify time
├── need_install.txt             # Packages installed on Dev
├── need_remove.txt              # Packages removed from Dev
├── dev_purged_packages.txt      # Record of purged packages
├── running_kernel_packages.txt  # Protected kernel packages
├── dev_protected_packages.txt   # Platform-protected packages
├── prod_platform_skip.txt       # Prod packages skipped on Dev
├── coverage_report.txt          # Cross-platform coverage gaps
├── apt_output.log               # Full apt output log
├── prod_post_distupgrade.txt    # Prod state after dist-upgrade
├── prod_post_upgrade.txt        # Prod state after full cleanup
├── resume.log                   # Post-reboot resume output
└── .install_complete            # Transient resume state (deleted after resume)
```

---

## Usage Examples

**Full workflow (matching platforms):**

```bash
# On Prod
sudo ./Parity-Upgrade.sh baseline
sudo ./Parity-Upgrade.sh simulate

# Copy bundle and script to Dev
scp ./upgrade_20260301/upgrade_20260301T120000Z.tar.gz dev-server:~/
scp ./Parity-Upgrade.sh dev-server:~/

# On Dev
sudo ./Parity-Upgrade.sh apply-dev ./upgrade_20260301T120000Z.tar.gz
# (reboot if prompted, resume runs automatically)
sudo ./Parity-Upgrade.sh verify-dev ./upgrade_20260301/
# Run your application test suite here

# On Prod (after Dev tests pass)
# Take a VM snapshot first!
sudo ./Parity-Upgrade.sh apply-prod ./upgrade_20260301/
# (reboot if prompted, resume runs automatically)
sudo ./Parity-Upgrade.sh verify-prod ./upgrade_20260301/
```

**Verbose mode (debugging):**

```bash
sudo ./Parity-Upgrade.sh -v apply-dev ./upgrade_20260301T120000Z.tar.gz
```

---

## Disclaimer

This software is provided **as-is**, without warranty of any kind, express or implied. The authors and contributors are not responsible for any damage, data loss, service disruption, or unbootable systems resulting from the use of this script.

This script performs destructive operations on package state, kernel images, `/boot` contents, apt sources, and systemd services. It can trigger system reboots. A failed or interrupted run may leave packages in a half-configured state, remove critical boot components, or render a server inaccessible.

**You are solely responsible for:**
- Taking VM-level snapshots before running `apply-prod` (or `apply-dev` on any machine you cannot afford to rebuild)
- Verifying that your environment meets the documented requirements and compatibility constraints
- Testing thoroughly on a non-production server before applying changes to production
- Maintaining your own backups and recovery procedures

By using this script, you acknowledge that you understand these risks and accept full responsibility for the outcome.

---

## License

This project is licensed under the [MIT License](LICENSE).
