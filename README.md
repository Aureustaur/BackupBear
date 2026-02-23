# 🐻 BackupBear
A robust, sleek Linux GUI wrapper for `rsync` and `rclone`, built with Electron.

## Features
* **Dual Engines:** Uses `rsync` for blazingly fast local backups and `rclone` for cloud syncing (Google Drive, Nextcloud, etc.).
* **Dynamic Modes:** Choose between Incremental updates or full Snapshot history.
* **Encryption:** Built-in support for `rclone crypt` to scramble files on remote OR local destinations.
* **Compression:** Dynamically use network transfer compression or full `.tar.gz` archiving.
* **Headless Automation:** Compiles your GUI choices into a standalone bash script and seamlessly injects it into Linux `crontab` for hands-free background backups.
* **Native Integration:** Hooks into Linux desktop notifications and fastfetch stripping.

## Installation
Simply download `packagebear.sh` and run it with `bash packagebear.sh`. The script will automatically download the dependencies, compile the Electron app, build a native Linux package, and install it on your system!
