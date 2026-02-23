#!/bin/bash
# BackupBear Master Packager 14.1.69: The Ultimate Edition

set -e

# Run directly in the folder the user executed the script from
APP_DIR="$(pwd)"
cd "$APP_DIR"

echo "🐻 BackupBear 14.1.69 Compiler & Packager"
echo "========================================="

echo "🧹 Cleaning old builds..."
rm -rf dist build

echo "🖼️  Setting up Linux desktop icon resources..."
mkdir -p build/icons

if [ -f "aureus-logo.png" ]; then
    cp "aureus-logo.png" "logo.png"
elif [ -f "$HOME/aureus-logo.png" ]; then
    cp "$HOME/aureus-logo.png" "logo.png"
fi

# BULLETPROOF FALLBACK: Generate an emergency icon if missing so the compiler doesn't crash
if [ ! -f "logo.png" ]; then
    echo "⚠️ Custom logo not found! Generating safe fallback icon..."
    echo "iVBORw0KGgoAAAANSUhEUgAAAgAAAAIAAQMAAADOtka5AAAAA1BMVEV/wP/7RtjOAAAANklEQVR4nO3BAQEAIAADscD+PxgQ2wAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACA2wANsAAB8v9oKAAAAABJRU5ErkJggg==" | base64 -d > "logo.png"
fi

if command -v magick &> /dev/null; then 
    magick "logo.png" -resize 512x512 "build/icons/512x512.png" || cp "logo.png" "build/icons/512x512.png"
elif command -v convert &> /dev/null; then 
    convert "logo.png" -resize 512x512 "build/icons/512x512.png" || cp "logo.png" "build/icons/512x512.png"
else
    cp "logo.png" "build/icons/512x512.png"
fi
cp "build/icons/512x512.png" "build/icon.png"

echo "📝 Writing Backend (main.js)..."
cat <<'EOF' > main.js
const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const { spawn, exec, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

let mainWindow;
let activeProcess = null;

const configPath = path.join(os.homedir(), '.config', 'backupbear');
const scheduleFile = path.join(configPath, 'schedule.json');

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1100, height: 800,
        minWidth: 900, minHeight: 650,
        resizable: true,
        backgroundColor: '#121212',
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            preload: path.join(__dirname, 'preload.js')
        },
        autoHideMenuBar: false,
        title: "BackupBear 14.1.69",
        icon: path.join(__dirname, 'logo.png')
    });
    
    mainWindow.webContents.on('before-input-event', (event, input) => {
        if (input.key === 'F12' && input.type === 'keyDown') mainWindow.webContents.toggleDevTools();
    });

    mainWindow.loadFile('index.html');
}
app.whenReady().then(createWindow);

ipcMain.handle('get-home', () => os.homedir());

ipcMain.handle('check-deps', async () => {
    const checkCmd = (cmd) => { try { execSync(`command -v ${cmd}`); return true; } catch { return false; } };
    const hasRclone = checkCmd('rclone'); 
    const hasRsync = checkCmd('rsync');
    const hasCron = checkCmd('crontab');
    const hasTar = checkCmd('tar');
    
    let missing = [];
    if (!hasRclone) missing.push('rclone');
    if (!hasRsync) missing.push('rsync');
    if (!hasCron) missing.push('cron');
    if (!hasTar) missing.push('tar');
    
    let installCmd = 'sudo apt install rclone rsync cron tar';
    if (checkCmd('pacman')) installCmd = 'sudo pacman -S rclone rsync cronie tar && sudo systemctl enable --now cronie.service';
    else if (checkCmd('dnf')) installCmd = 'sudo dnf install rclone rsync cronie tar && sudo systemctl enable --now crond.service';
    
    return { ok: missing.length === 0, missing, installCmd };
});

ipcMain.handle('get-schedule', () => {
    try { if (fs.existsSync(scheduleFile)) return JSON.parse(fs.readFileSync(scheduleFile)); } catch (e) {}
    return { active: false };
});

