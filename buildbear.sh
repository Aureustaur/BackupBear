#!/bin/bash
# BackupBear 13.6.0: Advanced Filtering & Excludes

set -e

APP_DIR="$HOME/BackupBear-Electron"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# 1. LOGO
if [ -f "$APP_DIR/aureus-logo.png" ]; then
    cp "$APP_DIR/aureus-logo.png" "$APP_DIR/logo.png"
elif [ -f "$HOME/aureus-logo.png" ]; then
    cp "$HOME/aureus-logo.png" "$APP_DIR/logo.png"
else
    cat <<EOF > "$APP_DIR/logo.svg"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><path fill="#FF9800" d="M199 23C133 60 93 132 102 203c4 30 16 58 36 81 20 23 16 24 7 29-44 23-68 70-61 124 8 60 57 103 120 106 66 3 133-33 161-85 16-31 17-73 1-105-8-17-11-18 11-41 40-42 46-108 13-155-21-31-59-51-102-56-24-2-66 2-88-18Z"/></svg>
EOF
    if command -v magick &> /dev/null; then 
        magick -background none -resize 512x512 "$APP_DIR/logo.svg" "$APP_DIR/logo.png"
    elif command -v convert &> /dev/null; then 
        convert -background none -resize 512x512 "$APP_DIR/logo.svg" "$APP_DIR/logo.png"
    else 
        cp "$APP_DIR/logo.svg" "$APP_DIR/logo.png"
    fi
fi

# 2. CONFIG
cat <<EOF > package.json
{
  "name": "backupbear",
  "version": "13.6.0",
  "main": "main.js",
  "scripts": { "start": "electron . --no-sandbox" }
}
EOF

# 3. PRELOAD
cat <<'EOF' > preload.js
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('bear', {
    invoke: (channel, data) => ipcRenderer.invoke(channel, data),
    send: (channel, data) => ipcRenderer.send(channel, data),
    on: (channel, func) => ipcRenderer.on(channel, (event, ...args) => func(...args)),
    getHome: () => ipcRenderer.invoke('get-home')
});
EOF

# 4. BACKEND
cat <<'EOF' > main.js
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { spawn, exec, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

let mainWindow;
let activeProcess = null;

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1050, height: 700,
        minWidth: 900, minHeight: 650,
        backgroundColor: '#121212',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: path.join(__dirname, 'preload.js')
        },
        autoHideMenuBar: false,
        title: "BackupBear 13.6.0",
        icon: path.join(__dirname, 'logo.png')
    });
    mainWindow.loadFile('index.html');
}
app.whenReady().then(createWindow);

ipcMain.handle('get-home', () => os.homedir());

ipcMain.handle('check-deps', async () => {
    const checkCmd = (cmd) => { try { execSync(`command -v ${cmd}`); return true; } catch { return false; } };
    const hasRclone = checkCmd('rclone');
    const hasRsync = checkCmd('rsync');
    let installCmd = 'sudo apt install rclone rsync';
    if (checkCmd('pacman')) installCmd = 'sudo pacman -S rclone rsync';
    else if (checkCmd('dnf')) installCmd = 'sudo dnf install rclone rsync';
    return { ok: hasRclone && hasRsync, missing: [!hasRclone ? 'rclone' : '', !hasRsync ? 'rsync' : ''].filter(Boolean), installCmd: installCmd };
});

ipcMain.handle('rclone-list', async () => new Promise(resolve => exec('rclone listremotes', (e, out) => resolve(e ? [] : out.split('\n').filter(r => r.trim()).map(r => r.replace(':', ''))))));
ipcMain.handle('rclone-ls', async (e, remote) => new Promise(resolve => exec(`rclone lsjson "${remote}:" --max-depth 1`, (err, out) => {
    if(err) return resolve([]);
    try { const f = JSON.parse(out); f.sort((a,b) => (b.IsDir===a.IsDir)?0:b.IsDir?1:-1); resolve(f); } catch { resolve([]); }
})));
ipcMain.handle('rclone-auth-drive', async (e, name) => new Promise(resolve => {
    const proc = spawn('rclone', ['authorize', 'drive']);
    proc.on('error', (err) => { resolve(err.code === 'ENOENT' ? "Engine Error: rclone missing" : "Error: " + err.message); });
    let buf = ''; proc.stdout.on('data', d => buf += d.toString());
    proc.on('close', code => {
        if(code !== 0) return resolve("Auth Failed");
        const match = buf.match(/\{.*\}/);
        if(!match) return resolve("No Token");
        try {
            const cfgDir = path.join(os.homedir(), '.config', 'rclone');
            if(!fs.existsSync(cfgDir)) fs.mkdirSync(cfgDir, {recursive:true});
            fs.appendFileSync(path.join(cfgDir, 'rclone.conf'), `\n[${name}]\ntype = drive\nscope = drive\ntoken = ${match[0]}\n`);
            resolve("Success");
        } catch(e) { resolve("File Error: " + e.message); }
    });
}));
ipcMain.handle('rclone-auth-nextcloud', async (e, args) => new Promise(resolve => {
    exec(`rclone obscure '${args.pass}'`, (err, out) => {
        if(err) return resolve("Engine Error: rclone missing");
        exec(`rclone config create "${args.name}" nextcloud url="${args.url}" user="${args.user}" pass="${out.trim()}"`, e => resolve(e ? "Failed" : "Success"));
    });
}));
ipcMain.handle('rclone-delete', async (e, n) => new Promise(resolve => exec(`rclone config delete "${n}"`, () => resolve("Deleted"))));
ipcMain.handle('dialog:open', async () => { const r = await dialog.showOpenDialog(mainWindow, {properties:['openDirectory']}); return r.canceled ? null : r.filePaths[0]; });
ipcMain.on('stop-task', () => { if(activeProcess) { activeProcess.kill(); activeProcess=null; if(!mainWindow.isDestroyed()) mainWindow.webContents.send('done', "Stopped"); }});

