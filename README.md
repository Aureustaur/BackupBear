# 🐻 BackupBear

A robust, sleek Linux GUI wrapper for `rsync` and `rclone`, built with Electron.

<p align="center">
  <img src="https://raw.githubusercontent.com/Aureustaur/BackupBear/main/screenshots/main.png" alt="BackupBear Main Interface" width="85%">
</p>

## 🚀 Features
* **Dual Engines:** Uses `rsync` for blazingly fast local backups and `rclone` for cloud syncing (Google Drive, Nextcloud, etc.).
* **Dynamic Modes:** Choose between Incremental updates (fast) or full Snapshot history (clones).
* **Ironclad Encryption:** Built-in support for `rclone crypt` to scramble files on remote *or* local destinations. Your files remain completely secure.
* **Compression:** Dynamically use network transfer compression (`-z`) to speed up NAS syncs, or pack everything into a solid `.tar.gz` Archive file.
* **Headless Automation:** Compiles your GUI choices into a standalone bash script and seamlessly injects it into your Linux `crontab` for hands-free background backups.
* **Native Integration:** Hooks into Linux desktop notifications and automatically handles terminal output formatting.

## 📸 Interface Gallery

<p align="center">
  <img src="https://raw.githubusercontent.com/Aureustaur/BackupBear/refs/heads/main/screenshots/options.png" alt="Filters and Excludes" width="49%">
  <img src="https://raw.githubusercontent.com/Aureustaur/BackupBear/main/screenshots/cloud.png" alt="Cloud and Explorer" width="49%">
</p>
<p align="center">
  <img src="https://raw.githubusercontent.com/Aureustaur/BackupBear/main/screenshots/sched.png" alt="Headless Automation" width="49%">
  <img src="https://raw.githubusercontent.com/Aureustaur/BackupBear/main/screenshots/about.png" alt="About BackupBear" width="49%">
</p>

---

## 💾 Installation Instructions

Head over to the **[Latest Releases](https://github.com/Aureustaur/BackupBear/releases/latest)** page and download the pre-compiled package for your Linux distribution from the Assets section. 

Once downloaded, open your terminal and run the commands for your specific system to install the app and all required dependencies:

### For Arch Linux / CachyOS / Manjaro (.pacman)
```bash
cd ~/Downloads
sudo pacman -U backupbear-*.pacman
```

## For Debian / Ubuntu / Linux Mint (.deb)

```bash
cd ~/Downloads
sudo apt install ./backupbear_*_amd64.deb
```

(Note: Using apt install ./ instead of dpkg automatically handles downloading missing dependencies like rclone or rsync!)

After installing, simply search for "BackupBear" in your application menu to launch!

## 🛠️ Compile from Source

If you want to build the absolute latest version directly from the code, BackupBear includes a master packager script that handles everything. It will install build dependencies, generate the app icons, inject the architecture, and compile the final .pacman and .deb files into a dist/ folder.

```bash
git clone [https://github.com/Aureustaur/BackupBear.git](https://github.com/Aureustaur/BackupBear.git)
cd BackupBear
bash packagebear.sh
```