ipcMain.handle('save-schedule', (e, payload) => {
    try {
        const { sched, sources, destinations, encrypt, key, mode, excludes, comp } = payload;
        
        if (!fs.existsSync(configPath)) fs.mkdirSync(configPath, { recursive: true });
        fs.writeFileSync(scheduleFile, JSON.stringify(sched, null, 2));

        const runnerScript = path.join(configPath, 'runner.sh');
        const tempCron = path.join(configPath, 'tempcron');

        let currentCron = "";
        try { currentCron = execSync('crontab -l 2>/dev/null').toString(); } catch(err) {}
        
        let filteredCron = currentCron.split('\n')
            .filter(line => line.trim() !== '' && !line.includes('BackupBear_Cron') && !line.includes('no crontab'))
            .join('\n');

        if (filteredCron.length > 0) filteredCron += '\n';
        fs.writeFileSync(tempCron, filteredCron);

        if (!sched.active) {
            execSync(`crontab "${tempCron}"`);
            return { success: true };
        }

        let script = `#!/bin/bash\nexport DISPLAY=:0\nexport DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus\n\nLOG="${sched.logEnabled ? sched.logPath : '/dev/null'}"\n\necho "=====================================" >> "$LOG"\necho "🐻 BackupBear Scheduled Run: $(date)" >> "$LOG"\nnotify-send "BackupBear" "Scheduled backup started..." -u normal || true\n\n`;

        const excludeString = excludes.map(ex => `--exclude '${ex}'`).join(' ');

        for (const dest of destinations) {
            if (!dest.enabled) continue;

            if (comp === 'archive') {
                let baseDest = dest.path.includes(':') ? `${dest.path}:Backup_$(date +%Y-%m-%d_%H-%M).tar.gz` : path.join(dest.path, `Backup_$(date +%Y-%m-%d_%H-%M).tar.gz`);
                const srcPaths = sources.filter(s => s.enabled).map(s => `'${s.path}'`).join(' ');

                script += `echo "[Archiving] ${srcPaths} -> ${baseDest}" >> "$LOG"\n`;
                let cmd = "";
                if (dest.type === 'cloud' || (encrypt && key)) {
                    let rcloneCmd = `tar -czf - ${excludeString} ${srcPaths} | rclone rcat '${baseDest}'`;
                    if (encrypt && key) {
                        try {
                            const obs = execSync(`rclone obscure '${key}'`).toString().trim();
                            cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${baseDest}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rcloneCmd.replace(baseDest, 'T:')}`;
                        } catch { cmd = `echo "Key Encryption Error" >> "$LOG"`; }
                    } else { cmd = rcloneCmd; }
                } else {
                    cmd = `tar -czvf '${baseDest}' ${excludeString} ${srcPaths}`;
                }
                script += `${cmd} >> "$LOG" 2>&1\n\n`;

            } else {
                let baseDest = dest.path;
                if (mode === 'full') {
                    baseDest = dest.path.includes(':') ? `${dest.path}:$(date +%Y-%m-%d_%H-%M)` : path.join(dest.path, `Backup_$(date +%Y-%m-%d_%H-%M)`);
                } else if (dest.type === 'cloud' && !dest.path.includes(':')) {
                    baseDest = `${dest.path}:Backup`;
                }

                for (const src of sources) {
                    if (!src.enabled) continue;
                    
                    let finalDest = baseDest;
                    if (src.path !== '/') {
                        const relativeSrc = src.path.replace(/^\/+/, '');
                        if (finalDest.includes(':')) finalDest = finalDest.endsWith('/') ? finalDest + relativeSrc : finalDest + '/' + relativeSrc;
                        else {
                            finalDest = path.join(finalDest, relativeSrc);
                            script += `mkdir -p "${finalDest}"\n`;
                        }
                    } else {
                        if (!finalDest.includes(':')) script += `mkdir -p "${finalDest}"\n`;
                    }

                    let cleanSrc = src.path.endsWith('/') ? src.path : src.path + '/';
                    script += `echo "[Syncing] ${cleanSrc} -> ${finalDest}" >> "$LOG"\n`;

                    let cmd = "";
                    if (dest.type === 'cloud' || (encrypt && key)) {
                        let rcloneCmd = `rclone sync '${cleanSrc}' '${finalDest}' -v ${excludeString}`;
                        if (encrypt && key) {
                            try {
                                const obs = execSync(`rclone obscure '${key}'`).toString().trim();
                                cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${finalDest}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rcloneCmd.replace(finalDest, 'T:')}`;
                            } catch { cmd = `echo "Key Encryption Error" >> "$LOG"`; }
                        } else { cmd = rcloneCmd; }
                    } else {
                        let flags = mode === 'full' ? "-aAXx" : "-aAXx --delete"; 
                        if (comp === 'transfer') flags += "z";
                        cmd = `rsync ${flags} ${excludeString} '${cleanSrc}' '${finalDest}/'`;
                    }
                    
                    script += `${cmd} >> "$LOG" 2>&1\n\n`;
                }
            }
        }

        script += `notify-send "BackupBear" "Scheduled backup completed!" -u normal || true\necho "Finished: $(date)" >> "$LOG"\n`;
        fs.writeFileSync(runnerScript, script, { mode: 0o755 });

        const [hr, min] = sched.time.split(':');
        let cronExp = '';
        if (sched.freq === 'daily') cronExp = `${min} ${hr} * * *`;
        else if (sched.freq === 'weekly') cronExp = `${min} ${hr} * * ${sched.day}`;
        else if (sched.freq === 'monthly') cronExp = `${min} ${hr} ${sched.day} * *`;

        const newCronLine = `${cronExp} "${runnerScript}" # BackupBear_Cron\n`;
        fs.appendFileSync(tempCron, newCronLine);
        execSync(`crontab "${tempCron}"`);
        
        return { success: true };
    } catch (e) { 
        console.error(e); 
        return { success: false, error: e.message }; 
    }
});

ipcMain.handle('dialog:open', async () => { const r = await dialog.showOpenDialog(mainWindow, {properties:['openDirectory']}); return r.canceled ? null : r.filePaths[0]; });
ipcMain.handle('dialog:save', async (e, defaultPath) => { const r = await dialog.showSaveDialog(mainWindow, {defaultPath}); return r.canceled ? null : r.filePath; });

ipcMain.handle('rclone-list', async () => new Promise(resolve => exec('rclone listremotes', (e, out) => resolve(e ? [] : out.split('\n').filter(r => r.trim()).map(r => r.replace(':', ''))))));
ipcMain.handle('rclone-ls', async (e, remote) => new Promise(resolve => exec(`rclone lsjson "${remote}:" --max-depth 1`, (err, out) => { try { const f = JSON.parse(out); f.sort((a,b) => (b.IsDir===a.IsDir)?0:b.IsDir?1:-1); resolve(f); } catch { resolve([]); } })));
ipcMain.handle('rclone-auth-drive', async (e, name) => new Promise(resolve => { const proc = spawn('rclone', ['authorize', 'drive']); let buf = ''; proc.stdout.on('data', d => buf += d.toString()); proc.on('close', code => { if(code !== 0) return resolve("Auth Failed"); const match = buf.match(/\{.*\}/); if(!match) return resolve("No Token"); try { const cfgDir = path.join(os.homedir(), '.config', 'rclone'); if(!fs.existsSync(cfgDir)) fs.mkdirSync(cfgDir, {recursive:true}); fs.appendFileSync(path.join(cfgDir, 'rclone.conf'), `\n[${name}]\ntype = drive\nscope = drive\ntoken = ${match[0]}\n`); resolve("Success"); } catch(e) { resolve("File Error: " + e.message); } }); }));
ipcMain.handle('rclone-auth-nextcloud', async (e, args) => new Promise(resolve => { exec(`rclone obscure '${args.pass}'`, (err, out) => { if(err) return resolve("Engine Error: rclone missing"); exec(`rclone config create "${args.name}" nextcloud url="${args.url}" user="${args.user}" pass="${out.trim()}"`, e => resolve(e ? "Failed" : "Success")); }); }));

ipcMain.on('stop-task', () => { if(activeProcess) { activeProcess.kill(); activeProcess=null; if(!mainWindow.isDestroyed()) mainWindow.webContents.send('done', "Stopped"); }});

