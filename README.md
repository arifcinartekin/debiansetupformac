<div align="center">

# Debian Setup for Mac

**Debian 12 (bookworm) arm64 on Apple Silicon Macs, in one command.**

*QEMU + HVF, UEFI boot via systemd-boot, LUKS2-encrypted btrfs, an integrity seal checked before every boot, verified downloads, a first-boot wizard, and the commands you'll actually use: `debianopen`, `debianclose`, `debianuninstall`, `debianseal`.*

![Platform: macOS Apple Silicon](https://img.shields.io/badge/macOS-Apple%20Silicon-black)
![Guest: Debian 12 arm64](https://img.shields.io/badge/guest-Debian%2012%20arm64-d70a53)
![Shell: bash](https://img.shields.io/badge/shell-bash-blue)

</div>

---

## 🚀 Install

```bash
bash <(curl -fsSL https://debian.arifcinartekin.me/install)
```

That's it. `/install` is `debianopen-setup.sh` from `main`, published by GitHub Pages (the same file is at `raw.githubusercontent.com/arifcinartekin/debiansetupformac/main/debianopen-setup.sh`). No checksum to paste and nothing that disappears next week: the Debian netinst ISO and the Alpine ISO are pinned and mirrored in this repo's [releases](../../releases).

Early on it asks for a **disk passphrase**: the Debian disk is encrypted with LUKS2 and you type this passphrase at every boot. There is no way to recover the data without it.

When it finishes, it offers to start Debian right away. Enter the disk passphrase, then log in as **`user`** with password **`user`**; you pick a new password right away. The first-boot wizard takes over from there. There is no root login at all: root is locked from the install on, and `sudo` needs no password on the serial console (the terminal running `debianopen`).

> Takes roughly 10–20 minutes, mostly downloads and `apt full-upgrade`. You need about 3 GB of free disk space to start; the VM disk grows up to 20 GB as you use it.

---

## 🧰 Commands

| Command | Where | What it does |
|---|---|---|
| `debianopen` | Mac | Checks the VM files against the integrity seal, then boots Debian in the current terminal (serial console, no window). Resizing the terminal window resizes the console inside Debian too. Refuses to boot if a file changed |
| `debianclose` | Mac | Shuts Debian down cleanly from another terminal: presses the VM's power button, falls back to a hard stop after 90 s. `debianclose --force` stops it immediately |
| `debianuninstall` | Mac | Removes what the setup installed. Asks about each item separately, so you can keep QEMU or the VM disk and remove the rest |
| `debianseal verify` / `debianseal accept` | Mac | Checks the seal by hand / shows what changed and seals the current state after you confirm |
| `ssh -p 2224 user@localhost` | Mac | SSH into the running VM (bound to `127.0.0.1` only) |

Inside the VM, `sudo poweroff` works too, and so does <kbd>Ctrl</kbd>+<kbd>A</kbd> then <kbd>X</kbd> (instant hard stop). <kbd>Ctrl</kbd>+<kbd>C</kbd> goes to the program running inside Debian, as in any terminal; it does not stop the VM.

The SSH port is 2224 because [Arch Setup for Mac](https://github.com/arifcinartekin/archsetupformac) uses 2222 and [BSD Setup for Mac](https://github.com/arifcinartekin/bsdsetupformac) 2223: all three VMs can be installed and run side by side.

---

## 🪄 What happens

```
Mac                                         VM
───────────────────────────────────────────────────────────────────────────
1. Homebrew, qemu, gnupg (only if missing)
   ask for the disk passphrase
2. Alpine ISO        → sha256 pin + GPG ✓
   Debian netinst ISO → sha256 pin + GPG
                        (signed SHA256SUMS) ✓
3. Boot a throwaway Alpine VM ───────────▶  ESP (FAT32); root: LUKS2 (argon2id)
   with the Debian ISO attached             → btrfs, subvolumes @ @home @log @pkg
   (driven over the serial console          debootstrap the Debian base system
    with expect, no clicking; the           from the ISO
    passphrase is typed with echo off)      chroot: apt sources, apt full-upgrade,
                                            sudo/zsh/git/openssh…, kernel,
                                            initramfs with LUKS unlock,
                                            systemd-boot, fstab, crypttab,
                                            hostname "debian", networkd, terminfo,
                                            user "user" (sudo), root locked
4. Seal the VM files (Keychain)
   Boot via the launcher: seal check ────▶  unlock the disk, log in as user, check
                                            kernel / ESP / btrfs on LUKS / hostname /
                                            sshd / network / root locked / sudo
                                            password-free on the console only, arm
                                            the first-boot wizard, expire the
                                            temporary password
   seal again after the shutdown
5. Add debianopen / debianclose / debianuninstall
   / debianseal to ~/.zshrc
```

### The system

Debian 12 (bookworm), arm64, from the official Debian archive (`deb.debian.org`: `bookworm`, `bookworm-updates`, `bookworm-security`). The base comes from the pinned netinst ISO through `debootstrap --variant=minbase`; `apt full-upgrade` during the install brings it up to date, so you boot into current packages. On top of the base: the `linux-image-arm64` kernel, systemd-boot, cryptsetup, btrfs-progs, OpenSSH, sudo, zsh, git, curl, wget and a few everyday tools (`less`, `nano`, `man`, `ping`, …).

- **Boot:** systemd-boot on the ESP (`/boot/efi`). Kernels reach it through `kernel-install`, which Debian's kernel and initramfs hooks run on every update: `apt upgrade` installs a new kernel and it boots next time, no manual step
- **Network:** systemd-networkd (DHCP) and systemd-resolved; systemd-timesyncd for the clock
- **Locale:** `C.UTF-8`; timezone UTC (`sudo timedatectl set-timezone Europe/Istanbul` to change it)

### Accounts and sudo

The installer creates your account, **`user`** (`DEBIANOPEN_USER` to pick another name), in the `sudo` group, and **locks root**: no root login on the console, none over SSH. Use `sudo -i` for a root shell.

`sudo` needs **no password on the serial console**, the terminal running `debianopen`: that terminal already sits behind your Mac login, the integrity seal and the disk passphrase. Everywhere else (SSH, another terminal) it asks for your password. A PAM rule in `/etc/pam.d/sudo` does this by matching the terminal (`ttyAMA0`); the verification boot checks both sides.

The temporary password `user` expires once the install has checked everything: the first login asks for it once more and then for a new one.

### First boot wizard

At your first login on the console a one-time wizard starts (through `sudo`) and asks, `y/n` each:

1. [**zsh_setup**](https://github.com/arifcinartekin/zsh_setup) for you: zsh, Oh My Zsh, Powerlevel10k, autosuggestions, syntax highlighting. The p10k configuration wizard runs at the end
2. **htop**, **fastfetch** with an `info` command, and [**lsd**](https://github.com/lsd-rs/lsd) (`ls` with colors and icons). fastfetch also runs at every login, so you see the system info each time you `debianopen`. With lsd, `ls`, `ll`, `la` and `lt` (tree) use it
3. [**ly**](https://codeberg.org/fairyglade/ly) as the login screen on the console (big clock, user and session picker; <kbd>F1</kbd> shuts down, <kbd>F2</kbd> reboots)

Then it removes itself and logs you out, onto the ly login screen if you chose it. Press <kbd>Ctrl</kbd>+<kbd>C</kbd> to skip it; it runs again at the next login on the console.

htop and lsd come from Debian. Two things Debian 12 does not ship come from their upstream projects only, pinned by sha256 and mirrored unchanged in this repo's release [`firstboot-tools-1`](../../releases/tag/firstboot-tools-1) (upstream is the fallback):

- **fastfetch 2.71.0**: upstream's own Debian package (Debian has fastfetch from 13 on)
- **ly 1.4.1** (the version Arch Linux ARM ships): built from upstream's source in the VM with upstream's vendored dependencies and Zig 0.16.0 from ziglang.org, without X11 support (there is no X server). The build tools are removed again afterwards

> 💡 Powerlevel10k icons need a Nerd Font **in your Mac terminal**, e.g. *MesloLGS NF* (Ghostty ships a Nerd Font by default).

---

## 🔐 Encryption and the integrity seal

**The disk.** The Debian root sits on a LUKS2 volume (aes-xts, argon2id) with btrfs inside it (`@` → `/`, `@home`, `@log` → `/var/log`, `@pkg` → `/var/cache/apt`, zstd compression). The initramfs (cryptsetup-initramfs, from `/etc/crypttab`) asks for the passphrase on the serial console at every boot. Without the passphrase, `disk.qcow2` is unreadable, whoever copies it.

**The problem LUKS does not solve.** The boot chain cannot be encrypted: the UEFI firmware, its variables, the ESP with systemd-boot, the kernel and the initramfs are plain files in `~/vm/debian`. Anyone who can change `efi.qcow2` can put in an initramfs that records your passphrase the next time you type it, and LUKS then protects nothing.

**The seal.** `debianopen` checks every file in the install directory before it starts QEMU:

- each file's sha256, size and mode: `efi.qcow2`, `disk.qcow2`, `vars.fd`, `efi-code.fd` (a private copy of the UEFI firmware), `start-uefi.sh`, `debianclose.sh`, `debianuninstall.sh`, `debianseal.sh`. A file that was **added** or **removed** counts as a change too
- the digest of that list is kept in your **macOS login Keychain**, not next to the files. Replacing `efi.qcow2` together with the list next to it is not enough to get through the check
- one changed file and **QEMU is not started**: the passphrase prompt never appears. `debianopen` names what changed

```
INTEGRITY CHECK FAILED: the VM files are not what they were when it last shut down.
  changed: efi.qcow2

  The VM was NOT started, so nothing has asked for your disk passphrase.
```

When the VM shuts down, the launcher seals the new state: the session itself changed `disk.qcow2`, and a kernel update rewrites the ESP. The UEFI variables (`vars.fd`) don't change: every boot runs on a throwaway copy. Hashing runs at about 2 GB/s, so a few seconds per boot for a well-filled disk.

If the last session did not end normally (Mac crashed, the launcher was killed), its changes were never sealed and the next `debianopen` refuses to boot, with a note that says so. If that is what happened, run `debianseal accept`: it shows what changed and seals after you confirm.

**What the seal does not protect against.** For this VM, your Mac is the hardware. Code that runs as your macOS user can also edit the launcher, your `~/.zshrc` or QEMU itself, and it can update the Keychain item with the same `security` tool the launcher uses. A real TPM does not protect against a compromised firmware either. The seal catches changes made to the VM files while you weren't running them: by another account or app that can write to the folder, a sync or backup tool that restored or overwrote a file, a guest that changed its own ESP, or a damaged file. Against someone with your Mac's disk in their hands, FileVault is what protects you. Keep it on.

---

## 🗑️ Uninstall

```bash
debianuninstall
```

It asks about each item (`y/N`), shows a summary, and asks once more before removing anything:

| Item | Notes |
|---|---|
| Debian virtual disks | `disk.qcow2`, `efi.qcow2`, `vars.fd`, `efi-code.fd`: the whole Debian system, plus its seal in the Keychain |
| Download cache and logs | Alpine ISO, Debian ISO, `install.log`, `versions.lock` |
| Shell commands | The `debianopen` block in `~/.zshrc` (all four commands) and `~/.zshrc.debianopen-backup` |
| SSH host key | `[localhost]:2224` in `~/.ssh/known_hosts`, if present |
| QEMU, GnuPG | `brew uninstall`; tells you if they were already there before the setup |
| `brew autoremove` | Only offered if you removed one of the above |
| Homebrew | Only offered if the setup installed it |

A running VM is shut down first. Once nothing of the install is left, `~/vm/debian` is removed, and so is `~/vm` if nothing else is in it (an Arch or FreeBSD VM next to it stays). `debianuninstall --all` removes everything without asking. If the commands are already gone:

```bash
bash <(curl -fsSL https://debian.arifcinartekin.me/uninstall)
```

Nothing inside the VM needs cleaning up: zsh_setup and everything else ran inside Debian and is deleted with the disk.

---

## ⚙️ Configuration

All optional, set as environment variables in front of the install command:

| Variable | Default | |
|---|---|---|
| `DEBIANOPEN_DIR` | `~/vm/debian` | Install directory (keep the path short: the QMP socket path has a limit of ~100 characters) |
| `DEBIANOPEN_HOSTNAME` | `debian` | Hostname inside the VM |
| `DEBIANOPEN_CPUS` / `DEBIANOPEN_MEM` | `4` / `4G` | VM resources |
| `DEBIANOPEN_ROOT_SIZE` / `DEBIANOPEN_ESP_SIZE` | `20G` / `1G` | Disk sizes (thin-provisioned qcow2) |
| `DEBIANOPEN_USER` | `user` | Your account inside the VM (sudo group) |
| `DEBIANOPEN_SSH_PORT` | `2224` | Host port forwarded to the VM's port 22 |
| `DEBIANOPEN_LUKS_PASSPHRASE` | | Disk passphrase, instead of asking for it (needed for an install without a terminal) |
| `DEBIANOPEN_YES=1` | | Do not ask for confirmation |
| `DEBIANOPEN_FORCE=1` | | Overwrite an existing install |
| `DEBIANOPEN_PIN_BREW=1` | | `brew pin qemu gnupg` |
| `DEBIANOPEN_APT_MIRROR` | `http://deb.debian.org` | Debian mirror used inside the VM (`…/debian` and `…/debian-security` below it) |

Example:

```bash
DEBIANOPEN_MEM=8G DEBIANOPEN_ROOT_SIZE=64G bash <(curl -fsSL https://debian.arifcinartekin.me/install)
```

---

## 🔒 Pinned versions and verification

| | Source | Checks |
|---|---|---|
| Alpine `3.24.3` (installer only) | [GitHub release `alpine-3.24.3`](https://github.com/arifcinartekin/debiansetupformac/releases/tag/alpine-3.24.3) of this repo (unmodified copy), then `dl-cdn.alpinelinux.org` | sha256 pinned in the script + GPG signature by fingerprint `0482D840…D9495A` |
| Debian `12.15.0` arm64 netinst ISO | [GitHub release `debian-12.15.0`](https://github.com/arifcinartekin/debiansetupformac/releases/tag/debian-12.15.0) of this repo (unmodified copy), then `cdimage.debian.org` | sha256 pinned in the script + the ISO's entry in **upstream** `SHA256SUMS`, GPG-signed by the Debian CD signing key `DF9B9C49…6294BE9B`. Checked again inside the installer VM |
| Debian packages | `deb.debian.org` | apt's own signature checks (`debian-archive-keyring`); debootstrap checks the ISO's packages against its `Release` / `Packages` files |
| fastfetch, ly, Zig (wizard) | [GitHub release `firstboot-tools-1`](https://github.com/arifcinartekin/debiansetupformac/releases/tag/firstboot-tools-1), then upstream | sha256 pinned in the wizard; ly's git fallback is checked against the pinned commit |
| Companion scripts | this repo | fetched from the same repo and ref as the setup script |

**Why mirror the ISOs?** Debian moves a point release's images from `cdimage/release` to `cdimage/archive` and the Alpine CDN only keeps recent releases: an install that depends on one URL breaks sooner or later. The release assets are the same files, byte for byte, so the upstream checksums and signatures still verify them. `SHA256SUMS`, its signature and the key are still fetched from upstream first. The ~550 MB ISO sits in GitHub Releases rather than in git: release assets can be up to 2 GB and have no bandwidth cap, while git rejects files over 100 MB.

The installed system is not old: `apt full-upgrade` runs during setup, so you boot into current packages. The ISO only fixes the starting point.

### Updating the pinned ISO (maintainers)

```bash
tools/publish-iso.sh 12.16.0        # verify SHA256SUMS + GPG, upload the release, update the script
git commit -am "Pin Debian 12.16.0 netinst" && git push
```

Needs `gh` (logged in with push access) and `gpg`; `--iso FILE` uses an ISO you already downloaded. To bump Alpine, edit `ALPINE_VERSION` and `ALPINE_ISO_SHA256` and publish the mirror:

```bash
gh release create alpine-<version> --latest=false --title "Alpine <version> aarch64 (installer environment)" \
  alpine-virt-<version>-aarch64.iso{,.sha256,.asc} ncopa.asc
```

---

## 📁 Repository layout

```
debianopen-setup.sh                   Mac: the installer (the one-liner runs this)
guest/debianopen-firstboot.sh         VM:  first-boot wizard (zsh, tools, login screen)
guest/debianopen-winsize.sh           VM:  applies the Mac terminal's size to the serial console
mac/debianclose.sh                    Mac: `debianclose`
mac/debianuninstall.sh                Mac: `debianuninstall`
mac/debianseal.sh                     Mac: `debianseal`, the integrity seal `debianopen` checks
third_party/zsh_setup/zsh_setup.sh    VM:  unmodified copy of arifcinartekin/zsh_setup
tools/publish-iso.sh                  Maintainers: pin a new Debian ISO
site/index.html                       debian.arifcinartekin.me landing page
.github/workflows/pages.yml           Publishes /install and /uninstall on debian.arifcinartekin.me
```

Files on your Mac after install (`~/vm/debian`): `disk.qcow2`, `efi.qcow2`, `vars.fd`, `efi-code.fd`, `start-uefi.sh`, `debianclose.sh`, `debianuninstall.sh`, `debianseal.sh`, `downloads/`, `install.log`, `versions.lock` (exact versions and package list), `.debianopen-manifest` (what was installed on the Mac, used by `debianuninstall`) and `.debianopen-seal` (the sealed file list, used to name what changed). Outside of it: one `debianopen-seal` item in the login Keychain.

---

## 🩺 Troubleshooting

| Problem | Fix |
|---|---|
| Install failed | Read `~/vm/debian/install.log` with `less` or `cat -v` (plain `cat` lets your terminal answer the escape sequences recorded in it, which leaves junk at your prompt), then run the setup again. It resumes downloads and redoes the disk |
| `There is already an install` | `debianuninstall` first, or `DEBIANOPEN_FORCE=1` |
| `INTEGRITY CHECK FAILED` | Something changed a VM file while Debian was off. If you know why (the last session crashed, you restored a backup), `debianseal accept`. If you don't, don't boot it |
| `no seal ... in the Keychain` | You moved the install directory or the Keychain item is gone: check the files, then `debianseal accept` |
| Change the disk passphrase | Inside the VM: `sudo cryptsetup luksChangeKey /dev/disk/by-label/debiancrypt` |
| Forgot the disk passphrase | The data can't be recovered. `debianuninstall` and install again |
| `The Debian VM is already running` | It's open in another terminal. `debianclose` |
| `debianclose` says *no QMP socket* | The VM was started by a launcher from an older version: `debianclose --force`, or reinstall |
| SSH: `REMOTE HOST IDENTIFICATION HAS CHANGED` | You reinstalled: `ssh-keygen -R "[localhost]:2224"` |
| Plain console login instead of ly (or back) | `sudo debianopen-firstboot --login-screen console` (or `ly`, which builds ly first if the wizard skipped it) |
| Text stays at the old size after resizing the window | The VM was started by a launcher from an older version: reinstall. Inside Debian, `systemctl status debianopen-winsize` shows whether the size helper runs |
| A kernel update does not boot | `ls /boot/efi/$(cat /etc/machine-id)` should list every installed kernel; `sudo kernel-install add <version> /boot/vmlinuz-<version> /boot/initrd.img-<version>` adds a missing one |
| Root password wanted | root is locked on purpose: `sudo -i`. To give it a password anyway: `sudo passwd root` |
| Skipped zsh setup | As your user: `sh /usr/local/share/debianopen/zsh_setup.sh` |
| Plain `ls` instead of lsd | Remove the `debianopen lsd` block from `~/.zshrc` (bash: `~/.bashrc`), or run `\ls` once |
| No fastfetch at login | Remove the `debianopen info` block from `~/.zprofile` (bash: `~/.profile`). The `info` alias is in `~/.zshrc` (bash: `~/.bashrc`) |

---

<div align="center">
Made by <a href="https://github.com/arifcinartekin">arifcinartekin</a> · zsh setup from <a href="https://github.com/arifcinartekin/zsh_setup">zsh_setup</a>
</div>