ipcMain.on('start-backup-batch', async (e, args) => {
    const { sources, destinations, encrypt, key, mode, excludes } = args;
    const now = new Date();
    const stamp = now.toISOString().replace(/T/,'_').replace(/:/g,'-').slice(0,16);

    // Build the dynamic exclude string
    const excludeString = excludes.map(ex => `--exclude '${ex}'`).join(' ');

    for (const dest of destinations) {
        if (!dest.enabled) continue;
        if (activeProcess === "STOPPED") break;
        
        let baseDest = dest.path;
        if (mode === 'full') baseDest = dest.path.includes(':') ? `${dest.path}:${stamp}` : path.join(dest.path, `Backup_${stamp}`);
        else if (dest.type === 'cloud' && !dest.path.includes(':')) baseDest = `${dest.path}:Backup`;

        for (const src of sources) {
            if (!src.enabled) continue;
            if (activeProcess === "STOPPED") break;

            const srcPath = src.path;
            let finalDest = baseDest;

            if (srcPath !== '/') {
                const relativeSrc = srcPath.replace(/^\/+/, '');
                if (finalDest.includes(':')) {
                    finalDest = finalDest.endsWith('/') ? finalDest + relativeSrc : finalDest + '/' + relativeSrc;
                } else {
                    finalDest = path.join(finalDest, relativeSrc);
                    fs.mkdirSync(finalDest, { recursive: true });
                }
            } else {
                if (!finalDest.includes(':') && !fs.existsSync(finalDest)) {
                    fs.mkdirSync(finalDest, { recursive: true });
                }
            }

            let cleanSrc = srcPath.endsWith('/') ? srcPath : srcPath + '/';

            if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `Syncing: ${srcPath}`, fullRaw: `\n[SYSTEM] Starting transfer: ${srcPath} -> ${finalDest}`, pct: "0%", speed: "--", eta: "--" });
            
            await new Promise(resolve => {
                let cmd = "";
                if (dest.type === 'cloud') {
                    let rcloneCmd = `rclone sync '${cleanSrc}' '${finalDest}' --progress --stats-one-line ${excludeString}`;
                    if (encrypt && key) {
                        try {
                            const obs = execSync(`rclone obscure '${key}'`).toString().trim();
                            cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${finalDest}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rcloneCmd.replace(finalDest, 'T:')}`;
                        } catch { cmd = "echo 'Key Error'"; }
                    } else { cmd = rcloneCmd; }
                } else {
                    let flags = mode === 'full' ? "-aAXx --info=progress2" : "-aAXx --delete --info=progress2";
                    cmd = `rsync ${flags} ${excludeString} '${cleanSrc}' '${finalDest}/' | tr '\\r' '\\n'`;
                }
                
                const proc = spawn('/bin/bash', ['-c', cmd]);
                proc.on('error', (err) => {
                    if(mainWindow.isDestroyed()) return;
                    mainWindow.webContents.send('progress', { raw: `Engine Error`, fullRaw: err.toString(), pct: "ERR", speed: "--", eta: "--" });
                    resolve();
                });
                activeProcess = proc;
                proc.stdout.on('data', d => {
                    if(mainWindow.isDestroyed()) return;
                    const line = d.toString().trim();
                    let spd="--", eta="--", pct="Working...";
                    if(dest.type==='cloud' && line.includes('%')) {
                        const p = line.split(',');
                        if(p.length>2) { pct = p[0].trim().split(' ')[0] || "0%"; spd = p[2]?.trim() || "--"; let rawEta = p[3]?.trim().replace('ETA','') || "--"; eta = rawEta.split('(')[0].trim(); }
                    } else if(line.includes('%')) {
                        const p = line.split(/\s+/).filter(x=>x);
                        if(p.length>=4) { pct = p[1]; spd = p[2]; eta = p[3].split('(')[0].trim(); }
                    }
                    mainWindow.webContents.send('progress', { raw: `[${dest.type}] ${line.substring(0,50)}...`, fullRaw: line, pct, speed:spd, eta });
                });
                proc.stderr.on('data', d => {
                    if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `[ERROR] Processing issue...`, fullRaw: `[ERR] ${d.toString().trim()}`, pct: "!", speed: "--", eta: "--" });
                });
                proc.on('close', () => { activeProcess=null; resolve(); });
            });
        }
    }
    if(!mainWindow.isDestroyed()) mainWindow.webContents.send('done', "Batch Complete");
});
EOF

# 5. HTML
cat <<'EOF' > index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>BackupBear 13.6.0</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700&family=JetBrains+Mono:wght@700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <style>
        :root { --bg: #000; --sidebar: #111; --card: #1a1a1a; --text: #fff; --accent: #FF9800; --border: #333; --input: #000; }
        body { background: var(--bg); color: var(--text); font-family: 'Inter', sans-serif; overflow: hidden; user-select: none; }
        
        .sidebar { height: 100vh; background: var(--sidebar); padding: 15px; width: 220px; position: fixed; border-right: 1px solid var(--border); }
        .content { margin-left: 220px; padding: 20px; height: 100vh; overflow-y: auto; display: flex; flex-direction: column; }
        
        .nav-btn { display: flex; align-items: center; gap: 10px; width: 100%; padding: 12px 15px; margin-bottom: 5px; background: transparent; border: 1px solid transparent; color: #888; font-weight: 700; border-radius: 8px; font-size: 0.85rem; cursor: pointer; transition: all 0.2s; }
        .nav-btn:hover { color: var(--text); background: rgba(128,128,128,0.1); }
        .nav-btn.active { background: var(--accent); color: #000 !important; }
        
        .view-section { display: none; flex-grow: 1; }
        .view-section.active { display: block; animation: fadeIn 0.3s; }
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
        
        h2.mb-3 { margin-bottom: 1rem !important; font-size: 1.5rem; }
        
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 10px; transition: border 0.2s; }
        .card-header { border-bottom: 1px solid var(--border); color: var(--accent); font-weight: 800; text-transform: uppercase; padding: 10px 15px; font-size: 0.75rem; letter-spacing: 1px; }
        
        .dest-list { height: 120px; overflow-y: auto; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; }
        .ex-list { max-height: 250px; overflow-y: auto; background: var(--bg); border: 1px solid var(--border); border-radius: 8px; }
        .dest-item { display: flex; align-items: center; padding: 8px 10px; border-bottom: 1px solid var(--border); }
        .dest-icon { margin-right: 10px; font-size: 1rem; color: var(--accent); }
        .dest-path { flex-grow: 1; font-family: 'JetBrains Mono', monospace; font-size: 0.8rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .dest-check { width: 16px; height: 16px; accent-color: var(--accent); cursor: pointer; }
        
        .form-control { background-color: var(--input) !important; color: var(--text) !important; border: 1px solid #444 !important; padding: 8px 10px; font-family: 'JetBrains Mono', monospace; font-size: 0.85rem;}
        .form-control:focus { border-color: var(--accent) !important; box-shadow: none !important; }
        .is-valid { border-color: #198754 !important; background-image: none !important; }
        .is-invalid { border-color: #dc3545 !important; background-image: none !important; }
        
        .cloud-tabs { display: flex; gap: 10px; overflow-x: auto; padding-bottom: 10px; border-bottom: 1px solid var(--border); margin-bottom: 10px; }
        .cloud-tab { background: #222; color: #888; border: 1px solid var(--border); padding: 6px 12px; border-radius: 15px; white-space: nowrap; cursor: pointer; font-weight: bold; font-size: 0.85rem; }
        .cloud-tab:hover { color: #fff; border-color: #666; }
        .cloud-tab.active { background: var(--accent); color: #000; border-color: var(--accent); }
        
        .file-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(90px, 1fr)); gap: 10px; max-height: 300px; overflow-y: auto; }
        .file-item { background: #222; padding: 10px; border-radius: 8px; text-align: center; cursor: pointer; transition: background 0.2s; }
        .file-item:hover { background: #333; }
        .file-icon { font-size: 1.8rem; color: #666; margin-bottom: 3px; }
        .file-name { font-size: 0.7rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: #ccc; }
        .is-dir .file-icon { color: var(--accent); }
        
        .metric-lbl { color: var(--accent) !important; font-size: 0.75rem; font-weight: 800; display: block !important; margin-bottom: 3px; opacity: 1 !important; }
        .metric-val { font-family: 'JetBrains Mono', monospace; font-size: 1.3rem; color: var(--accent); font-weight: bold; white-space: nowrap; }
        
        .logo-img { width: 120px; display: block; margin-bottom: 5px; }
        .hero-logo { width: 180px; margin-bottom: 20px; animation: float 6s ease-in-out infinite; }
        @keyframes float { 0% { transform: translateY(0px); } 50% { transform: translateY(-15px); } 100% { transform: translateY(0px); } }
        
        #auth-overlay, #dep-overlay { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.95); z-index: 9999; display: none; align-items: center; justify-content: center; flex-direction: column; text-align: center; }
    </style>
</head>
<body>
    <div id="dep-overlay">
        <i class="bi bi-exclamation-triangle-fill text-warning mb-4" style="font-size: 3rem;"></i>
        <h3 class="fw-bold text-white mb-2">Missing System Dependencies</h3>
        <p class="text-secondary fs-6 mb-3">BackupBear requires <b class="text-white">rclone</b> and <b class="text-white">rsync</b> to function.</p>
        <div class="card bg-dark border-secondary p-3 mb-3" style="width: 450px;">
            <div class="text-start small text-secondary mb-2 fw-bold">RUN THIS IN YOUR TERMINAL:</div>
            <code id="dep-cmd" class="text-warning fs-6 user-select-all" style="cursor: pointer;" title="Click to copy" onclick="navigator.clipboard.writeText(this.innerText); alert('Copied to clipboard!');"></code>
        </div>
        <button class="btn btn-sm btn-outline-light mt-2 px-4 py-2" onclick="window.close()">Exit BackupBear</button>
    </div>

    <div class="modal fade" id="weakPwModal" tabindex="-1">
        <div class="modal-dialog modal-dialog-centered">
            <div class="modal-content" style="background:var(--card); color:var(--text); border: 1px solid #dc3545;">
                <div class="modal-header border-secondary">
                    <h5 class="modal-title fw-bold text-danger"><i class="bi bi-shield-exclamation"></i> Security Warning</h5>
                    <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
                </div>
                <div class="modal-body">
                    <p id="weak-reason" class="fw-bold text-warning fs-5"></p>
                    <p class="text-secondary small">For securing files on the cloud, a robust passphrase is highly recommended.</p>
                    <p class="mb-0 fw-bold">Do you want to proceed with this weak passphrase anyway?</p>
                </div>
                <div class="modal-footer border-secondary">
                    <button type="button" class="btn btn-outline-secondary" data-bs-dismiss="modal">Make it Stronger</button>
                    <button type="button" class="btn btn-danger fw-bold" id="btn-force-backup">Proceed Anyway</button>
                </div>
            </div>
        </div>
    </div>

    <div class="modal fade" id="cloudModal" tabindex="-1"><div class="modal-dialog modal-dialog-centered"><div class="modal-content" style="background:var(--card); color:var(--text);"><div class="modal-header border-secondary"><h6 class="modal-title">Select Remote</h6><button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button></div><div class="modal-body"><select id="modal-cloud-list" class="form-select form-select-sm form-control mb-3"></select><button id="btn-confirm-cloud" class="btn btn-warning btn-sm w-100">Add</button></div></div></div></div>

    <div class="sidebar">
        <div class="d-flex flex-column align-items-center mb-4 ps-1">
            <img src="logo.png" class="logo-img" onerror="this.src='logo.svg'">
            <h5 class="fw-bold m-0 mt-1">BackupBear</h5>
        </div>
        <button class="nav-btn active" id="btn-backup"><i class="bi bi-rocket-takeoff"></i> BACKUP</button>
        <button class="nav-btn" id="btn-excludes"><i class="bi bi-funnel"></i> EXCLUDES</button>
        <button class="nav-btn" id="btn-cloud"><i class="bi bi-cloud"></i> CLOUD / EXPLORE</button>
        <button class="nav-btn" id="btn-restore"><i class="bi bi-arrow-counterclockwise"></i> RESTORE</button>
        <button class="nav-btn" id="btn-schedule"><i class="bi bi-clock"></i> SCHEDULE</button>
        <button class="nav-btn" id="btn-about"><i class="bi bi-info-circle"></i> ABOUT</button>
        <div class="mt-auto pt-3 border-top border-secondary border-opacity-25 small position-absolute bottom-0 mb-3 text-secondary" style="font-size:0.75rem;">
            v13.6.0<br>System Ready
        </div>
    </div>

    <div class="content">
        <div id="view-backup" class="view-section active">
            <h2 class="mb-3 fw-bold">System Backup</h2>
            <div class="row mb-3 gx-3">
                <div class="col-6">
                    <div class="card h-100 mb-0 border-secondary">
                        <div class="card-header d-flex justify-content-between align-items-center">
                            <span>1. Sources (What)</span>
                            <div class="btn-group">
                                <button class="btn btn-sm btn-outline-info" title="Add Home Folder" onclick="addHome()"><i class="bi bi-house-door-fill"></i></button>
                                <button class="btn btn-sm btn-outline-danger" title="Add Entire System (Root)" onclick="addRoot()"><i class="bi bi-hdd-network-fill"></i></button>
                                <button class="btn btn-sm btn-outline-light" title="Add Specific Folder" onclick="addSourceLocal()"><i class="bi bi-folder-plus"></i></button>
                            </div>
                        </div>
                        <div class="card-body p-2">
                            <div id="source-container" class="dest-list"></div>
                        </div>
                    </div>
                </div>
                <div class="col-6">
                    <div class="card h-100 mb-0 border-secondary">
                        <div class="card-header d-flex justify-content-between align-items-center">
                            <span>2. Destinations (Where)</span>
                            <div>
                                <button class="btn btn-sm btn-outline-light me-1" onclick="addLocal()">+ LOCAL</button>
                                <button class="btn btn-sm btn-outline-warning" onclick="promptCloud()">+ CLOUD</button>
                            </div>
                        </div>
                        <div class="card-body p-2">
                            <div id="dest-container" class="dest-list"></div>
                        </div>
                    </div>
                </div>
            </div>
            <div class="card p-3 mb-3 border-secondary">
                <div class="row">
                    <div class="col-md-5">
                        <label class="small text-secondary fw-bold mb-2">3. BACKUP MODE</label>
                        <div class="btn-group w-100" role="group">
                            <input type="radio" class="btn-check" name="bkmode" id="mode-inc" checked><label class="btn btn-outline-warning btn-sm fw-bold" for="mode-inc" title="Fast">Incremental</label>
                            <input type="radio" class="btn-check" name="bkmode" id="mode-full"><label class="btn btn-outline-warning btn-sm fw-bold" for="mode-full" title="History">Snapshot</label>
                        </div>
                    </div>
                    <div class="col-md-7">
                        <label class="small text-secondary fw-bold mb-2">4. ENCRYPTION</label>
                        <div class="input-group input-group-sm mb-1">
                            <div class="input-group-text bg-dark border-secondary"><input class="form-check-input mt-0" type="checkbox" id="bak-enc"></div>
                            <input type="password" id="bak-key" class="form-control" placeholder="Passphrase" disabled>
                            <input type="password" id="bak-key-confirm" class="form-control" placeholder="Confirm" disabled>
                        </div>
                        <div id="pw-status" class="small fw-bold" style="font-size: 0.75rem; height: 16px;"></div>
                    </div>
                </div>
            </div>
            <div class="d-flex gap-2">
                <button id="btn-run-backup" class="btn btn-warning w-100 py-2 fw-bold fs-6">START BATCH BACKUP</button>
                <button id="btn-stop-backup" class="btn btn-danger w-25 py-2 fw-bold fs-6" style="display:none;">STOP</button>
            </div>
        </div>

        <div id="view-excludes" class="view-section">
            <h2 class="mb-3 fw-bold">Filters & Excludes</h2>
            <div class="row gx-3">
                <div class="col-6">
                    <div class="card h-100 border-secondary">
                        <div class="card-header">System Defaults</div>
                        <div class="card-body p-2">
                            <p class="small text-secondary px-2 mb-2">These folders are skipped by default to prevent infinite loops and wasted space.</p>
                            <div id="sys-excludes-container" class="ex-list"></div>
                        </div>
                    </div>
                </div>
                <div class="col-6">
                    <div class="card h-100 border-secondary">
                        <div class="card-header">Custom Rules & Extensions</div>
                        <div class="card-body p-2">
                            <div class="input-group input-group-sm mb-2">
                                <input type="text" id="custom-exclude-input" class="form-control" placeholder="e.g. *.mp4 or /home/user/Downloads/**">
                                <button class="btn btn-warning fw-bold" onclick="addCustomExclude()">ADD</button>
                            </div>
                            <div class="small text-secondary mb-2 px-1">Use <code class="text-warning">*.ext</code> for files, <code class="text-warning">/path/**</code> for folders.</div>
                            <div id="custom-excludes-container" class="ex-list" style="max-height: 185px;"></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div id="view-cloud" class="view-section">
            <h2 class="mb-3 fw-bold">Cloud & Explorer</h2>
            <div class="row mb-3 gx-3">
                <div class="col-md-6">
                    <div class="card p-3 h-100 mb-0 border-secondary"><h6 class="text-white fs-6">Add Google Drive</h6><input id="g-name" class="form-control form-control-sm mb-3" placeholder="user@gmail.com"><button id="btn-g-auth" class="btn btn-primary btn-sm w-100">Authenticate</button></div>
                </div>
                <div class="col-md-6">
                    <div class="card p-3 h-100 mb-0 border-secondary"><h6 class="text-white fs-6">Add Nextcloud</h6><input id="n-url" class="form-control form-control-sm mb-2" placeholder="URL"><input id="n-user" class="form-control form-control-sm mb-2" placeholder="User"><input id="n-pass" type="password" class="form-control form-control-sm mb-2" placeholder="Pass"><button id="btn-n-auth" class="btn btn-info btn-sm w-100">Connect</button></div>
                </div>
            </div>
            <div class="card mb-0 border-secondary">
                <div class="card-header">Cloud Explorer</div>
                <div class="card-body p-2">
                    <div id="cloud-tabs" class="cloud-tabs"><span class="text-secondary small py-1">Add remote to browse...</span></div>
                    <div id="file-view" class="file-grid"></div>
                </div>
            </div>
        </div>

        <div id="view-restore" class="view-section">
            <h2 class="mb-3 fw-bold">Restore</h2>
            <div class="card p-3 border-secondary" id="drop-zone-restore">
                <div class="input-group input-group-sm mb-3"><input type="text" id="res-src" class="form-control" placeholder="/path/to/source"><button id="btn-browse-restore" class="btn btn-secondary">BROWSE</button></div>
                <button id="btn-run-restore" class="btn btn-danger w-100 py-2 fw-bold">START RESTORE</button>
            </div>
        </div>
        
        <div id="view-schedule" class="view-section">
            <h2 class="mb-3 fw-bold">Automation</h2>
            <div class="card p-3 border-secondary"><select id="cron-freq" class="form-select form-select-sm w-25 mb-3 form-control"><option>Daily</option><option>Weekly</option></select><button id="btn-save-cron" class="btn btn-primary btn-sm px-4 py-2 fw-bold">SAVE SCHEDULE</button></div>
        </div>

        <div id="view-about" class="view-section text-center">
            <div style="margin-top: 20px;">
                <img src="logo.png" class="hero-logo" onerror="this.src='logo.svg'">
                <h2 class="fw-bold mb-1">Aureus The SpaceBearTaur</h2>
                <p class="text-secondary mb-4">BackupBear Edition</p>
                <div class="card d-inline-block p-3 text-start border-secondary" style="min-width: 250px;">
                    <div class="mb-2"><span class="text-secondary fw-bold small">VERSION</span><br><span class="fw-bold text-white fs-6">13.6.0</span></div>
                    <div class="mb-2"><span class="text-secondary fw-bold small">BUILD DATE</span><br><span class="font-monospace text-warning fs-6">2026-02-21</span></div>
                    <div><span class="text-secondary fw-bold small">ENGINE</span><br><span class="font-monospace text-white fs-6">Electron + Rclone + Rsync</span></div>
                </div>
            </div>
        </div>

        <div id="metrics-panel" class="card mt-auto p-3 border-secondary" style="margin-top: 20px; margin-bottom: 0;">
             <div class="row text-center align-items-center">
                <div class="col-3"><span class="metric-lbl">SPEED</span><div class="metric-val" id="val-spd">--</div></div>
                <div class="col-3"><span class="metric-lbl">ETA</span><div class="metric-val" id="val-eta">--</div></div>
                <div class="col-6 text-start">
                    <span class="metric-lbl">LOGS</span>
                    <div id="val-raw" class="text-white small mt-1 text-truncate font-monospace" style="opacity:0.7; font-size:0.75rem;">System Ready</div>
                </div>
             </div>
             <div class="row mt-2">
                 <div class="col-12">
                     <button id="btn-toggle-term" class="btn btn-outline-secondary btn-sm w-100" style="font-size: 0.75rem; border-color: #444;"><i class="bi bi-terminal"></i> Show Live Terminal</button>
                     <div id="live-terminal-container" style="display: none; margin-top: 5px;">
                         <pre id="live-terminal" class="bg-black text-success p-2 rounded text-start m-0" style="height: 100px; overflow-y: auto; font-family: 'JetBrains Mono', monospace; font-size: 0.7rem; border: 1px solid #333; white-space: pre-wrap; word-wrap: break-word;"></pre>
                     </div>
                 </div>
             </div>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="renderer.js"></script>
</body>
</html>
EOF

# 6. RENDERER
cat <<'EOF' > renderer.js
let destinations = [];
let sources = [];
let excludes = [
    { pattern: '/proc/**', enabled: true, sys: true, label: 'System Procs (/proc)' },
    { pattern: '/sys/**', enabled: true, sys: true, label: 'Devices (/sys)' },
    { pattern: '/dev/**', enabled: true, sys: true, label: 'Hardware (/dev)' },
    { pattern: '/run/**', enabled: true, sys: true, label: 'Runtime (/run)' },
    { pattern: '/tmp/**', enabled: true, sys: true, label: 'Temp Files (/tmp)' },
    { pattern: '/mnt/**', enabled: true, sys: true, label: 'Mounts (/mnt)' },
    { pattern: '/media/**', enabled: true, sys: true, label: 'Media (/media)' },
    { pattern: '/lost+found/**', enabled: true, sys: true, label: 'Lost+Found' },
    { pattern: '.cache/**', enabled: false, sys: true, label: 'App Caches (.cache)' },
    { pattern: '.Trash-*/**', enabled: true, sys: true, label: 'Trash Bins' }
];

let termVisible = false;

async function checkDependencies() {
    const status = await window.bear.invoke('check-deps');
    if (!status.ok) {
        document.getElementById('dep-cmd').innerText = status.installCmd;
        document.getElementById('dep-overlay').style.display = 'flex';
    }
}
checkDependencies();

window.bear.getHome().then(homePath => {
    sources.push({ type: 'home', path: homePath, enabled: true });
    renderSources();
});

const views = ['backup', 'excludes', 'cloud', 'restore', 'schedule', 'about'];
views.forEach(v => {
    document.getElementById(`btn-${v}`).addEventListener('click', () => switchView(v));
});

function switchView(viewName) {
    document.querySelectorAll('.view-section').forEach(el => el.classList.remove('active'));
    document.getElementById(`view-${viewName}`).classList.add('active');
    document.querySelectorAll('.nav-btn').forEach(el => el.classList.remove('active'));
    document.getElementById(`btn-${viewName}`).classList.add('active');
    
    const metrics = document.getElementById('metrics-panel');
    if(metrics) {
        metrics.style.display = (viewName === 'backup' || viewName === 'restore' || viewName === 'excludes') ? 'block' : 'none';
    }

    if (viewName === 'cloud') loadRemotes();
}

document.getElementById('btn-toggle-term').addEventListener('click', () => {
    termVisible = !termVisible;
    document.getElementById('live-terminal-container').style.display = termVisible ? 'block' : 'none';
    document.getElementById('btn-toggle-term').innerHTML = termVisible ? '<i class="bi bi-terminal-dash"></i> Hide Live Terminal' : '<i class="bi bi-terminal"></i> Show Live Terminal';
    if (termVisible) { const term = document.getElementById('live-terminal'); term.scrollTop = term.scrollHeight; }
});

// --- EXCLUDES LOGIC ---
function renderExcludes() {
    const sysContainer = document.getElementById('sys-excludes-container');
    const custContainer = document.getElementById('custom-excludes-container');
    
    sysContainer.innerHTML = excludes.filter(e => e.sys).map((e, i) => `
        <div class="dest-item py-1">
            <i class="bi bi-shield-lock text-secondary me-2"></i>
            <div class="dest-path text-white">${e.label}</div>
            <input type="checkbox" class="dest-check" ${e.enabled ? 'checked' : ''} onchange="toggleExclude(${excludes.indexOf(e)})">
        </div>`).join('');
        
    const customs = excludes.filter(e => !e.sys);
    if(customs.length === 0) {
        custContainer.innerHTML = '<div class="p-2 text-center text-secondary small">No custom rules yet.</div>';
    } else {
        custContainer.innerHTML = customs.map((e, i) => `
            <div class="dest-item py-1">
                <i class="bi bi-file-earmark-x text-warning me-2"></i>
                <div class="dest-path text-white font-monospace">${e.pattern}</div>
                <input type="checkbox" class="dest-check" ${e.enabled ? 'checked' : ''} onchange="toggleExclude(${excludes.indexOf(e)})">
                <button class="btn btn-sm text-danger ms-2 p-0 px-1" onclick="removeExclude(${excludes.indexOf(e)})"><i class="bi bi-x-lg"></i></button>
            </div>`).join('');
    }
}
window.toggleExclude = (i) => { excludes[i].enabled = !excludes[i].enabled; };
window.removeExclude = (i) => { excludes.splice(i, 1); renderExcludes(); };
window.addCustomExclude = () => {
    const input = document.getElementById('custom-exclude-input');
    const val = input.value.trim();
    if(val && !excludes.find(e => e.pattern === val)) {
        excludes.push({ pattern: val, enabled: true, sys: false });
        input.value = '';
        renderExcludes();
    }
};
renderExcludes();

// --- SOURCES LOGIC ---
async function addSourceLocal() {
    const path = await window.bear.invoke('dialog:open');
    if (path && !sources.find(s => s.path === path)) { sources.push({ type: 'folder', path: path, enabled: true }); renderSources(); }
}
async function addHome() {
    const homePath = await window.bear.getHome();
    if (!sources.find(s => s.path === homePath)) { sources.push({ type: 'home', path: homePath, enabled: true }); renderSources(); }
}
function addRoot() {
    if (!sources.find(s => s.path === '/')) { sources.push({ type: 'system', path: '/', enabled: true }); renderSources(); }
}
function renderSources() {
    const container = document.getElementById('source-container');
    if (sources.length === 0) { container.innerHTML = '<div class="p-3 text-center text-secondary small">Click buttons above<br>to add sources</div>'; return; }
    container.innerHTML = sources.map((s, i) => `
        <div class="dest-item">
            <i class="bi ${s.path === '/' ? 'bi-hdd-network-fill text-danger' : s.type === 'home' ? 'bi-house-door-fill text-info' : 'bi-folder-fill'} dest-icon"></i>
            <div class="dest-path text-white" title="${s.path}">${s.path}</div>
            <input type="checkbox" class="dest-check" ${s.enabled ? 'checked' : ''} onchange="toggleSrc(${i})">
            <button class="btn btn-sm text-danger ms-2 p-0 px-1" onclick="removeSrc(${i})"><i class="bi bi-x-lg"></i></button>
        </div>`).join('');
}
window.toggleSrc = (i) => { sources[i].enabled = !sources[i].enabled; };
window.removeSrc = (i) => { sources.splice(i, 1); renderSources(); };


// --- DESTINATIONS LOGIC ---
document.getElementById('btn-add-local').addEventListener('click', async () => {
    const path = await window.bear.invoke('dialog:open');
    if (path && !destinations.find(d => d.path === path)) { destinations.push({ type: 'local', path: path, enabled: true }); renderDestinations(); }
});
document.getElementById('btn-prompt-cloud').addEventListener('click', async () => {
    const remotes = await window.bear.invoke('rclone-list');
    const sel = document.getElementById('modal-cloud-list');
    sel.innerHTML = remotes.map(r => `<option value="${r}">${r}</option>`).join('');
    new bootstrap.Modal(document.getElementById('cloudModal')).show();
});
document.getElementById('btn-confirm-cloud').addEventListener('click', () => {
    const val = document.getElementById('modal-cloud-list').value;
    if (val && !destinations.find(d => d.path === val)) { destinations.push({ type: 'cloud', path: val, enabled: true }); renderDestinations(); bootstrap.Modal.getInstance(document.getElementById('cloudModal')).hide(); }
});

function renderDestinations() {
    const container = document.getElementById('dest-container');
    if (destinations.length === 0) { container.innerHTML = '<div class="p-3 text-center text-secondary small">Click buttons above<br>to add destinations</div>'; return; }
    container.innerHTML = destinations.map((d, i) => `
        <div class="dest-item">
            <i class="bi ${d.type === 'cloud' ? 'bi-cloud-fill' : 'bi-hdd-fill'} dest-icon"></i>
            <div class="dest-path text-white" title="${d.path}">${d.path}</div>
            <input type="checkbox" class="dest-check" ${d.enabled ? 'checked' : ''} onchange="toggleDest(${i})">
            <button class="btn btn-sm text-danger ms-2 p-0 px-1" onclick="removeDest(${i})"><i class="bi bi-x-lg"></i></button>
        </div>`).join('');
}
window.toggleDest = (i) => { destinations[i].enabled = !destinations[i].enabled; };
window.removeDest = (i) => { destinations.splice(i, 1); renderDestinations(); };

// --- PASSWORD LOGIC ---
const pwInput = document.getElementById('bak-key');
const pwConfirm = document.getElementById('bak-key-confirm');
const pwStatus = document.getElementById('pw-status');
function checkPasswordStrength(pwd) {
    if (pwd.length < 8) return { weak: true, reason: "Too short (must be at least 8 characters)." };
    if (/^[a-zA-Z]+$/.test(pwd)) return { weak: true, reason: "Contains only letters (plain words are easily cracked)." };
    if (/^[0-9]+$/.test(pwd)) return { weak: true, reason: "Contains only numbers." };
    if (!/[^a-zA-Z0-9]/.test(pwd) && pwd.length < 12) return { weak: true, reason: "Missing special characters or numbers." };
    return { weak: false };
}
function validatePasswords() {
    if (!document.getElementById('bak-enc').checked) {
        pwInput.classList.remove('is-valid', 'is-invalid'); pwConfirm.classList.remove('is-valid', 'is-invalid');
        pwStatus.innerHTML = ''; return;
    }
    const val1 = pwInput.value; const val2 = pwConfirm.value;
    if (val1 === '' && val2 === '') { pwInput.classList.remove('is-valid', 'is-invalid'); pwConfirm.classList.remove('is-valid', 'is-invalid'); pwStatus.innerHTML = ''; return; }
    if (val1 === val2 && val1.length > 0) {
        pwInput.classList.remove('is-invalid'); pwConfirm.classList.remove('is-invalid');
        pwInput.classList.add('is-valid'); pwConfirm.classList.add('is-valid');
        pwStatus.innerHTML = '<span class="text-success"><i class="bi bi-check-circle-fill"></i> Passphrases match</span>';
    } else {
        pwInput.classList.remove('is-valid'); pwConfirm.classList.remove('is-valid');
        if (val2.length > 0) { pwConfirm.classList.add('is-invalid'); pwStatus.innerHTML = '<span class="text-danger"><i class="bi bi-x-circle-fill"></i> Do not match</span>'; } 
        else { pwConfirm.classList.remove('is-invalid'); pwStatus.innerHTML = ''; }
    }
}
pwInput.addEventListener('input', validatePasswords);
pwConfirm.addEventListener('input', validatePasswords);
document.getElementById('bak-enc').addEventListener('change', (e) => {
    pwInput.disabled = !e.target.checked; pwConfirm.disabled = !e.target.checked;
    if(!e.target.checked) { pwInput.value = ''; pwConfirm.value = ''; }
    validatePasswords();
});

// --- BACKUP EXECUTION ---
function executeBackup(sources, destinations, encrypt, key, mode) {
    document.getElementById('btn-run-backup').style.display = 'none';
    document.getElementById('btn-stop-backup').style.display = 'block';
    document.getElementById('live-terminal').textContent = ''; 
    
    // Extract active exclude strings to send to backend
    const activeExcludes = excludes.filter(e => e.enabled).map(e => e.pattern);
    
    window.bear.send('start-backup-batch', { sources, destinations, encrypt, key, mode, excludes: activeExcludes });
}

document.getElementById('btn-run-backup').addEventListener('click', () => {
    if (sources.filter(s => s.enabled).length === 0) return alert("Select at least one Source!");
    if (destinations.filter(d => d.enabled).length === 0) return alert("Select at least one Destination!");
    
    const encrypt = document.getElementById('bak-enc').checked;
    const key = pwInput.value;
    const mode = document.getElementById('mode-full').checked ? 'full' : 'inc';
    
    if (encrypt) {
        if(!key) return alert("Enter a passphrase");
        if(key !== pwConfirm.value) return alert("Passphrases do not match!");
        const strength = checkPasswordStrength(key);
        if(strength.weak) {
            document.getElementById('weak-reason').innerText = "Issue: " + strength.reason;
            new bootstrap.Modal(document.getElementById('weakPwModal')).show();
            return;
        }
    }
    executeBackup(sources, destinations, encrypt, key, mode);
});

document.getElementById('btn-force-backup').addEventListener('click', () => {
    bootstrap.Modal.getInstance(document.getElementById('weakPwModal')).hide();
    const mode = document.getElementById('mode-full').checked ? 'full' : 'inc';
    executeBackup(sources, destinations, true, pwInput.value, mode);
});

document.getElementById('btn-stop-backup').addEventListener('click', () => { window.bear.send('stop-task'); });

// --- CLOUD EXPLORER ---
async function loadRemotes() {
    const remotes = await window.bear.invoke('rclone-list');
    const tabContainer = document.getElementById('cloud-tabs');
    if (remotes.length === 0) { tabContainer.innerHTML = '<span class="text-secondary small py-2">No remotes found. Add one above.</span>'; } 
    else { tabContainer.innerHTML = remotes.map(r => `<div class="cloud-tab" onclick="openRemote('${r}', this)">${r}</div>`).join(''); }
}
window.openRemote = async (remote, tabEl) => {
    document.querySelectorAll('.cloud-tab').forEach(t => t.classList.remove('active')); tabEl.classList.add('active');
    const grid = document.getElementById('file-view'); grid.innerHTML = '<div class="text-warning p-3">Loading files...</div>';
    const files = await window.bear.invoke('rclone-ls', remote);
    if (files.length === 0) { grid.innerHTML = '<div class="text-secondary p-3">Folder is empty.</div>'; return; }
    grid.innerHTML = files.map(f => `<div class="file-item ${f.IsDir ? 'is-dir' : ''}"><i class="bi ${f.IsDir ? 'bi-folder-fill' : 'bi-file-earmark-text'} file-icon"></i><div class="file-name" title="${f.Name}">${f.Name}</div></div>`).join('');
};
document.getElementById('btn-g-auth').addEventListener('click', async () => {
    const name = document.getElementById('g-name').value; if (!name) return alert("Enter Email");
    document.getElementById('auth-overlay').style.display = 'flex';
    const res = await window.bear.invoke('rclone-auth-drive', name);
    document.getElementById('auth-overlay').style.display = 'none';
    if (res === "Success") { showSuccess('btn-g-auth', "Linked!"); document.getElementById('g-name').value = ""; loadRemotes(); } else alert(res);
});
document.getElementById('btn-n-auth').addEventListener('click', async () => {
    const user = document.getElementById('n-user').value; if (!user) return alert("Enter Username");
    const autoName = "Nextcloud_" + user.replace(/[^a-zA-Z0-9]/g, "");
    const res = await window.bear.invoke('rclone-auth-nextcloud', { name: autoName, url: document.getElementById('n-url').value, user: user, pass: document.getElementById('n-pass').value });
    if (res === "Success") { showSuccess('btn-n-auth', "Connected!"); loadRemotes(); } else alert(res);
});
document.getElementById('btn-cancel-auth').addEventListener('click', () => { document.getElementById('auth-overlay').style.display = 'none'; });

function showSuccess(btnId, msg) {
    const btn = document.getElementById(btnId); const originalText = btn.innerText; const originalClass = btn.className;
    btn.className = "btn btn-success w-100 fw-bold py-2 fs-6"; btn.innerText = "✓ " + msg;
    setTimeout(() => { btn.className = originalClass; btn.innerText = originalText; }, 3000);
}

// --- EVENTS ---
window.bear.on('progress', (data) => {
    document.getElementById('val-spd').innerText = data.speed; document.getElementById('val-eta').innerText = data.eta; document.getElementById('val-raw').innerText = data.raw;
    if (data.fullRaw) {
        const term = document.getElementById('live-terminal');
        term.textContent += data.fullRaw + '\n';
        if (termVisible) term.scrollTop = term.scrollHeight; 
    }
});
window.bear.on('done', (msg) => {
    document.getElementById('btn-run-backup').style.display = 'block'; document.getElementById('btn-stop-backup').style.display = 'none';
    if (msg.includes("Complete") || msg.includes("Stopped")) showSuccess('btn-run-backup', msg); else alert(msg);
});

switchView('backup');
EOF

echo ""
echo "✅ BackupBear 13.6.0 Built."
echo "🚀 Starting App..."
npm start