ipcMain.on('start-backup-batch', async (e, args) => {
    const { sources, destinations, encrypt, key, mode, excludes, comp } = args;
    const now = new Date();
    const stamp = now.toISOString().replace(/T/,'_').replace(/:/g,'-').slice(0,16);
    const excludeString = excludes.map(ex => `--exclude '${ex}'`).join(' ');

    for (const dest of destinations) {
        if (!dest.enabled) continue;
        if (activeProcess === "STOPPED") break;
        
        if (comp === 'archive') {
            let baseDest = dest.path.includes(':') ? `${dest.path}:Backup_${stamp}.tar.gz` : path.join(dest.path, `Backup_${stamp}.tar.gz`);
            const srcPaths = sources.filter(s => s.enabled).map(s => `'${s.path}'`).join(' ');
            
            if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `Archiving to ${baseDest}...`, fullRaw: `\n[SYSTEM] Starting Archive -> ${baseDest}`, pct: "0%", speed: "--", eta: "--" });
            
            await new Promise(resolve => {
                let cmd = "";
                if (dest.type === 'cloud' || (encrypt && key)) {
                    let rcloneCmd = `tar -czf - ${excludeString} ${srcPaths} | rclone rcat '${baseDest}'`;
                    if (encrypt && key) {
                        try {
                            const obs = execSync(`rclone obscure '${key}'`).toString().trim();
                            cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${baseDest}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rcloneCmd.replace(baseDest, 'T:')}`;
                        } catch { cmd = "echo 'Key Error'"; }
                    } else { cmd = rcloneCmd; }
                } else {
                    cmd = `tar -czvf '${baseDest}' ${excludeString} ${srcPaths}`;
                }
                
                // Add --noprofile --norc to suppress fastfetch
                const proc = spawn('/bin/bash', ['--noprofile', '--norc', '-c', cmd]);
                proc.on('error', (err) => {
                    if(mainWindow.isDestroyed()) return;
                    mainWindow.webContents.send('progress', { raw: `Engine Error`, fullRaw: err.toString(), pct: "ERR", speed: "--", eta: "--" });
                    resolve();
                });
                activeProcess = proc;
                proc.stdout.on('data', d => {
                    if(mainWindow.isDestroyed()) return;
                    const cleanString = d.toString().replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').trim();
                    mainWindow.webContents.send('progress', { raw: `[Archiving] ${cleanString.substring(0,40)}...`, fullRaw: cleanString, pct: "...", speed: "--", eta: "--" });
                });
                proc.stderr.on('data', d => {
                    if(!mainWindow.isDestroyed()) {
                        const cleanString = d.toString().replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').trim();
                        mainWindow.webContents.send('progress', { raw: `[Processing Archive Data]...`, fullRaw: cleanString, pct: "...", speed: "--", eta: "--" });
                    }
                });
                proc.on('close', () => { activeProcess=null; resolve(); });
            });

        } else {
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
                    if (finalDest.includes(':')) finalDest = finalDest.endsWith('/') ? finalDest + relativeSrc : finalDest + '/' + relativeSrc;
                    else { finalDest = path.join(finalDest, relativeSrc); fs.mkdirSync(finalDest, { recursive: true }); }
                } else {
                    if (!finalDest.includes(':') && !fs.existsSync(finalDest)) fs.mkdirSync(finalDest, { recursive: true });
                }

                let cleanSrc = src.path.endsWith('/') ? src.path : src.path + '/';
                if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `Syncing: ${srcPath}`, fullRaw: `\n[SYSTEM] Starting transfer: ${srcPath} -> ${finalDest}`, pct: "0%", speed: "--", eta: "--" });
                
                await new Promise(resolve => {
                    let cmd = "";
                    if (dest.type === 'cloud' || (encrypt && key)) {
                        let rcloneCmd = `rclone sync '${cleanSrc}' '${finalDest}' --progress --stats-one-line ${excludeString}`;
                        if (encrypt && key) {
                            try {
                                const obs = execSync(`rclone obscure '${key}'`).toString().trim();
                                cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${finalDest}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rcloneCmd.replace(finalDest, 'T:')}`;
                            } catch { cmd = "echo 'Key Error'"; }
                        } else { cmd = rcloneCmd; }
                    } else {
                        let flags = mode === 'full' ? "-aAXx" : "-aAXx --delete";
                        if (comp === 'transfer') flags += "z";
                        flags += " --info=progress2";
                        cmd = `rsync ${flags} ${excludeString} '${cleanSrc}' '${finalDest}/' | tr '\\r' '\\n'`;
                    }
                    
                    // Block fastfetch by passing --noprofile and --norc
                    const proc = spawn('/bin/bash', ['--noprofile', '--norc', '-c', cmd]);
                    proc.on('error', (err) => {
                        if(mainWindow.isDestroyed()) return;
                        mainWindow.webContents.send('progress', { raw: `Engine Error`, fullRaw: err.toString(), pct: "ERR", speed: "--", eta: "--" });
                        resolve();
                    });
                    activeProcess = proc;
                    proc.stdout.on('data', d => {
                        if(mainWindow.isDestroyed()) return;
                        const rawStr = d.toString();
                        const line = rawStr.replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').trim();
                        let spd="--", eta="--", pct="Working...";
                        
                        if((dest.type==='cloud'||encrypt) && line.match(/\d+%/)) {
                            const p = line.split(',');
                            if(p.length>2) { pct = p[0].trim().split(' ')[0] || "0%"; spd = p[2]?.trim() || "--"; let rawEta = p[3]?.trim().replace('ETA','') || "--"; eta = rawEta.split('(')[0].trim(); }
                        } else if(line.match(/\d+%/)) {
                            const p = line.split(/\s+/).filter(x=>x);
                            if(p.length>=4) { pct = p[1]; spd = p[2]; eta = p[3].split('(')[0].trim(); }
                        }
                        
                        if(line) mainWindow.webContents.send('progress', { raw: `[Sync] ${line.substring(0,50)}...`, fullRaw: rawStr.trim(), pct, speed:spd, eta });
                    });
                    proc.stderr.on('data', d => {
                        if(!mainWindow.isDestroyed()) {
                            const cleanString = d.toString().replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').trim();
                            mainWindow.webContents.send('progress', { raw: `[ERROR] Processing issue...`, fullRaw: `[ERR] ${cleanString}`, pct: "!", speed: "--", eta: "--" });
                        }
                    });
                    proc.on('close', () => { activeProcess=null; resolve(); });
                });
            }
        }
    }
    if(!mainWindow.isDestroyed()) mainWindow.webContents.send('done', "Batch Complete");
});
EOF

echo "📝 Writing Preload (preload.js)..."
cat <<'EOF' > preload.js
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('bear', {
    invoke: (channel, data) => ipcRenderer.invoke(channel, data),
    send: (channel, data) => ipcRenderer.send(channel, data),
    on: (channel, func) => ipcRenderer.on(channel, (event, ...args) => func(...args)),
    getHome: () => ipcRenderer.invoke('get-home')
});
EOF

echo "📝 Writing Interface (index.html)..."
cat <<'EOF' > index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>BackupBear 14.1.69</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700&family=JetBrains+Mono:wght@700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <style>
        :root { --bg: #000; --sidebar: #111; --card: #1a1a1a; --text: #fff; --accent: #FF9800; --border: #333; --input: #000; }
        body { background: var(--bg); color: var(--text); font-family: 'Inter', sans-serif; overflow: hidden; user-select: none; }
        
        /* THE INPUT FIX: Ensuring typing is fully unlocked */
        input, textarea, select { user-select: text !important; }

        .sidebar { height: 100vh; background: var(--sidebar); padding: 15px; width: 220px; position: fixed; border-right: 1px solid var(--border); }
        .content { margin-left: 220px; padding: 20px; height: 100vh; overflow-y: auto; overflow-x: hidden; display: flex; flex-direction: column; }
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
        <p class="text-secondary fs-6 mb-3">BackupBear requires <b class="text-white">rclone</b>, <b class="text-white">rsync</b>, <b class="text-white">tar</b>, and <b class="text-white">cron</b> to function.</p>
        <div class="card bg-dark border-secondary p-3 mb-3" style="width: 450px;">
            <div class="text-start small text-secondary mb-2 fw-bold">RUN THIS IN YOUR TERMINAL:</div>
            <code id="dep-cmd" class="text-warning fs-6 user-select-all" style="cursor: pointer;" title="Click to copy" onclick="navigator.clipboard.writeText(this.innerText); alert('Copied to clipboard!');"></code>
        </div>
        <button class="btn btn-sm btn-outline-light mt-2 px-4 py-2" onclick="window.close()">Exit BackupBear</button>
    </div>

    <div id="auth-overlay">
        <div class="spinner-border text-warning mb-3" style="width: 2.5rem; height: 2.5rem;"></div>
        <h4 class="text-white fw-bold">Authenticating...</h4>
        <button id="btn-cancel-auth" class="btn btn-sm btn-outline-secondary mt-3">Cancel</button>
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
            v14.1.69<br>System Ready
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
                                <button id="btn-add-home" class="btn btn-sm btn-outline-info" title="Add Home Folder"><i class="bi bi-house-door-fill"></i></button>
                                <button id="btn-add-root" class="btn btn-sm btn-outline-danger" title="Add Entire System (Root)"><i class="bi bi-hdd-network-fill"></i></button>
                                <button id="btn-add-source-local" class="btn btn-sm btn-outline-light" title="Add Specific Folder"><i class="bi bi-folder-plus"></i></button>
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
                                <button id="btn-add-local" class="btn btn-sm btn-outline-light me-1">+ LOCAL</button>
                                <button id="btn-prompt-cloud" class="btn btn-sm btn-outline-warning">+ CLOUD</button>
                            </div>
                        </div>
                        <div class="card-body p-2">
                            <div id="dest-container" class="dest-list"></div>
                        </div>
                    </div>
                </div>
            </div>
            <div class="card p-3 mb-3 border-secondary">
                <div class="row gx-3">
                    <div class="col-md-3">
                        <label class="small text-secondary fw-bold mb-2">3. BACKUP MODE</label>
                        <div class="btn-group w-100" role="group">
                            <input type="radio" class="btn-check" name="bkmode" id="mode-inc" checked><label class="btn btn-outline-warning btn-sm fw-bold" for="mode-inc" title="Fast">Inc</label>
                            <input type="radio" class="btn-check" name="bkmode" id="mode-full"><label class="btn btn-outline-warning btn-sm fw-bold" for="mode-full" title="History">Snap</label>
                        </div>
                    </div>
                    <div class="col-md-4">
                        <label class="small text-secondary fw-bold mb-2">4. COMPRESSION</label>
                        <select id="bak-comp" class="form-select form-select-sm form-control" style="font-family: 'Inter', sans-serif;">
                            <option value="none">None (1:1 Files)</option>
                            <option value="transfer">Transfer (-z Network)</option>
                            <option value="archive">Archive (.tar.gz File)</option>
                        </select>
                    </div>
                    <div class="col-md-5">
                        <div class="d-flex justify-content-between align-items-end mb-2">
                            <label class="small text-secondary fw-bold m-0">5. ENCRYPTION</label>
                            <div class="form-check m-0 d-flex align-items-center">
                                <input class="form-check-input m-0 me-1" type="checkbox" id="bak-remember" style="accent-color: var(--accent);">
                                <label class="form-check-label text-secondary small" style="font-size: 0.75rem;">Remember</label>
                            </div>
                        </div>
                        <div class="input-group input-group-sm mb-1">
                            <div class="input-group-text bg-dark border-secondary"><input class="form-check-input mt-0" type="checkbox" id="bak-enc"></div>
                            <input type="password" id="bak-key" class="form-control" placeholder="Passphrase">
                            <input type="password" id="bak-key-confirm" class="form-control" placeholder="Confirm">
                        </div>
                        <div id="pw-status" class="small fw-bold" style="font-size: 0.75rem; height: 16px;"></div>
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-12">
                        <div id="comp-info" class="p-2 rounded bg-black border border-secondary small text-secondary" style="font-size: 0.8rem; min-height: 40px; display: flex; align-items: center;">
                            <i class="bi bi-info-circle text-info me-2 fs-5"></i> <span id="comp-info-text">Select a mode to see details...</span>
                        </div>
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
                                <button id="btn-add-custom-exclude" class="btn btn-warning fw-bold">ADD</button>
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
            <h2 class="mb-3 fw-bold">Automation <span class="badge bg-danger fs-6 ms-2">Headless Mode</span></h2>
            
            <div class="card mb-3 border-secondary bg-dark">
                <div class="card-body p-3 text-center">
                    <h6 class="text-secondary fw-bold mb-1">CURRENT STATUS</h6>
                    <div id="schedule-status" class="fs-4 fw-bold text-secondary">Not Scheduled</div>
                    <button id="btn-clear-schedule" class="btn btn-sm btn-outline-danger mt-2" style="display:none;">Clear Schedule</button>
                </div>
            </div>

            <div class="card p-3 border-secondary mb-3">
                <p class="small text-warning fw-bold mb-3"><i class="bi bi-info-circle"></i> To automate backups, set up your Sources, Destinations, Excludes, and Compression on the Backup tab first. This tool takes a "snapshot" of your current configuration and builds a script for Linux Crontab to run in the background.</p>
                <div class="row gx-2 mb-3">
                    <div class="col-4">
                        <label class="small text-secondary fw-bold mb-1">FREQUENCY</label>
                        <select id="cron-freq" class="form-select form-select-sm form-control">
                            <option value="daily">Daily</option>
                            <option value="weekly">Weekly</option>
                            <option value="monthly">Monthly</option>
                        </select>
                    </div>
                    <div class="col-4" id="div-cron-day" style="display: none;">
                        <label class="small text-secondary fw-bold mb-1" id="lbl-cron-day">DAY</label>
                        <select id="cron-day" class="form-select form-select-sm form-control"></select>
                    </div>
                    <div class="col-4">
                        <label class="small text-secondary fw-bold mb-1">TIME</label>
                        <input type="time" id="cron-time" class="form-control form-control-sm" value="02:00">
                    </div>
                </div>
                
                <hr class="border-secondary my-3">
                <div class="row gx-2 align-items-center mb-3">
                    <div class="col-3">
                        <div class="form-check">
                            <input class="form-check-input" type="checkbox" id="cron-log-enable" checked style="accent-color: var(--accent);">
                            <label class="form-check-label small fw-bold text-white">Enable Logging</label>
                        </div>
                    </div>
                    <div class="col-9">
                        <div class="input-group input-group-sm">
                            <input type="text" id="cron-log-path" class="form-control text-secondary font-monospace" placeholder="/path/to/log.txt">
                            <button class="btn btn-secondary" id="btn-browse-log"><i class="bi bi-folder2-open"></i></button>
                        </div>
                    </div>
                </div>

                <button id="btn-save-cron" class="btn btn-primary btn-sm w-100 fw-bold py-2">COMPILE & ACTIVATE SCHEDULE</button>
            </div>
        </div>

        <div id="view-about" class="view-section text-center">
            <div style="margin-top: 20px;">
                <img src="logo.png" class="hero-logo" onerror="this.src='logo.svg'">
                <h2 class="fw-bold mb-1">Aureus The SpaceBearTaur</h2>
                <p class="text-secondary mb-4">BackupBear Edition</p>
                <div class="card d-inline-block p-3 text-start border-secondary mb-4" style="min-width: 250px;">
                    <div class="mb-2"><span class="text-secondary fw-bold small">VERSION</span><br><span class="fw-bold text-white fs-6">14.1.69</span></div>
                    <div class="mb-2"><span class="text-secondary fw-bold small">BUILD DATE</span><br><span class="font-monospace text-warning fs-6">2026-02-22</span></div>
                    <div><span class="text-secondary fw-bold small">ENGINE</span><br><span class="badge bg-primary mt-1 mb-1 fw-bold"><i class="bi bi-lightning-charge-fill"></i> Powered by Electron</span><br><span class="font-monospace text-white fs-6">Rclone + Rsync + Tar</span></div>
                </div>
                <div>
                    <span class="badge bg-dark border border-secondary text-secondary p-2 fw-normal" style="font-size: 0.85rem;">
                        <i class="bi bi-bug text-warning pe-1"></i> Developer Tip: Press <b>F12</b> to toggle the Debug Console
                    </span>
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

    <script>
        window.onerror = function(message, source, lineno, colno, error) {
            const logBox = document.getElementById('val-raw');
            if(logBox) {
                logBox.innerText = `[CRITICAL JS ERROR] ${message} (Line ${lineno})`;
                logBox.className = 'text-danger small mt-1 text-truncate font-monospace fw-bold';
                logBox.style.opacity = '1';
            }
        };
    </script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="./renderer.js"></script>
</body>
</html>
EOF

echo "📝 Writing Logic (renderer.js)..."
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
    document.getElementById('cron-log-path').value = homePath + '/.config/backupbear/history.log';
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
    if (viewName === 'schedule') loadSchedule();
}

document.getElementById('btn-toggle-term').addEventListener('click', () => {
    termVisible = !termVisible;
    document.getElementById('live-terminal-container').style.display = termVisible ? 'block' : 'none';
    document.getElementById('btn-toggle-term').innerHTML = termVisible ? '<i class="bi bi-terminal-dash"></i> Hide Live Terminal' : '<i class="bi bi-terminal"></i> Show Live Terminal';
    if (termVisible) { const term = document.getElementById('live-terminal'); term.scrollTop = term.scrollHeight; }
});

// --- DYNAMIC HUD LOGIC ---
const modeInc = document.getElementById('mode-inc');
const modeFull = document.getElementById('mode-full');
const bakComp = document.getElementById('bak-comp');
const encCheck = document.getElementById('bak-enc');
const compInfoText = document.getElementById('comp-info-text');

function updateCompInfo() {
    const c = bakComp.value;
    const isInc = modeInc.checked;
    const isEnc = encCheck.checked;
    let text = "";
    
    if (c === 'archive') {
        modeFull.checked = true; 
        modeInc.disabled = true; 
        text += '<span class="text-warning"><b>ARCHIVE MODE:</b> Packs everything into a single .tar.gz file. <b>This forces Snapshot mode.</b> Incremental tracking is disabled.</span> ';
    } else {
        modeInc.disabled = false;
        if (c === 'transfer') {
            text += '<span class="text-info"><b>TRANSFER COMPRESSION:</b> Compresses files <i>during network transit</i>, then unzips them at the destination. <b>Best for remote NAS.</b> ' + (isInc ? 'Incremental will only send new/changed files.' : 'Snapshot creates a full 1:1 copy.') + '</span> ';
        } else {
            text += '<span class="text-success"><b>NO COMPRESSION:</b> Pure 1:1 file copying. <b>Best and fastest for local USB drives.</b> ' + (isInc ? 'Incremental updates only changed files (FAST).' : 'Snapshot creates a full exact clone.') + '</span> ';
        }
    }
    
    if (isEnc) {
        text += '<br><span class="text-danger mt-1 d-block"><i class="bi bi-shield-lock-fill"></i> <b>ENCRYPTION ACTIVE:</b> Your destination files will be scrambled names and unreadable without BackupBear or your Rclone passphrase. Incremental mode is still supported!</span>';
    }
    
    compInfoText.innerHTML = text;
}

modeInc.addEventListener('change', updateCompInfo);
modeFull.addEventListener('change', updateCompInfo);
bakComp.addEventListener('change', updateCompInfo);
encCheck.addEventListener('change', updateCompInfo);


// --- SCHEDULE LOGIC ---
const freqEl = document.getElementById('cron-freq');
const dayDiv = document.getElementById('div-cron-day');
const dayLbl = document.getElementById('lbl-cron-day');
const dayEl = document.getElementById('cron-day');

freqEl.addEventListener('change', () => {
    const val = freqEl.value;
    if (val === 'daily') {
        dayDiv.style.display = 'none';
    } else if (val === 'weekly') {
        dayDiv.style.display = 'block';
        dayLbl.innerText = 'DAY OF WEEK';
        dayEl.innerHTML = `
            <option value="1">Monday</option>
            <option value="2">Tuesday</option>
            <option value="3">Wednesday</option>
            <option value="4">Thursday</option>
            <option value="5">Friday</option>
            <option value="6">Saturday</option>
            <option value="0">Sunday</option>
        `;
    } else if (val === 'monthly') {
        dayDiv.style.display = 'block';
        dayLbl.innerText = 'DAY OF MONTH';
        let days = '';
        for(let i=1; i<=28; i++) days += `<option value="${i}">${i}</option>`;
        dayEl.innerHTML = days;
    }
});

document.getElementById('cron-log-enable').addEventListener('change', (e) => {
    document.getElementById('cron-log-path').disabled = !e.target.checked;
    document.getElementById('btn-browse-log').disabled = !e.target.checked;
});

document.getElementById('btn-browse-log').addEventListener('click', async () => {
    const path = await window.bear.invoke('dialog:save', 'history.log');
    if (path) document.getElementById('cron-log-path').value = path;
});

async function loadSchedule() {
    const sched = await window.bear.invoke('get-schedule');
    const statusEl = document.getElementById('schedule-status');
    const clearBtn = document.getElementById('btn-clear-schedule');
    
    if (sched && sched.active) {
        let txt = `Active: ${sched.freq.charAt(0).toUpperCase() + sched.freq.slice(1)}`;
        if (sched.freq === 'weekly') {
            const days = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"];
            txt += ` on ${days[parseInt(sched.day)]}`;
        } else if (sched.freq === 'monthly') {
            const d = parseInt(sched.day);
            txt += ` on the ${d}${d===1?'st':d===2?'nd':d===3?'rd':'th'}`;
        }
        txt += ` at ${sched.time}`;
        
        statusEl.innerText = txt;
        statusEl.className = 'fs-5 fw-bold text-success';
        clearBtn.style.display = 'inline-block';
        
        freqEl.value = sched.freq;
        freqEl.dispatchEvent(new Event('change'));
        if(sched.freq !== 'daily') dayEl.value = sched.day;
        document.getElementById('cron-time').value = sched.time;
        
        document.getElementById('cron-log-enable').checked = sched.logEnabled;
        document.getElementById('cron-log-enable').dispatchEvent(new Event('change'));
        if (sched.logPath) document.getElementById('cron-log-path').value = sched.logPath;
        
    } else {
        statusEl.innerText = 'Not Scheduled';
        statusEl.className = 'fs-5 fw-bold text-secondary';
        clearBtn.style.display = 'none';
    }
}

document.getElementById('btn-save-cron').addEventListener('click', async () => {
    if (sources.filter(s => s.enabled).length === 0) return alert("Select at least one Source on the Backup tab first!");
    if (destinations.filter(d => d.enabled).length === 0) return alert("Select at least one Destination on the Backup tab first!");

    const schedData = {
        active: true,
        freq: freqEl.value,
        day: freqEl.value !== 'daily' ? dayEl.value : null,
        time: document.getElementById('cron-time').value,
        logEnabled: document.getElementById('cron-log-enable').checked,
        logPath: document.getElementById('cron-log-path').value
    };
    
    const encrypt = document.getElementById('bak-enc').checked;
    const key = document.getElementById('bak-key').value;
    const mode = document.getElementById('mode-full').checked ? 'full' : 'inc';
    const comp = document.getElementById('bak-comp').value;
    const activeExcludes = excludes.filter(e => e.enabled).map(e => e.pattern);

    if (encrypt) {
        if(!key) return alert("Enter an encryption passphrase on the Backup tab");
        if(key !== document.getElementById('bak-key-confirm').value) return alert("Passphrases do not match!");
    }

    const payload = {
        sched: schedData,
        sources: sources.filter(s => s.enabled),
        destinations: destinations.filter(d => d.enabled),
        encrypt, key, mode, comp, excludes: activeExcludes
    };

    const res = await window.bear.invoke('save-schedule', payload);
    
    if (res && res.success) {
        loadSchedule();
        showSuccess('btn-save-cron', 'SCRIPT COMPILED & CRONTAB UPDATED!');
    } else {
        alert("Failed to save schedule to Linux crontab.\n\nError details: " + (res?.error || "Unknown Error. Press F12."));
    }
});

document.getElementById('btn-clear-schedule').addEventListener('click', async () => {
    await window.bear.invoke('save-schedule', { sched: { active: false } });
    loadSchedule();
});

function renderExcludes() {
    const sysContainer = document.getElementById('sys-excludes-container');
    const custContainer = document.getElementById('custom-excludes-container');
    sysContainer.innerHTML = excludes.filter(e => e.sys).map((e, i) => `<div class="dest-item py-1"><i class="bi bi-shield-lock text-secondary me-2"></i><div class="dest-path text-white">${e.label}</div><input type="checkbox" class="dest-check" ${e.enabled ? 'checked' : ''} onchange="toggleExclude(${excludes.indexOf(e)})"></div>`).join('');
    const customs = excludes.filter(e => !e.sys);
    if(customs.length === 0) { custContainer.innerHTML = '<div class="p-2 text-center text-secondary small">No custom rules yet.</div>'; } 
    else { custContainer.innerHTML = customs.map((e, i) => `<div class="dest-item py-1"><i class="bi bi-file-earmark-x text-warning me-2"></i><div class="dest-path text-white font-monospace">${e.pattern}</div><input type="checkbox" class="dest-check" ${e.enabled ? 'checked' : ''} onchange="toggleExclude(${excludes.indexOf(e)})"><button class="btn btn-sm text-danger ms-2 p-0 px-1" onclick="removeExclude(${excludes.indexOf(e)})"><i class="bi bi-x-lg"></i></button></div>`).join(''); }
}
window.toggleExclude = (i) => { excludes[i].enabled = !excludes[i].enabled; };
window.removeExclude = (i) => { excludes.splice(i, 1); renderExcludes(); };

document.getElementById('btn-add-custom-exclude').addEventListener('click', () => {
    const input = document.getElementById('custom-exclude-input'); const val = input.value.trim();
    if(val && !excludes.find(e => e.pattern === val)) { excludes.push({ pattern: val, enabled: true, sys: false }); input.value = ''; renderExcludes(); }
});
renderExcludes();

document.getElementById('btn-add-source-local').addEventListener('click', async () => {
    const path = await window.bear.invoke('dialog:open');
    if (path && !sources.find(s => s.path === path)) { sources.push({ type: 'folder', path: path, enabled: true }); renderSources(); }
});
document.getElementById('btn-add-home').addEventListener('click', async () => {
    const homePath = await window.bear.getHome();
    if (!sources.find(s => s.path === homePath)) { sources.push({ type: 'home', path: homePath, enabled: true }); renderSources(); }
});
document.getElementById('btn-add-root').addEventListener('click', () => {
    if (!sources.find(s => s.path === '/')) { sources.push({ type: 'system', path: '/', enabled: true }); renderSources(); }
});

function renderSources() {
    const container = document.getElementById('source-container');
    if (sources.length === 0) { container.innerHTML = '<div class="p-3 text-center text-secondary small">Click buttons above<br>to add sources</div>'; return; }
    container.innerHTML = sources.map((s, i) => `<div class="dest-item"><i class="bi ${s.path === '/' ? 'bi-hdd-network-fill text-danger' : s.type === 'home' ? 'bi-house-door-fill text-info' : 'bi-folder-fill'} dest-icon"></i><div class="dest-path text-white" title="${s.path}">${s.path}</div><input type="checkbox" class="dest-check" ${s.enabled ? 'checked' : ''} onchange="toggleSrc(${i})"><button class="btn btn-sm text-danger ms-2 p-0 px-1" onclick="removeSrc(${i})"><i class="bi bi-x-lg"></i></button></div>`).join('');
}
window.toggleSrc = (i) => { sources[i].enabled = !sources[i].enabled; };
window.removeSrc = (i) => { sources.splice(i, 1); renderSources(); };


document.getElementById('btn-add-local').addEventListener('click', async () => {
    const path = await window.bear.invoke('dialog:open');
    if (path && !destinations.find(d => d.path === path)) { destinations.push({ type: 'local', path: path, enabled: true }); renderDestinations(); }
});
document.getElementById('btn-prompt-cloud').addEventListener('click', async () => {
    const remotes = await window.bear.invoke('rclone-list'); const sel = document.getElementById('modal-cloud-list');
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
    container.innerHTML = destinations.map((d, i) => `<div class="dest-item"><i class="bi ${d.type === 'cloud' ? 'bi-cloud-fill' : 'bi-hdd-fill'} dest-icon"></i><div class="dest-path text-white" title="${d.path}">${d.path}</div><input type="checkbox" class="dest-check" ${d.enabled ? 'checked' : ''} onchange="toggleDest(${i})"><button class="btn btn-sm text-danger ms-2 p-0 px-1" onclick="removeDest(${i})"><i class="bi bi-x-lg"></i></button></div>`).join('');
}
window.toggleDest = (i) => { destinations[i].enabled = !destinations[i].enabled; };
window.removeDest = (i) => { destinations.splice(i, 1); renderDestinations(); };

// --- PASSWORD UX & REMEMBER FEATURE ---
const pw1 = document.getElementById('bak-key');
const pw2 = document.getElementById('bak-key-confirm');
const pwStat = document.getElementById('pw-status');
const remCheck = document.getElementById('bak-remember');

function checkPw() {
    if (!encCheck.checked) {
        pw1.classList.remove('is-invalid', 'is-valid');
        pw2.classList.remove('is-invalid', 'is-valid');
        pwStat.innerHTML = '';
        return;
    }
    if (pw1.value === '' && pw2.value === '') {
        pwStat.innerHTML = '';
        return;
    }
    if (pw1.value === pw2.value && pw1.value.length > 0) {
        pw1.classList.remove('is-invalid'); pw2.classList.remove('is-invalid');
        pw1.classList.add('is-valid'); pw2.classList.add('is-valid');
        pwStat.innerHTML = '<span class="text-success"><i class="bi bi-check-circle-fill"></i> Passphrases match</span>';
    } else {
        pw1.classList.remove('is-valid'); pw2.classList.remove('is-valid');
        if (pw2.value.length > 0) {
            pw2.classList.add('is-invalid');
            pwStat.innerHTML = '<span class="text-danger"><i class="bi bi-x-circle-fill"></i> Do not match</span>';
        } else {
            pw2.classList.remove('is-invalid');
            pwStat.innerHTML = '';
        }
    }
}

function savePass() {
    if (remCheck.checked && pw1.value === pw2.value && pw1.value.length > 0) {
        localStorage.setItem('bear_pass', pw1.value);
        localStorage.setItem('bear_rem', 'true');
    } else if (!remCheck.checked) {
        localStorage.removeItem('bear_pass');
        localStorage.removeItem('bear_rem');
    }
}

pw1.addEventListener('input', () => { encCheck.checked = true; checkPw(); savePass(); updateCompInfo(); });
pw2.addEventListener('input', () => { encCheck.checked = true; checkPw(); savePass(); updateCompInfo(); });
remCheck.addEventListener('change', savePass);

// Auto-Load Saved Password
if (localStorage.getItem('bear_rem') === 'true') {
    remCheck.checked = true;
    const savedPw = localStorage.getItem('bear_pass');
    if (savedPw) {
        encCheck.checked = true;
        pw1.value = savedPw;
        pw2.value = savedPw;
        checkPw();
    }
}

// FORCE HUD TO UPDATE AFTER AUTO-LOAD FIXES THE RACE CONDITION
updateCompInfo();

function executeBackup(sources, destinations, encrypt, key, mode, comp) {
    document.getElementById('btn-run-backup').style.display = 'none';
    document.getElementById('btn-stop-backup').style.display = 'block';
    document.getElementById('live-terminal').textContent = ''; 
    const activeExcludes = excludes.filter(e => e.enabled).map(e => e.pattern);
    window.bear.send('start-backup-batch', { sources, destinations, encrypt, key, mode, comp, excludes: activeExcludes });
}

document.getElementById('btn-run-backup').addEventListener('click', () => {
    if (sources.filter(s => s.enabled).length === 0) return alert("Select at least one Source!");
    if (destinations.filter(d => d.enabled).length === 0) return alert("Select at least one Destination!");
    
    const encrypt = encCheck.checked;
    const key = pw1.value;
    const mode = document.getElementById('mode-full').checked ? 'full' : 'inc';
    const comp = document.getElementById('bak-comp').value;
    
    if (encrypt) {
        if(!key) return alert("Enter a passphrase");
        if(key !== pw2.value) return alert("Passphrases do not match!");
    }
    executeBackup(sources, destinations, encrypt, key, mode, comp);
});

document.getElementById('btn-force-backup').addEventListener('click', () => {
    bootstrap.Modal.getInstance(document.getElementById('weakPwModal')).hide();
    const mode = document.getElementById('mode-full').checked ? 'full' : 'inc';
    const comp = document.getElementById('bak-comp').value;
    executeBackup(sources, destinations, true, pw1.value, mode, comp);
});

document.getElementById('btn-stop-backup').addEventListener('click', () => { window.bear.send('stop-task'); });

async function loadRemotes() {
    const remotes = await window.bear.invoke('rclone-list'); const tabContainer = document.getElementById('cloud-tabs');
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
    const res = await window.bear.invoke('rclone-auth-drive', name); document.getElementById('auth-overlay').style.display = 'none';
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

window.bear.on('progress', (data) => {
    const elSpd = document.getElementById('val-spd'); if(elSpd) elSpd.innerText = data.speed;
    const elEta = document.getElementById('val-eta'); if(elEta) elEta.innerText = data.eta;
    const elRaw = document.getElementById('val-raw'); if(elRaw) { elRaw.innerText = data.raw; elRaw.className = "text-white small mt-1 text-truncate font-monospace"; }
    if (data.fullRaw) { const term = document.getElementById('live-terminal'); if(term) { term.textContent += data.fullRaw + '\n'; if (termVisible) term.scrollTop = term.scrollHeight; } }
});

window.bear.on('done', (msg) => {
    const btnRun = document.getElementById('btn-run-backup'); const btnStop = document.getElementById('btn-stop-backup');
    if(btnRun) btnRun.style.display = 'block'; if(btnStop) btnStop.style.display = 'none';
    if (msg.includes("Complete") || msg.includes("Stopped")) showSuccess('btn-run-backup', msg); else alert(msg);
});

switchView('backup');
EOF

echo "📝 Updating package.json with Mandatory Metadata..."
cat <<EOF > package.json
{
  "name": "backupbear",
  "productName": "BackupBear",
  "version": "14.1.69",
  "description": "A robust Rclone/Rsync GUI wrapper with incremental, snapshot support, compression, and advanced filtering.",
  "author": "Aureus K'Tharr <space-bear-taur@proton.me>",
  "homepage": "https://github.com/aureus/backupbear",
  "main": "main.js",
  "scripts": {
    "start": "electron . --no-sandbox",
    "dist": "electron-builder"
  },
  "build": {
    "appId": "com.aureus.backupbear",
    "directories": {
      "buildResources": "build",
      "output": "dist"
    },
    "linux": {
      "target": ["pacman", "deb"],
      "category": "Utility",
      "icon": "build/icons/512x512.png",
      "maintainer": "Aureus K'Tharr <space-bear-taur@proton.me>"
    },
    "files": [
      "**/*",
      "!dist/*",
      "!build/*",
      "!.*"
    ]
  }
}
EOF

echo "📦 Installing build dependencies..."
npm install --save-dev electron electron-builder --no-audit --silent

echo "🔨 Compiling v14.1.69 Packages..."
npx electron-builder --linux

echo ""
echo "✅ Build Complete!"
echo "---------------------------------------------------"
PKG_FILE=$(find dist -maxdepth 1 -name "*.pacman" -type f | head -n 1)
if [ -n "$PKG_FILE" ]; then
    echo "🟡 AUTO-DEPLOYING TO CACHYOS..."
    echo "Please enter your password if prompted:"
    sudo pacman -U --noconfirm "$APP_DIR/$PKG_FILE"
    
    echo "🧹 Wiping Plasma Icon Cache..."
    rm -f ~/.cache/icon-cache.kcache
    kbuildsycoca6 --noincremental > /dev/null 2>&1
    
    echo "✅ INSTALLATION SUCCESSFUL! Launch BackupBear from your application menu."
fi
echo "---------------------------------------------------"
