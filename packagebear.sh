#!/bin/bash
# BackupBear Master Packager 16.4.0: Architectural Integrity

set -e
APP_DIR="$(pwd)"
cd "$APP_DIR"

echo "BackupBear 16.4.0 Compiler & Packager"
echo "========================================="

echo "Cleaning old builds..."
rm -rf dist build
mkdir -p build/icons

if [ -f "aureus-logo.png" ]; then 
    cp "aureus-logo.png" "logo.png"
elif [ -f "$HOME/aureus-logo.png" ]; then 
    cp "$HOME/aureus-logo.png" "logo.png"
else 
    echo "Generating fallback icon..."
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

echo "Writing Backend (main.js)..."
cat <<'EOF' > main.js
const { app, BrowserWindow, ipcMain, dialog, Tray, Menu, shell } = require('electron');
const { spawn, exec, execSync } = require('child_process');
const fs = require('fs'); 
const path = require('path'); 
const os = require('os'); 
const https = require('https');

let mainWindow; 
let tray = null; 
let activeProcess = null;
let stopSignal = false;

const configPath = path.join(os.homedir(), '.config', 'backupbear');
const scheduleFile = path.join(configPath, 'schedule.json');
const profilesFile = path.join(configPath, 'profiles.json');
const appConfigFile = path.join(configPath, 'appconfig.json');

if (!fs.existsSync(configPath)) fs.mkdirSync(configPath, { recursive: true });

let appConfig = { 
    tray: false, 
    updates: false, 
    webhook: '', 
    ntfy: '', 
    notify: true,
    logEnabled: true,
    logPath: path.join(configPath, 'history.log'),
    defaultProfile: ''
};

try { 
    if (fs.existsSync(appConfigFile)) {
        const loaded = JSON.parse(fs.readFileSync(appConfigFile));
        appConfig = { ...appConfig, ...loaded };
    }
} catch(e){}

function createWindow() {
    mainWindow = new BrowserWindow({ 
        width: 1150, height: 850, minWidth: 950, minHeight: 700, 
        backgroundColor: '#121212', 
        webPreferences: { 
            nodeIntegration: false, 
            contextIsolation: true, 
            preload: path.join(__dirname, 'preload.js') 
        }, 
        autoHideMenuBar: true, 
        title: "BackupBear 16.4.0", 
        icon: path.join(__dirname, 'logo.png') 
    });
    
    mainWindow.webContents.on('before-input-event', (e, i) => { 
        if (i.key === 'F12' && i.type === 'keyDown') mainWindow.webContents.toggleDevTools(); 
    });
    
    mainWindow.loadFile('index.html');
    
    mainWindow.on('close', (e) => { 
        if (appConfig.tray && !app.isQuitting) { e.preventDefault(); mainWindow.hide(); } 
    });
    
    if (appConfig.updates) checkGitHubUpdates();
}

app.whenReady().then(() => {
    createWindow();
    tray = new Tray(path.join(__dirname, 'logo.png'));
    tray.setContextMenu(Menu.buildFromTemplate([
        { label: 'Show BackupBear', click: () => mainWindow.show() }, 
        { label: 'Quit', click: () => { app.isQuitting = true; app.quit(); } }
    ]));
    tray.on('click', () => mainWindow.show());
});

function checkGitHubUpdates() {
    https.get({ hostname: 'api.github.com', path: '/repos/Aureustaur/backupbear/releases/latest', headers: { 'User-Agent': 'BackupBear-App' } }, (res) => {
        let d = ''; 
        res.on('data', c => d += c); 
        res.on('end', () => { 
            try { 
                const r = JSON.parse(d); 
                if (r.tag_name && r.tag_name > 'v16.4.0') mainWindow.webContents.send('update-available', r); 
            } catch(e) {} 
        });
    });
}

function sendExtNotify(msg) {
    if (appConfig.webhook) { 
        try { 
            const d = JSON.stringify({ content: `[BackupBear] ${msg}` }); 
            const u = new URL(appConfig.webhook); 
            const r = https.request({ hostname: u.hostname, path: u.pathname, method: 'POST', headers: {'Content-Type': 'application/json', 'Content-Length': d.length} }); 
            r.write(d); r.end(); 
        } catch(e) {} 
    }
    if (appConfig.ntfy) { 
        try { 
            const u = new URL(appConfig.ntfy); 
            const r = https.request({ hostname: u.hostname, path: u.pathname, method: 'POST', headers: {'Title': 'BackupBear', 'Tags': 'bear'} }); 
            r.write(msg); r.end(); 
        } catch(e) {} 
    }
}

ipcMain.on('run-updater', () => { 
    const cmd = `cd "$HOME/BackupBear-Electron" && wget -O packagebear.sh https://raw.githubusercontent.com/Aureustaur/BackupBear/main/packagebear.sh && bash packagebear.sh; read -p 'Press Enter...'`; 
    exec(`konsole -e bash -c '${cmd}' || gnome-terminal -- bash -c '${cmd}' || xfce4-terminal -e "bash -c '${cmd}'" || xterm -e bash -c '${cmd}'`); 
    app.isQuitting = true; app.quit(); 
});

ipcMain.on('open-link', (e, link) => shell.openExternal(link));
ipcMain.handle('get-home', () => os.homedir());
ipcMain.handle('get-config', () => appConfig);
ipcMain.handle('save-config', (e, c) => { 
    appConfig = { ...appConfig, ...c }; 
    fs.writeFileSync(appConfigFile, JSON.stringify(appConfig)); 
    return true; 
});

ipcMain.handle('get-profiles', () => { 
    try { if (fs.existsSync(profilesFile)) return JSON.parse(fs.readFileSync(profilesFile)); } catch (e) {} 
    return {}; 
});

ipcMain.handle('save-profile', (e, a) => { 
    let p = {}; 
    try { if (fs.existsSync(profilesFile)) p = JSON.parse(fs.readFileSync(profilesFile)); } catch (e) {} 
    if(a.delete) delete p[a.name]; else p[a.name] = a.data; 
    fs.writeFileSync(profilesFile, JSON.stringify(p, null, 2)); 
    return p; 
});

ipcMain.handle('check-deps', async () => { 
    const chk = (c) => { try { execSync(`command -v ${c}`); return true; } catch { return false; } }; 
    const m = []; 
    ['rclone', 'rsync', 'cron', 'tar'].forEach(c => { if(!chk(c==='cron'?'crontab':c)) m.push(c); }); 
    return { ok: m.length===0, missing: m, installCmd: chk('pacman')?'sudo pacman -S rclone rsync cronie tar':'sudo apt install rclone rsync cron tar' }; 
});

ipcMain.handle('dialog:open', async () => { 
    const r = await dialog.showOpenDialog(mainWindow, {properties:['openDirectory']}); 
    return r.canceled ? null : r.filePaths[0]; 
});

ipcMain.handle('dialog:save', async (e, defaultPath) => { 
    const r = await dialog.showSaveDialog(mainWindow, {defaultPath}); 
    return r.canceled ? null : r.filePath; 
});

// CLOUD HANDLERS
ipcMain.handle('rclone-dump', async () => new Promise(resolve => {
    exec('rclone config dump', (e, out) => {
        try {
            const jsonStart = out.indexOf('{');
            const jsonEnd = out.lastIndexOf('}') + 1;
            if(jsonStart !== -1 && jsonEnd !== -1) { resolve(JSON.parse(out.substring(jsonStart, jsonEnd))); } 
            else { resolve({}); }
        } catch { resolve({}); }
    });
}));

ipcMain.handle('rclone-list', async () => new Promise(res => exec('rclone listremotes', (e, o) => res(e ? [] : o.split('\n').filter(r => r.trim()).map(r => r.replace(':', ''))))));
ipcMain.handle('rclone-ls', async (e, r) => new Promise(res => exec(`rclone lsjson "${r}:" --max-depth 1`, (err, o) => { try { const f = JSON.parse(o); f.sort((a,b)=>(b.IsDir===a.IsDir)?0:b.IsDir?1:-1); res(f); } catch { res([]); } })));
ipcMain.handle('rclone-delete', async (e, n) => new Promise(res => exec(`rclone config delete "${n}"`, () => res(true))));
ipcMain.handle('rclone-auth-drive', async (e, n) => new Promise(res => { const p = spawn('rclone', ['authorize', 'drive']); let b=''; p.stdout.on('data', d=>b+=d.toString()); p.on('close', c=>{ if(c!==0) return res("Fail"); const m=b.match(/\{.*\}/); if(!m) return res("No Token"); try{ const cd=path.join(os.homedir(), '.config', 'rclone'); if(!fs.existsSync(cd)) fs.mkdirSync(cd, {recursive:true}); fs.appendFileSync(path.join(cd, 'rclone.conf'), `\n[${n}]\ntype=drive\nscope=drive\ntoken=${m[0]}\n`); res("Success"); }catch(err){res("Err");} }); }));
ipcMain.handle('rclone-auth-nextcloud', async (e, a) => new Promise(res => exec(`rclone obscure '${a.pass}'`, (err, o) => { if(err) return res("Err"); exec(`rclone config create "${a.name}" nextcloud url="${a.url}" user="${a.user}" pass="${o.trim()}"`, e => res(e ? "Fail" : "Success")); })));
ipcMain.handle('rclone-auth-b2', async (e, a) => new Promise(res => exec(`rclone config create "${a.name}" b2 account "${a.acc}" key "${a.key}"`, err => res(err ? "Fail" : "Success"))));
ipcMain.handle('rclone-auth-webdav', async (e, a) => new Promise(res => exec(`rclone obscure '${a.pass}'`, (err, o) => { if(err) return res("Err"); exec(`rclone config create "${a.name}" webdav url "${a.url}" vendor other user "${a.user}" pass "${o.trim()}"`, e => res(e ? "Fail" : "Success")); })));

// CORE ENGINE EXECUTION
ipcMain.on('stop-task', () => { 
    stopSignal = true;
    if(activeProcess) { 
        activeProcess.kill(); 
        activeProcess = null; 
        if(!mainWindow.isDestroyed()) mainWindow.webContents.send('done', "Stopped by User"); 
    }
});

const esc = (p) => p.replace(/'/g, "'\\''");

ipcMain.on('start-backup-batch', async (e, args) => {
    activeProcess = null;
    stopSignal = false;
    
    try {
        const { sources, destinations, encrypt, key, mode, excludes, comp, dryRun, bwVal, bwUnit } = args;
        const stamp = new Date().toISOString().replace(/T/,'_').replace(/:/g,'-').slice(0,16);
        const excludeString = excludes.map(ex => `--exclude '${esc(ex)}'`).join(' ');

        let bwRsync = ""; let bwRclone = "";
        if (bwVal && parseInt(bwVal) > 0) { 
            if (bwUnit === 'M') { bwRsync = `--bwlimit=${bwVal * 1024}`; bwRclone = `--bwlimit ${bwVal}M`; } 
            else { bwRsync = `--bwlimit=${bwVal}`; bwRclone = `--bwlimit ${bwVal}k`; } 
        }

        if (dryRun && !mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: "SIMULATION INITIATED...", pct: "TEST", stage: "Dry Run Mode", stageClass: "text-info" });

        for (const dest of destinations) {
            if (dest.enabled === false) continue;
            if (stopSignal) break;
            
            if (comp === 'archive') {
                let baseDest = dest.path.includes(':') ? `${dest.path}:Backup_${stamp}.tar.gz` : path.join(dest.path, `Backup_${stamp}.tar.gz`);
                const srcPaths = sources.filter(s => s.enabled !== false).map(s => `'${esc(s.path)}'`).join(' ');
                
                await new Promise(resolve => {
                    let cmd = "";
                    if (dest.type === 'cloud' || (encrypt && key)) {
                        let rCmd = `tar -czf - ${excludeString} ${srcPaths} | rclone rcat '${esc(baseDest)}' ${bwRclone} ${dryRun ? '--dry-run' : ''}`;
                        if (encrypt && key) { 
                            try { 
                                const obs = execSync(`rclone obscure '${esc(key)}'`).toString().trim();
                                cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${esc(baseDest)}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rCmd.replace(esc(baseDest), 'T:')}`; 
                            } catch {} 
                        } else { cmd = rCmd; }
                    } else { 
                        cmd = dryRun ? `echo 'SIMULATION: Archive ${esc(baseDest)}'` : `tar -czvf '${esc(baseDest)}' ${excludeString} ${srcPaths}`; 
                    }
                    
                    if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `Archiving to ${baseDest}...`, fullRaw: `[SYSTEM] Initiating Archive Process for ${baseDest}...`, pct: "0%", stage: "Preparing Archive..." });

                    // FORCED CLEAN SHELL TO AVOID FASTFETCH
                    const proc = spawn('/bin/bash', ['--noprofile', '--norc', '-c', cmd]); 
                    activeProcess = proc;
                    
                    proc.stdout.on('data', d => { 
                        if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `[Archive] ${d.toString().substring(0,40)}...`, fullRaw: d.toString().trim(), pct: dryRun?"TEST":"...", stage: "Compressing..." }); 
                    });
                    proc.stderr.on('data', d => {
                        if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { fullRaw: `[ERR] ${d.toString().trim()}` });
                    });
                    proc.on('close', () => { activeProcess=null; resolve(); });
                });
            } else {
                let baseDest = dest.path;
                if (mode === 'full') baseDest = dest.path.includes(':') ? `${dest.path}:${stamp}` : path.join(dest.path, `Backup_${stamp}`);
                else if (dest.type === 'cloud' && !dest.path.includes(':')) baseDest = `${dest.path}:Backup`;

                for (const src of sources) {
                    if (src.enabled === false) continue;
                    if (stopSignal) break;

                    let finalDest = baseDest;
                    if (src.path !== '/') {
                        const rSrc = src.path.replace(/^\/+/, '');
                        if (finalDest.includes(':')) finalDest = finalDest.endsWith('/') ? finalDest + rSrc : finalDest + '/' + rSrc;
                        else { finalDest = path.join(finalDest, rSrc); if(!dryRun) fs.mkdirSync(finalDest, { recursive: true }); }
                    }

                    await new Promise(resolve => {
                        let cmd = ""; let cleanSrc = src.path.endsWith('/') ? src.path : src.path + '/';
                        if (dest.type === 'cloud' || (encrypt && key)) {
                            let rCmd = `rclone sync '${esc(cleanSrc)}' '${esc(finalDest)}' --progress --stats-one-line ${excludeString} ${bwRclone} ${dryRun ? '--dry-run' : ''}`;
                            if (encrypt && key) { 
                                try { 
                                    const obs = execSync(`rclone obscure '${esc(key)}'`).toString().trim();
                                    cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${esc(finalDest)}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rCmd.replace(esc(finalDest), 'T:')}`; 
                                } catch {} 
                            } else { cmd = rCmd; }
                        } else { 
                            let flags = mode === 'full' ? "-aAXxv" : "-aAXxv --delete";
                            if (comp === 'transfer') flags += "z";
                            cmd = `rsync ${flags} --info=progress2 ${bwRsync} ${dryRun ? '--dry-run' : ''} ${excludeString} '${esc(cleanSrc)}' '${esc(finalDest)}/' | tr '\\r' '\\n'`; 
                        }
                        
                        if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `Syncing: ${src.path}...`, fullRaw: `[SYSTEM] Establishing Connection for ${src.path}...`, pct: "0%", stage: "Connecting..." });

                        // FORCED CLEAN SHELL TO AVOID FASTFETCH
                        const proc = spawn('/bin/bash', ['--noprofile', '--norc', '-c', cmd]); 
                        activeProcess = proc;
                        proc.stdout.on('data', d => {
                            if(mainWindow.isDestroyed()) return;
                            const line = d.toString().replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').trim(); 
                            let spd="--", eta="--", pct=dryRun ? "TEST" : "Working...";
                            if((dest.type==='cloud'||encrypt) && line.match(/\d+%/)) { 
                                const p = line.split(','); if(p.length>2) { pct = p[0].trim().split(' ')[0]; spd = p[2]?.trim(); eta = p[3]?.trim().split('(')[0].replace('ETA',''); } 
                            } else if(line.match(/\d+%/)) { 
                                const p = line.split(/\s+/).filter(x=>x); if(p.length>=4) { pct = p[1]; spd = p[2]; eta = p[3].split('(')[0]; } 
                            }
                            if(line) mainWindow.webContents.send('progress', { raw: `[Sync] ${line.substring(0,60)}...`, fullRaw: line, pct, speed:spd, eta, stage: dryRun?"Simulating...":"Transferring...", stageClass: dryRun?"text-info":"text-warning" });
                        });
                        proc.stderr.on('data', d => {
                            if(!mainWindow.isDestroyed()) mainWindow.webContents.send('progress', { raw: `[Log] Processing...`, fullRaw: `[ERR] ${d.toString().trim()}` });
                        });
                        proc.on('close', () => { activeProcess=null; resolve(); });
                    });
                }
            }
        }
        
        if(!mainWindow.isDestroyed() && !stopSignal) mainWindow.webContents.send('done', dryRun ? "Simulation Complete" : "Batch Complete");
        if(!dryRun && !stopSignal) { 
            if(appConfig.notify) exec(`notify-send "BackupBear" "Job completed!"`); 
            sendExtNotify(`Job completed at ${new Date().toLocaleTimeString()}`); 
        }

    } catch (err) {
        if(!mainWindow.isDestroyed()) {
            mainWindow.webContents.send('progress', { raw: "CRITICAL FAILURE", fullRaw: `[CRITICAL ERROR] ${err.message}`, pct: "ERR", stage: "Engine Failed", stageClass: "text-danger" });
            mainWindow.webContents.send('done', "Process Crashed");
        }
    }
});

ipcMain.on('start-restore-task', async (e, args) => {
    activeProcess = null;
    stopSignal = false;
    
    try {
        const { source, dest, isArchive, encrypt, key } = args;
        
        if(!mainWindow.isDestroyed()) mainWindow.webContents.send('restore-progress', { raw: `Restoring...`, pct: "0%", stage: "Initializing Restore..." });
        
        await new Promise(resolve => {
            let cmd = ""; let isCloud = source.includes(':') || (encrypt && key);
            if (isArchive) {
                if (isCloud) { 
                    let rCmd = `rclone cat '${esc(source)}' | tar -xzf - -C '${esc(dest)}'`; 
                    if (encrypt && key) { 
                        try { 
                            const obs = execSync(`rclone obscure '${esc(key)}'`).toString().trim();
                            cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${esc(source)}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rCmd.replace(esc(source), 'T:')}`; 
                        } catch {} 
                    } else { cmd = rCmd; } 
                } else { cmd = `tar -xzvf '${esc(source)}' -C '${esc(dest)}'`; }
            } else {
                let cln = source.endsWith('/')||source.endsWith(':') ? source : source+'/';
                if (isCloud) { 
                    let rCmd = `rclone sync '${esc(cln)}' '${esc(dest)}' --progress --stats-one-line`; 
                    if (encrypt && key) { 
                        try { 
                            const obs = execSync(`rclone obscure '${esc(key)}'`).toString().trim();
                            cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${esc(cln)}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rCmd.replace(esc(cln), 'T:')}`; 
                        } catch {} 
                    } else { cmd = rCmd; } 
                } else { cmd = `rsync -aAXv --info=progress2 '${esc(cln)}' '${esc(dest)}/' | tr '\\r' '\\n'`; }
            }
            
            // FORCED CLEAN SHELL TO AVOID FASTFETCH
            const proc = spawn('/bin/bash', ['--noprofile', '--norc', '-c', cmd]); 
            activeProcess = proc;
            proc.stdout.on('data', d => {
                if(mainWindow.isDestroyed()) return;
                const line = d.toString().replace(/\x1B\[[0-9;]*[A-Za-z]/g, '').trim(); 
                let spd="--", eta="--", pct="Working...";
                if(isCloud && !isArchive && line.match(/\d+%/)) { 
                    const p = line.split(','); if(p.length>2) { pct = p[0].trim().split(' ')[0]; spd = p[2]?.trim(); eta = p[3]?.trim().split('(')[0].replace('ETA',''); } 
                } else if(!isCloud && !isArchive && line.match(/\d+%/)) { 
                    const p = line.split(/\s+/).filter(x=>x); if(p.length>=4) { pct = p[1]; spd = p[2]; eta = p[3].split('(')[0]; } 
                } else if (isArchive) { pct = "Extracting"; }
                
                if(line) mainWindow.webContents.send('restore-progress', { raw: `[Restore] ${line.substring(0,50)}...`, fullRaw: line, pct, speed:spd, eta, stage: isArchive?"Extracting":"Restoring..." });
            });
            proc.stderr.on('data', d => {
                if(!mainWindow.isDestroyed()) mainWindow.webContents.send('restore-progress', { fullRaw: `[ERR] ${d.toString().trim()}` });
            });
            proc.on('close', () => { activeProcess=null; resolve(); });
        });
        
        if(!mainWindow.isDestroyed() && !stopSignal) mainWindow.webContents.send('restore-done', "Restore Complete");
        if(appConfig.notify && !stopSignal) exec(`notify-send "BackupBear" "Restore completed!"`);
    } catch (err) {
        if(!mainWindow.isDestroyed()) {
            mainWindow.webContents.send('restore-progress', { raw: "CRITICAL FAILURE", fullRaw: `[CRITICAL ERROR] ${err.message}`, pct: "ERR", stage: "Engine Failed" });
            mainWindow.webContents.send('restore-done', "Process Crashed");
        }
    }
});

// MULTI-CRON SCHEDULE MANAGER
ipcMain.handle('get-schedule', () => {
    try { 
        if (fs.existsSync(scheduleFile)) {
            const data = JSON.parse(fs.readFileSync(scheduleFile));
            if (Array.isArray(data)) return data;
            // Legacy Migration
            if (data && data.active) return [ { id: 'job_1', profile: 'Legacy Job', freq: data.freq, day: data.day, time: data.time } ];
        }
    } catch (e) {}
    return [];
});

ipcMain.handle('save-schedule', (e, payload) => {
    try {
        const { schedules, profiles, appConf } = payload;
        if (!fs.existsSync(configPath)) fs.mkdirSync(configPath, { recursive: true });
        fs.writeFileSync(scheduleFile, JSON.stringify(schedules, null, 2));

        const tempCron = path.join(configPath, 'tempcron');
        let currentCron = "";
        try { currentCron = execSync('crontab -l 2>/dev/null').toString(); } catch(err) {}
        
        let filteredCron = currentCron.split('\n')
            .filter(line => line.trim() !== '' && !line.includes('BackupBear_Cron') && !line.includes('no crontab'))
            .join('\n');
            
        if (filteredCron.trim() === '') {
            filteredCron = "# BackupBear Automation File\n";
        } else {
            filteredCron += '\n';
        }
        
        try { execSync(`rm -f ${path.join(configPath, 'runner_*.sh')}`); } catch(e){}

        if (schedules.length === 0) { 
            if (filteredCron.trim() === '# BackupBear Automation File') {
                try { execSync(`crontab -r 2>/dev/null`); } catch(e){}
            } else {
                fs.writeFileSync(tempCron, filteredCron);
                execSync(`crontab "${tempCron}"`); 
            }
            return { success: true }; 
        }

        for (const sched of schedules) {
            const profile = profiles[sched.profile];
            if (!profile) continue;

            const runnerScript = path.join(configPath, `runner_${sched.id}.sh`);
            const logPath = appConf.logEnabled ? appConf.logPath : '/dev/null';
            const excludeString = (profile.excludes || []).filter(e=>e.enabled).map(ex => `--exclude '${esc(ex.pattern)}'`).join(' ');
            
            let script = `#!/bin/bash\nexport DISPLAY=:0\nexport DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus\nLOG="${logPath}"\n`;
            script += `echo "=====================================" >> "$LOG"\necho "BackupBear Scheduled Run [${sched.profile}]: $(date)" >> "$LOG"\nnotify-send "BackupBear" "Scheduled backup [${sched.profile}] started..." -u normal || true\n\n`;

            const sources = (profile.sources || []).filter(s => s.enabled !== false);
            const dests = (profile.destinations || []).filter(d => d.enabled !== false);

            for (const dest of dests) {
                if (profile.comp === 'archive') {
                    let baseDest = dest.path.includes(':') ? `${dest.path}:Backup_$(date +%Y-%m-%d_%H-%M).tar.gz` : path.join(dest.path, `Backup_$(date +%Y-%m-%d_%H-%M).tar.gz`);
                    const srcPaths = sources.map(s => `'${esc(s.path)}'`).join(' ');
                    script += `echo "[Archiving] ${srcPaths} -> ${baseDest}" >> "$LOG"\n`;
                    let cmd = "";
                    if (dest.type === 'cloud' || (profile.encrypt && profile.key)) {
                        let rCmd = `tar -czf - ${excludeString} ${srcPaths} | rclone rcat '${esc(baseDest)}'`;
                        if (profile.encrypt && profile.key) {
                            try { 
                                const obs = execSync(`rclone obscure '${esc(profile.key)}'`).toString().trim(); 
                                cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${esc(baseDest)}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rCmd.replace(esc(baseDest), 'T:')}`; 
                            } catch {}
                        } else { cmd = rCmd; }
                    } else { cmd = `tar -czvf '${esc(baseDest)}' ${excludeString} ${srcPaths}`; }
                    script += `${cmd} >> "$LOG" 2>&1\n\n`;
                } else {
                    let baseDest = dest.path;
                    if (profile.mode === 'full') { baseDest = dest.path.includes(':') ? `${dest.path}:$(date +%Y-%m-%d_%H-%M)` : path.join(dest.path, `Backup_$(date +%Y-%m-%d_%H-%M)`); } 
                    else if (dest.type === 'cloud' && !dest.path.includes(':')) { baseDest = `${dest.path}:Backup`; }

                    for (const src of sources) {
                        let finalDest = baseDest;
                        if (src.path !== '/') {
                            const relativeSrc = src.path.replace(/^\/+/, '');
                            if (finalDest.includes(':')) finalDest = finalDest.endsWith('/') ? finalDest + relativeSrc : finalDest + '/' + relativeSrc;
                            else { finalDest = path.join(finalDest, relativeSrc); script += `mkdir -p "${finalDest}"\n`; }
                        } else { if (!finalDest.includes(':')) script += `mkdir -p "${finalDest}"\n`; }
                        let cleanSrc = src.path.endsWith('/') ? src.path : src.path + '/';
                        script += `echo "[Syncing] ${cleanSrc} -> ${finalDest}" >> "$LOG"\n`;
                        let cmd = "";
                        if (dest.type === 'cloud' || (profile.encrypt && profile.key)) {
                            let rCmd = `rclone sync '${esc(cleanSrc)}' '${esc(finalDest)}' -v ${excludeString}`;
                            if (profile.encrypt && profile.key) {
                                try { 
                                    const obs = execSync(`rclone obscure '${esc(profile.key)}'`).toString().trim(); 
                                    cmd = `RCLONE_CONFIG_T_TYPE=crypt RCLONE_CONFIG_T_REMOTE='${esc(finalDest)}' RCLONE_CONFIG_T_PASSWORD='${obs}' ${rCmd.replace(esc(finalDest), 'T:')}`; 
                                } catch {}
                            } else { cmd = rCmd; }
                        } else {
                            let flags = profile.mode === 'full' ? "-aAXxv" : "-aAXxv --delete"; 
                            if (profile.comp === 'transfer') flags += "z";
                            cmd = `rsync ${flags} ${excludeString} '${esc(cleanSrc)}' '${esc(finalDest)}/'`;
                        }
                        script += `${cmd} >> "$LOG" 2>&1\n\n`;
                    }
                }
            }
            script += `notify-send "BackupBear" "Scheduled backup [${sched.profile}] completed!" -u normal || true\necho "Finished: $(date)" >> "$LOG"\n`;
            fs.writeFileSync(runnerScript, script, { mode: 0o755 });

            const [hr, min] = sched.time.split(':');
            let cronExp = '';
            if (sched.freq === 'daily') cronExp = `${min} ${hr} * * *`;
            else if (sched.freq === 'weekly') cronExp = `${min} ${hr} * * ${sched.day}`;
            else if (sched.freq === 'monthly') cronExp = `${min} ${hr} ${sched.day} * *`;

            filteredCron += `${cronExp} "${runnerScript}" # BackupBear_Cron\n`;
        }
        
        fs.writeFileSync(tempCron, filteredCron);
        execSync(`crontab "${tempCron}"`);
        return { success: true };
    } catch (e) { 
        console.error(e); 
        return { success: false, error: e.message }; 
    }
});

EOF

echo "Writing Preload (preload.js)..."
cat <<'EOF' > preload.js
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('bear', { 
    invoke: (c, d) => ipcRenderer.invoke(c, d), 
    send: (c, d) => ipcRenderer.send(c, d), 
    on: (c, f) => ipcRenderer.on(c, (e, ...a) => f(...a)), 
    getHome: () => ipcRenderer.invoke('get-home') 
});
EOF

echo "Writing Interface (index.html)..."
cat <<'EOF' > index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>BackupBear 16.4.0</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;700&family=JetBrains+Mono:wght@700&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.0/font/bootstrap-icons.css">
    <style>
        :root { --bg:#000; --sidebar:#0a0a0a; --card:#151515; --text:#fff; --accent:#FF9800; --border:#333; --input:#000; }
        body { background:var(--bg); color:var(--text); font-family:'Inter', sans-serif; overflow:hidden; user-select:none; }
        input, textarea, select { user-select:text !important; }
        
        .sidebar { height:100vh; background:var(--sidebar); padding:15px; width:220px; position:fixed; border-right:1px solid var(--border); }
        
        /* BULLETPROOF FLEX SCALING: */
        .content { margin-left:220px; padding:20px; height:100vh; overflow:hidden; display:flex; flex-direction:column; }
        .view-section { display:none; flex-direction:column; flex: 1 1 0; min-height:0; overflow:hidden; }
        .view-section.active { display:flex; animation:fadeIn 0.3s; }
        .tab-content { flex: 1 1 0; display:flex; flex-direction:column; overflow:hidden; min-height:0; }
        .tab-pane { display:none; flex-direction:column; height:100%; flex: 1 1 0; overflow-y:auto; min-height:0; }
        .tab-pane.active { display:flex; }
        
        /* DASHBOARD TERMINAL LOCK */
        #b-dash { overflow: hidden; } 
        
        @keyframes fadeIn { from{opacity:0} to{opacity:1} }
        
        h2.mb-3 { margin-bottom:1rem !important; font-size:1.5rem; }
        .card { background:var(--card); border:1px solid var(--border); border-radius:10px; }
        .card-header { border-bottom:1px solid var(--border); color:var(--accent); font-weight:800; text-transform:uppercase; padding:10px 15px; font-size:0.75rem; letter-spacing:1px; }
        
        .dest-list { height:120px; overflow-y:auto; background:var(--bg); border:1px solid var(--border); border-radius:8px; }
        .ex-list { background:var(--bg); border:1px solid var(--border); border-radius:8px; overflow-y:auto; }
        .dest-item { display:flex; align-items:center; padding:8px 10px; border-bottom:1px solid var(--border); }
        .dest-icon { margin-right:10px; font-size:1rem; color:var(--accent); }
        .dest-path { flex-grow:1; font-family:'JetBrains Mono',monospace; font-size:0.8rem; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .dest-check { width:16px; height:16px; accent-color:var(--accent); cursor:pointer; }
        .cursor-pointer { cursor:pointer; transition:background 0.2s; }
        .cursor-pointer:hover { background: #222 !important; }
        
        .nav-btn { display:flex; align-items:center; gap:10px; width:100%; padding:12px 15px; margin-bottom:5px; background:transparent; border:1px solid transparent; color:#888; font-weight:700; border-radius:8px; font-size:0.85rem; cursor:pointer; transition:all 0.2s; }
        .nav-btn:hover { color:var(--text); background:rgba(128,128,128,0.1); }
        .nav-btn.active { background:var(--accent); color:#000 !important; }
        
        .nav-pills .nav-link { color:#888; border:1px solid transparent; border-radius:6px; font-size:0.85rem; padding:8px 16px; transition:all 0.2s; }
        .nav-pills .nav-link.active { background-color:var(--accent); color:#000 !important; font-weight:bold; border-color:var(--accent); }
        .nav-pills .nav-link:hover:not(.active) { color:#fff; border-color:#444; }

        .form-control, .form-select, .input-group-text { background-color:var(--input) !important; color:var(--text) !important; border:1px solid #444 !important; font-size:0.85rem;}
        .form-control:focus, .form-select:focus { border-color:var(--accent) !important; box-shadow:none !important; }
        .is-valid { border-color:#198754 !important; background-image:none !important; }
        .is-invalid { border-color:#dc3545 !important; background-image:none !important; }
        
        .cloud-tabs { display:flex; gap:10px; overflow-x:auto; padding-bottom:10px; border-bottom:1px solid var(--border); margin-bottom:10px; }
        .cloud-tab { background:#222; color:#888; border:1px solid var(--border); padding:6px 12px; border-radius:15px; white-space:nowrap; cursor:pointer; font-weight:bold; font-size:0.85rem; }
        .cloud-tab.active { background:var(--accent); color:#000; border-color:var(--accent); }
        .file-grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(90px, 1fr)); gap:10px; max-height:300px; overflow-y:auto; }
        .file-item { background:#222; padding:10px; border-radius:8px; text-align:center; cursor:pointer; }
        .file-icon { font-size:1.8rem; color:#666; margin-bottom:3px; }
        .file-name { font-size:0.7rem; color:#ccc; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
        .is-dir .file-icon { color:var(--accent); }
        
        .metric-lbl { color:var(--accent) !important; font-size:0.75rem; font-weight:800; display:block !important; margin-bottom:3px; }
        .metric-val { font-family:'JetBrains Mono',monospace; font-size:1.1rem; font-weight:bold; white-space:nowrap; }
        
        #auth-overlay { position:fixed; top:0; left:0; width:100%; height:100%; background:rgba(0,0,0,0.95); z-index:9999; display:none; align-items:center; justify-content:center; flex-direction:column; text-align:center; }
    </style>
</head>
<body>

<div id="auth-overlay">
    <div class="spinner-border text-warning mb-3" style="width:2.5rem;height:2.5rem;"></div>
    <h4 class="text-white fw-bold">Authenticating...</h4>
</div>

<div class="modal fade" id="cloudModal" tabindex="-1">
    <div class="modal-dialog modal-dialog-centered">
        <div class="modal-content" style="background:var(--card);">
            <div class="modal-header border-secondary">
                <h6 class="modal-title text-white">Select Remote Provider</h6>
                <button type="button" class="btn-close btn-close-white" data-bs-dismiss="modal"></button>
            </div>
            <div class="modal-body">
                <select id="modal-cloud-list" class="form-select mb-3"></select>
                <button id="btn-confirm-cloud" class="btn btn-warning btn-sm w-100 fw-bold text-dark">Select Profile</button>
            </div>
        </div>
    </div>
</div>

<div class="sidebar">
    <div class="d-flex flex-column align-items-center mb-4 ps-1">
        <img src="logo.png" style="width:120px; margin-bottom:5px;" onerror="this.src='logo.svg'">
        <h5 class="fw-bold m-0 mt-1">BackupBear</h5>
    </div>
    <button class="nav-btn active" id="btn-backup"><i class="bi bi-rocket-takeoff"></i> BACKUP</button>
    <button class="nav-btn" id="btn-cloud"><i class="bi bi-cloud"></i> CLOUD</button>
    <button class="nav-btn" id="btn-restore"><i class="bi bi-arrow-counterclockwise"></i> RESTORE</button>
    <button class="nav-btn" id="btn-schedule"><i class="bi bi-clock"></i> SCHEDULE</button>
    <button class="nav-btn" id="btn-config"><i class="bi bi-gear"></i> CONFIG</button>
    <button class="nav-btn" id="btn-about"><i class="bi bi-info-circle"></i> ABOUT</button>
    <div class="mt-auto pt-3 border-top border-secondary border-opacity-25 small position-absolute bottom-0 mb-3 text-secondary" style="font-size:0.75rem;">v16.4.0<br>System Ready</div>
</div>

<div class="content">
    
    <div id="view-backup" class="view-section active">
        <h2 class="mb-3 fw-bold">System Backup</h2>
        <ul class="nav nav-pills mb-3 border-bottom border-secondary pb-2" role="tablist">
            <li class="nav-item"><button class="nav-link active fw-bold" data-bs-toggle="tab" data-bs-target="#b-dash"><i class="bi bi-speedometer2"></i> Dashboard</button></li>
            <li class="nav-item"><button class="nav-link fw-bold" data-bs-toggle="tab" data-bs-target="#b-paths"><i class="bi bi-diagram-2"></i> Paths & Engine</button></li>
            <li class="nav-item"><button class="nav-link fw-bold" data-bs-toggle="tab" data-bs-target="#b-sec"><i class="bi bi-shield-lock"></i> Profiles & Security</button></li>
        </ul>
        
        <div class="tab-content">
            <div class="tab-pane fade show active" id="b-dash">
                <div class="d-flex gap-2 mb-3 flex-shrink-0">
                    <button id="btn-run-backup" class="btn btn-success w-100 py-3 fw-bold fs-5 shadow-sm text-white">START BATCH BACKUP</button>
                    <button id="btn-run-dry" class="btn btn-outline-success py-3 fw-bold fs-5 px-4 text-white shadow-sm" title="Test without transferring data">SIMULATE</button>
                    <button id="btn-stop-backup" class="btn btn-danger w-100 py-3 fw-bold fs-5 shadow-sm text-white" style="display:none;">STOP PROCESS</button>
                </div>
                <label class="small text-secondary fw-bold mb-2 flex-shrink-0">LIVE TERMINAL OUTPUT</label>
                <pre id="job-mini-terminal" class="bg-black text-success p-3 rounded text-start border border-secondary mb-0 w-100" style="flex: 1 1 0; height: 0; overflow-y:auto; font-family:'JetBrains Mono',monospace; font-size:0.8rem; white-space:pre-wrap; word-wrap:break-word;">Ready to start...</pre>
            </div>
            
            <div class="tab-pane fade" id="b-paths">
                <div class="row mb-3 gx-3">
                    <div class="col-6">
                        <div class="card h-100 mb-0 border-secondary">
                            <div class="card-header d-flex justify-content-between align-items-center">
                                <span>Sources (What)</span>
                                <div class="btn-group">
                                    <button id="btn-add-home" class="btn btn-sm btn-outline-info" title="Home Folder"><i class="bi bi-house-door-fill"></i></button>
                                    <button id="btn-add-root" class="btn btn-sm btn-outline-danger" title="Root Folder"><i class="bi bi-hdd-network-fill"></i></button>
                                    <button id="btn-add-source-local" class="btn btn-sm btn-outline-light" title="Select Folder"><i class="bi bi-folder-plus"></i></button>
                                </div>
                            </div>
                            <div class="card-body p-2"><div id="source-container" class="dest-list"></div></div>
                        </div>
                    </div>
                    <div class="col-6">
                        <div class="card h-100 mb-0 border-secondary">
                            <div class="card-header d-flex justify-content-between align-items-center">
                                <span>Destinations (Where)</span>
                                <div>
                                    <button id="btn-add-local" class="btn btn-sm btn-warning fw-bold text-dark me-1">+ LOCAL</button>
                                    <button id="btn-prompt-cloud" class="btn btn-sm btn-warning fw-bold text-dark">+ CLOUD</button>
                                </div>
                            </div>
                            <div class="card-body p-2"><div id="dest-container" class="dest-list"></div></div>
                        </div>
                    </div>
                </div>
                <div class="card p-3 border-secondary mb-3">
                    <div class="row gx-3">
                        <div class="col-4">
                            <label class="small text-secondary fw-bold mb-2">BACKUP MODE</label>
                            <div class="btn-group w-100">
                                <input type="radio" class="btn-check" name="bkmode" id="mode-inc" checked>
                                <label class="btn btn-outline-warning btn-sm fw-bold text-dark" for="mode-inc">Incremental</label>
                                <input type="radio" class="btn-check" name="bkmode" id="mode-full">
                                <label class="btn btn-outline-warning btn-sm fw-bold text-dark" for="mode-full">Snapshot</label>
                            </div>
                        </div>
                        <div class="col-4">
                            <label class="small text-secondary fw-bold mb-2">COMPRESSION</label>
                            <select id="bak-comp" class="form-select form-select-sm">
                                <option value="none">None (1:1)</option>
                                <option value="transfer">Transfer (-z)</option>
                                <option value="archive">.tar.gz Archive</option>
                            </select>
                        </div>
                        <div class="col-4">
                            <label class="small text-secondary fw-bold mb-2">NETWORK THROTTLE</label>
                            <div class="input-group input-group-sm">
                                <input type="number" id="bak-bw-val" class="form-control" placeholder="Unlimited" min="0">
                                <select id="bak-bw-unit" class="form-select" style="max-width:70px;">
                                    <option value="M">MB/s</option>
                                    <option value="K">KB/s</option>
                                </select>
                            </div>
                        </div>
                    </div>
                    <div class="row mt-3"><div class="col-12"><div id="comp-info" class="p-2 rounded bg-black border border-secondary small text-secondary">...</div></div></div>
                </div>
            </div>
            
            <div class="tab-pane fade" id="b-sec">
                <div class="card p-4 border-secondary mb-3">
                    <h6 class="text-warning fw-bold mb-3"><i class="bi bi-journal-bookmark-fill"></i> Job Profiles</h6>
                    <div class="d-flex gap-2 align-items-center mb-3">
                        <input type="text" id="job-name-input" class="form-control form-control-sm" placeholder="New Profile Name..." style="max-width: 250px;">
                        <button class="btn btn-success btn-sm fw-bold px-3 text-white" id="btn-save-job">SAVE NEW / OVERWRITE</button>
                        <span id="job-load-msg" class="text-success fw-bold ms-1" style="display:none; font-size: 0.85rem;">[OK] Loaded</span>
                    </div>
                    
                    <div id="job-list-container" class="row gy-2 mb-4">
                        </div>

                    <hr class="border-secondary mb-4">
                    <h6 class="text-info fw-bold mb-3"><i class="bi bi-shield-lock-fill"></i> Job Encryption</h6>
                    <div class="small text-secondary mb-3">This passphrase will be securely embedded into the Job Profile so automated tasks can scramble your files on the fly.</div>
                    <div class="row gx-4">
                        <div class="col-6">
                            <div class="form-check mb-2 mt-1">
                                <input class="form-check-input" type="checkbox" id="bak-enc">
                                <label class="form-check-label text-white fw-bold">Scramble Destination</label>
                            </div>
                        </div>
                        <div class="col-6">
                            <div class="input-group input-group-sm mb-2">
                                <input type="password" id="bak-key" class="form-control" placeholder="Encryption Passphrase">
                                <button class="btn btn-outline-secondary toggle-pw" type="button" tabindex="-1"><i class="bi bi-eye"></i></button>
                            </div>
                            <div class="input-group input-group-sm">
                                <input type="password" id="bak-key-confirm" class="form-control" placeholder="Confirm Passphrase">
                                <button class="btn btn-outline-secondary toggle-pw" type="button" tabindex="-1"><i class="bi bi-eye"></i></button>
                            </div>
                            <div id="pw-status" class="small fw-bold mt-1 text-end"></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div id="backup-metrics-panel" class="card mt-2 p-3 border-secondary flex-shrink-0">
            <div class="row text-center align-items-center">
                <div class="col-3"><span class="metric-lbl">STATUS</span><div class="metric-val text-secondary" id="val-stage">Ready</div></div>
                <div class="col-3"><span class="metric-lbl">SPEED</span><div class="metric-val text-white" id="val-spd">--</div></div>
                <div class="col-2"><span class="metric-lbl">ETA</span><div class="metric-val text-warning" id="val-eta">--</div></div>
                <div class="col-4 text-start"><span class="metric-lbl">LOGS</span><div id="val-raw" class="text-white small text-truncate font-monospace" style="opacity:0.7;">System Ready</div></div>
            </div>
        </div>
    </div>

    <div id="view-cloud" class="view-section">
        <h2 class="mb-3 fw-bold flex-shrink-0">Cloud Management</h2>
        <ul class="nav nav-pills mb-3 border-bottom border-secondary pb-2 flex-shrink-0" role="tablist">
            <li class="nav-item"><button class="nav-link active fw-bold" data-bs-toggle="tab" data-bs-target="#c-remotes"><i class="bi bi-hdd-network"></i> Connected Accounts</button></li>
            <li class="nav-item"><button class="nav-link fw-bold" data-bs-toggle="tab" data-bs-target="#c-add"><i class="bi bi-plus-circle"></i> Add Provider</button></li>
            <li class="nav-item"><button class="nav-link fw-bold" data-bs-toggle="tab" data-bs-target="#c-browse"><i class="bi bi-folder-symlink"></i> File Explorer</button></li>
        </ul>
        <div class="tab-content">
            <div class="tab-pane fade show active" id="c-remotes">
                <div id="connected-remotes-container" class="row gy-3"></div>
            </div>
            <div class="tab-pane fade" id="c-add">
                <div class="row mb-3 gx-3 gy-3">
                    <div class="col-6">
                        <div class="card p-3 border-secondary h-100">
                            <h6 class="text-white small fw-bold">GOOGLE DRIVE</h6>
                            <input id="g-name" class="form-control form-control-sm mb-2" placeholder="user@gmail.com">
                            <button id="btn-g-auth" class="btn btn-warning btn-sm w-100 fw-bold text-dark">Link Drive</button>
                        </div>
                    </div>
                    <div class="col-6">
                        <div class="card p-3 border-secondary h-100">
                            <h6 class="text-white small fw-bold">NEXTCLOUD</h6>
                            <input id="n-url" class="form-control form-control-sm mb-1" placeholder="URL">
                            <input id="n-user" class="form-control form-control-sm mb-1" placeholder="User">
                            <div class="input-group input-group-sm mb-2">
                                <input id="n-pass" type="password" class="form-control" placeholder="App Pass">
                                <button class="btn btn-outline-secondary toggle-pw" type="button" tabindex="-1"><i class="bi bi-eye"></i></button>
                            </div>
                            <button id="btn-n-auth" class="btn btn-warning btn-sm w-100 fw-bold text-dark">Connect Nextcloud</button>
                        </div>
                    </div>
                    <div class="col-6">
                        <div class="card p-3 border-secondary h-100">
                            <h6 class="text-white small fw-bold">BACKBLAZE B2</h6>
                            <input id="b2-name" class="form-control form-control-sm mb-1" placeholder="Profile Name">
                            <input id="b2-acc" class="form-control form-control-sm mb-1" placeholder="Key ID / Account">
                            <div class="input-group input-group-sm mb-2">
                                <input id="b2-key" type="password" class="form-control" placeholder="Application Key">
                                <button class="btn btn-outline-secondary toggle-pw" type="button" tabindex="-1"><i class="bi bi-eye"></i></button>
                            </div>
                            <button id="btn-b2-auth" class="btn btn-warning btn-sm w-100 fw-bold text-dark">Connect B2</button>
                        </div>
                    </div>
                    <div class="col-6">
                        <div class="card p-3 border-secondary h-100">
                            <h6 class="text-white small fw-bold">GENERIC WEBDAV</h6>
                            <input id="dav-name" class="form-control form-control-sm mb-1" placeholder="Profile Name">
                            <input id="dav-url" class="form-control form-control-sm mb-1" placeholder="URL">
                            <input id="dav-user" class="form-control form-control-sm mb-1" placeholder="User">
                            <div class="input-group input-group-sm mb-2">
                                <input id="dav-pass" type="password" class="form-control" placeholder="App Pass">
                                <button class="btn btn-outline-secondary toggle-pw" type="button" tabindex="-1"><i class="bi bi-eye"></i></button>
                            </div>
                            <button id="btn-dav-auth" class="btn btn-warning btn-sm w-100 fw-bold text-dark">Connect WebDAV</button>
                        </div>
                    </div>
                </div>
            </div>
            <div class="tab-pane fade" id="c-browse">
                <div class="card border-secondary h-100 d-flex flex-column">
                    <div class="card-header flex-shrink-0">Cloud File Explorer</div>
                    <div class="card-body p-2 d-flex flex-column" style="overflow: hidden;">
                        <div id="cloud-tabs" class="cloud-tabs flex-shrink-0"></div>
                        <div id="file-view" class="file-grid flex-grow-1" style="max-height: none; overflow-y: auto;"></div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <div id="view-restore" class="view-section">
        <h2 class="mb-3 fw-bold flex-shrink-0">System Restore</h2>

        <div class="card p-3 mb-3 border-secondary bg-black flex-shrink-0">
            <div class="d-flex justify-content-between align-items-center">
                <div>
                    <h6 class="text-warning fw-bold mb-0"><i class="bi bi-journal-arrow-up"></i> Load Backup Profile</h6>
                    <div class="small text-secondary">Auto-fill paths and keys from a saved job</div>
                </div>
                <select id="res-profile-selector" class="form-select form-select-sm" style="max-width: 250px;">
                    <option value="">-- Select Saved Job --</option>
                </select>
            </div>
        </div>

        <div class="row mb-3 gx-3 flex-shrink-0">
            <div class="col-6">
                <div class="card h-100 mb-0 border-secondary">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <span>Source (From)</span>
                        <div>
                            <button id="btn-browse-restore-src" class="btn btn-sm btn-outline-light" title="Browse Local Files"><i class="bi bi-folder2-open"></i></button>
                            <button id="btn-cloud-restore-src" class="btn btn-sm btn-warning text-dark fw-bold" title="Browse Cloud Remote"><i class="bi bi-cloud"></i></button>
                        </div>
                    </div>
                    <div class="card-body p-3">
                        <input type="text" id="res-src" class="form-control mb-2" placeholder="Local Path OR Remote Name:">
                        <div class="small text-secondary">Select the folder or remote cloud drive containing your backup files.</div>
                    </div>
                </div>
            </div>
            <div class="col-6">
                <div class="card h-100 mb-0 border-secondary">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <span>Destination (To)</span>
                        <button id="btn-browse-restore-dest" class="btn btn-sm btn-outline-light" title="Browse Local"><i class="bi bi-folder2-open"></i></button>
                    </div>
                    <div class="card-body p-3">
                        <input type="text" id="res-dest" class="form-control mb-2" placeholder="Restore Target Path">
                        <div class="small text-secondary">Select where the engine should place the restored files on your computer.</div>
                    </div>
                </div>
            </div>
        </div>
        <div class="card p-3 mb-3 border-secondary flex-shrink-0">
            <div class="row gx-3">
                <div class="col-5">
                    <label class="small text-secondary fw-bold mb-2">RESTORE FORMAT</label>
                    <div class="btn-group w-100">
                        <input type="radio" class="btn-check" name="resformat" id="res-fmt-folder" checked>
                        <label class="btn btn-outline-warning btn-sm fw-bold text-dark" for="res-fmt-folder">Folder (1:1)</label>
                        <input type="radio" class="btn-check" name="resformat" id="res-fmt-archive">
                        <label class="btn btn-outline-warning btn-sm fw-bold text-dark" for="res-fmt-archive">.tar.gz Archive</label>
                    </div>
                </div>
                <div class="col-7">
                    <label class="small text-secondary fw-bold mb-2 d-block">DECRYPTION LAYER</label>
                    <div class="input-group input-group-sm mb-1">
                        <div class="input-group-text bg-dark border-secondary">
                            <input class="form-check-input mt-0" type="checkbox" id="res-enc">
                        </div>
                        <input type="password" id="res-key" class="form-control" placeholder="Passphrase to Decrypt">
                        <button class="btn btn-outline-secondary toggle-pw" type="button" tabindex="-1"><i class="bi bi-eye"></i></button>
                    </div>
                </div>
            </div>
            <div class="row mt-2"><div class="col-12"><div id="res-info" class="p-2 rounded bg-black border border-secondary small text-secondary">...</div></div></div>
        </div>
        
        <div class="d-flex gap-2 mb-3 flex-shrink-0">
            <button id="btn-run-restore" class="btn btn-success w-100 py-3 fw-bold fs-5 text-white">START SYSTEM RESTORE</button>
            <button id="btn-stop-restore" class="btn btn-danger w-100 py-3 fw-bold fs-5 text-white" style="display:none;">STOP PROCESS</button>
        </div>
        
        <div class="card p-3 border-secondary bg-black mt-auto flex-shrink-0">
            <div class="row text-center align-items-center">
                <div class="col-4"><span class="metric-lbl">RESTORE STATUS</span><div class="metric-val text-secondary" id="res-val-stage">Ready</div></div>
                <div class="col-4"><span class="metric-lbl">SPEED</span><div class="metric-val text-white" id="res-val-spd">--</div></div>
                <div class="col-4"><span class="metric-lbl">ETA</span><div class="metric-val text-warning" id="res-val-eta">--</div></div>
            </div>
        </div>
    </div>

    <div id="view-schedule" class="view-section">
        <h2 class="mb-3 fw-bold flex-shrink-0">System Schedule</h2>
        <div class="row gx-3 h-100">
            <div class="col-md-5">
                <div class="card p-4 border-secondary mb-3">
                    <h6 class="text-warning fw-bold mb-3"><i class="bi bi-clock-fill"></i> Add Scheduled Job</h6>
                    <label class="small text-secondary fw-bold mb-1">PROFILE TO AUTOMATE</label>
                    <select id="cron-profile" class="form-select form-select-sm mb-3">
                        <option value="">-- Select Saved Job --</option>
                    </select>

                    <label class="small text-secondary fw-bold mb-1">FREQUENCY</label>
                    <select id="cron-freq" class="form-select form-select-sm mb-3">
                        <option value="daily">Daily</option>
                        <option value="weekly">Weekly</option>
                        <option value="monthly">Monthly</option>
                    </select>

                    <div id="div-cron-day" style="display:none;" class="mb-3">
                        <label class="small text-secondary fw-bold mb-1" id="lbl-cron-day">DAY</label>
                        <select id="cron-day" class="form-select form-select-sm"></select>
                    </div>

                    <label class="small text-secondary fw-bold mb-1">TIME</label>
                    <input type="time" id="cron-time" class="form-control form-control-sm mb-4" value="02:00">
                    
                    <button id="btn-add-cron" class="btn btn-success w-100 fw-bold py-2 text-white">ADD TO CRONTAB</button>
                </div>
            </div>
            
            <div class="col-md-7 h-100">
                <div class="card h-100 border-secondary d-flex flex-column">
                    <div class="card-header flex-shrink-0">Active Background Jobs</div>
                    <div class="card-body p-2 flex-grow-1" id="active-crons-container" style="overflow-y:auto; max-height: none;">
                        <div class="p-3 text-center text-secondary">No automated jobs scheduled.</div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <div id="view-config" class="view-section">
        <h2 class="mb-3 fw-bold flex-shrink-0">System Configuration</h2>
        
        <ul class="nav nav-pills mb-3 border-bottom border-secondary pb-2 flex-shrink-0" role="tablist">
            <li class="nav-item"><button class="nav-link active fw-bold" data-bs-toggle="tab" data-bs-target="#cfg-general"><i class="bi bi-gear-fill"></i> App Settings</button></li>
            <li class="nav-item"><button class="nav-link fw-bold" data-bs-toggle="tab" data-bs-target="#cfg-excludes"><i class="bi bi-funnel-fill"></i> Global Excludes</button></li>
            <li class="nav-item"><button class="nav-link fw-bold" data-bs-toggle="tab" data-bs-target="#cfg-logs"><i class="bi bi-file-text-fill"></i> Logging</button></li>
        </ul>

        <div class="tab-content">
            
            <div class="tab-pane fade show active" id="cfg-general">
                <div class="card p-4 border-secondary mb-3">
                    
                    <h6 class="text-info fw-bold mt-1"><i class="bi bi-github"></i> Auto-Updates</h6>
                    <div class="form-check form-switch mb-1">
                        <input class="form-check-input" type="checkbox" id="cfg-updates">
                        <label class="text-white fw-bold">Check GitHub on Launch</label>
                    </div>
                    <div class="small text-secondary mb-4">BackupBear will silently ping GitHub. If an update is found, it prompts you to review notes or auto-compile.</div>
                    
                    <hr class="border-secondary">
                    
                    <div class="form-check form-switch mb-1 mt-3">
                        <input class="form-check-input" type="checkbox" id="cfg-tray">
                        <label class="text-white fw-bold">Minimize to System Tray</label>
                    </div>
                    <div class="small text-secondary mb-4">Closing the app window will hide BackupBear in your system tray so background tasks and crons run uninterrupted.</div>
                    
                    <div class="form-check form-switch mb-1">
                        <input class="form-check-input" type="checkbox" id="cfg-notify">
                        <label class="text-white fw-bold">Desktop Notifications</label>
                    </div>
                    <div class="small text-secondary mb-4">Show native Linux desktop pop-ups when a backup job starts, finishes, or encounters an error.</div>
                    
                    <hr class="border-secondary">
                    
                    <h6 class="text-success fw-bold mt-3"><i class="bi bi-broadcast"></i> Ntfy.sh Push Notifications</h6>
                    <div class="small text-secondary mb-2">The open-source standard for push notifications to your phone. Enter your topic URL to receive alerts.</div>
                    <input type="text" id="cfg-ntfy" class="form-control form-control-sm mb-4" placeholder="https://ntfy.sh/your_custom_topic">
                    
                    <h6 class="text-warning fw-bold mt-2"><i class="bi bi-webhook"></i> Custom Webhook</h6>
                    <div class="small text-secondary mb-2">Paste a Discord, Slack, or Mattermost Webhook URL here to receive automated JSON payload alerts.</div>
                    <input type="text" id="cfg-webhook" class="form-control form-control-sm mb-2" placeholder="https://...">
                </div>
                <button id="btn-save-config" class="btn btn-warning w-100 py-2 fw-bold text-dark">SAVE CONFIGURATION</button>
            </div>

            <div class="tab-pane fade" id="cfg-excludes">
                <div class="row gx-3 m-0 h-100 pb-3 w-100">
                    <div class="col-6 h-100">
                        <div class="card border-secondary h-100 d-flex flex-column">
                            <div class="card-header flex-shrink-0">System Defaults</div>
                            <div class="card-body p-2 d-flex flex-column" style="overflow:hidden;">
                                <p class="small text-secondary px-2 mb-2 flex-shrink-0">These system artifacts and temporary files are skipped by default to prevent endless loops and errors.</p>
                                <div id="sys-excludes-container" class="ex-list p-1 flex-grow-1" style="overflow-y:auto;"></div>
                            </div>
                        </div>
                    </div>
                    <div class="col-6 h-100">
                        <div class="card border-secondary h-100 d-flex flex-column">
                            <div class="card-header flex-shrink-0">Custom Rules</div>
                            <div class="card-body p-2 d-flex flex-column" style="overflow:hidden;">
                                <p class="small text-secondary px-2 mb-2 flex-shrink-0">Add your own paths to ignore. Use <code>*.ext</code> for files, or <code>/path/**</code> for directories.</p>
                                <div class="input-group input-group-sm mb-2 flex-shrink-0">
                                    <input type="text" id="custom-exclude-input" class="form-control" placeholder="e.g. *.mp4 or /Downloads/**">
                                    <button id="btn-add-custom-exclude" class="btn btn-warning fw-bold text-dark">ADD</button>
                                </div>
                                <div id="custom-excludes-container" class="ex-list p-1 flex-grow-1" style="overflow-y:auto;"></div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>

            <div class="tab-pane fade" id="cfg-logs">
                <div class="card p-4 border-secondary mb-3">
                    <div class="form-check form-switch mb-3">
                        <input class="form-check-input" type="checkbox" id="cfg-log-enable">
                        <label class="text-white fw-bold">Enable Cron Job Logging</label>
                    </div>
                    <label class="small text-secondary fw-bold mb-1">Global Log Output File</label>
                    <div class="input-group input-group-sm mb-2">
                        <input type="text" id="cfg-log-path" class="form-control text-secondary font-monospace" placeholder="/path/to/log.txt">
                        <button class="btn btn-secondary" id="btn-browse-log"><i class="bi bi-folder2-open"></i></button>
                    </div>
                    <div class="small text-secondary">All headless cron tasks will append their output to this plain-text file.</div>
                </div>
                <button id="btn-save-log-config" class="btn btn-warning w-100 py-2 fw-bold text-dark">SAVE LOGGING PREFERENCES</button>
            </div>
        </div>
    </div>

    <div id="view-about" class="view-section h-100">
        <div class="d-flex flex-column h-100 align-items-center justify-content-center">
            <img src="logo.png" class="hero-logo" onerror="this.src='logo.svg'" style="width: 180px; margin-bottom: 20px;">
            <h2 class="fw-bold mb-1">BackupBear</h2>
            <p class="text-secondary mb-4">by Aureus K'Tharr</p>
            
            <div class="card p-4 text-center border-secondary shadow mb-4" style="min-width: 320px;">
                <div class="mb-3">
                    <span class="text-secondary fw-bold small">VERSION</span><br>
                    <span class="fw-bold text-white fs-5">16.4.0</span>
                </div>
                <div class="mb-3">
                    <span class="text-secondary fw-bold small">BUILD DATE</span><br>
                    <span class="font-monospace text-warning fs-6">2026-02-24</span>
                </div>
                <div>
                    <span class="text-secondary fw-bold small">ENGINE</span><br>
                    <span class="badge bg-primary mt-1 mb-1 fw-bold text-white">Powered by Electron</span><br>
                    <span class="font-monospace text-white fs-6">Rclone + Rsync + Tar + Cron</span>
                </div>
            </div>
            
            <span class="badge bg-dark border border-secondary text-secondary p-2">
                Press <b>F12</b> to toggle Debug Console
            </span>
        </div>
    </div>

</div>

<script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
<script src="./renderer.js"></script>
</body>
</html>
EOF

echo "Writing Logic (renderer.js)..."
cat <<'EOF' > renderer.js
let destinations = []; 
let sources = [];
const defExcludes = [
    { pattern: '/proc/**', enabled: true, sys: true, label: 'System Procs (/proc)' },
    { pattern: '/sys/**', enabled: true, sys: true, label: 'Devices (/sys)' },
    { pattern: '/dev/**', enabled: true, sys: true, label: 'Hardware (/dev)' },
    { pattern: '/run/**', enabled: true, sys: true, label: 'Runtime (/run)' },
    { pattern: '/tmp/**', enabled: true, sys: true, label: 'Temp Files (/tmp)' },
    { pattern: '/mnt/**', enabled: true, sys: true, label: 'Mounts (/mnt)' },
    { pattern: '/media/**', enabled: true, sys: true, label: 'Media (/media)' },
    { pattern: '/lost+found/**', enabled: true, sys: true, label: 'Lost+Found' },
    { pattern: '.cache/**', enabled: true, sys: true, label: 'App Caches' },
    { pattern: '.Trash-*/**', enabled: true, sys: true, label: 'Trash Bins' },
    { pattern: '*.log', enabled: true, sys: true, label: '*.log' },
    { pattern: '*.tmp', enabled: true, sys: true, label: '*.tmp' },
    { pattern: '*.bak', enabled: true, sys: true, label: '*.bak' },
    { pattern: 'System Volume Information/**', enabled: true, sys: true, label: 'Win Sys Vol' },
    { pattern: '$RECYCLE.BIN/**', enabled: true, sys: true, label: 'Win Recycle Bin' }
];
let excludes = JSON.parse(JSON.stringify(defExcludes));
let profiles = {}; 
let schedules = []; 
let cloudModalTarget = 'backup';
window.defaultLoaded = false;

window.bear.getHome().then(h => { 
    sources.push({ type: 'home', path: h, enabled: true }); 
    renderSources(); 
});

['backup', 'cloud', 'restore', 'schedule', 'config', 'about'].forEach(v => { 
    document.getElementById(`btn-${v}`).addEventListener('click', () => switchView(v)); 
});

function switchView(v) {
    document.querySelectorAll('.view-section').forEach(e => e.classList.remove('active')); 
    document.getElementById(`view-${v}`).classList.add('active');
    document.querySelectorAll('.nav-btn').forEach(e => e.classList.remove('active')); 
    document.getElementById(`btn-${v}`).classList.add('active');
    
    if(v==='cloud') loadRemotes(); 
    if(v==='schedule') loadSchedule();
}

// === VIEW PASSWORD LOGIC ===
document.querySelectorAll('.toggle-pw').forEach(btn => {
    btn.addEventListener('click', function() {
        const input = this.previousElementSibling;
        const icon = this.querySelector('i');
        if (input.type === 'password') {
            input.type = 'text';
            icon.classList.replace('bi-eye', 'bi-eye-slash');
        } else {
            input.type = 'password';
            icon.classList.replace('bi-eye-slash', 'bi-eye');
        }
    });
});

// === CONFIG TAB LOGIC ===
async function loadConfig() { 
    const c = await window.bear.invoke('get-config'); 
    document.getElementById('cfg-tray').checked = c.tray; 
    document.getElementById('cfg-updates').checked = c.updates; 
    document.getElementById('cfg-notify').checked = c.notify; 
    document.getElementById('cfg-webhook').value = c.webhook || ''; 
    document.getElementById('cfg-ntfy').value = c.ntfy || ''; 
    document.getElementById('cfg-log-enable').checked = c.logEnabled !== false;
    document.getElementById('cfg-log-path').value = c.logPath || '';
}
loadConfig();

document.getElementById('cfg-log-enable').addEventListener('change', (e) => { 
    document.getElementById('cfg-log-path').disabled = !e.target.checked; 
    document.getElementById('btn-browse-log').disabled = !e.target.checked; 
});
document.getElementById('btn-browse-log').addEventListener('click', async () => { 
    const p = await window.bear.invoke('dialog:save', 'history.log'); 
    if(p) document.getElementById('cfg-log-path').value = p; 
});

const saveConfigAction = async (btnId) => {
    await window.bear.invoke('save-config', { 
        tray: document.getElementById('cfg-tray').checked, 
        updates: document.getElementById('cfg-updates').checked, 
        notify: document.getElementById('cfg-notify').checked, 
        webhook: document.getElementById('cfg-webhook').value.trim(), 
        ntfy: document.getElementById('cfg-ntfy').value.trim(),
        logEnabled: document.getElementById('cfg-log-enable').checked,
        logPath: document.getElementById('cfg-log-path').value.trim()
    }); 
    const b = document.getElementById(btnId); 
    const orig = b.innerText;
    b.innerText = "[OK] SAVED!"; 
    b.classList.replace('btn-warning', 'btn-success');
    b.classList.replace('text-dark', 'text-white');
    setTimeout(() => { 
        b.innerText = orig; 
        b.classList.replace('btn-success', 'btn-warning'); 
        b.classList.replace('text-white', 'text-dark');
    }, 2000); 
};
document.getElementById('btn-save-config').addEventListener('click', () => saveConfigAction('btn-save-config'));
document.getElementById('btn-save-log-config').addEventListener('click', () => saveConfigAction('btn-save-log-config'));

// === PROFILES / JOBS LOGIC ===
async function loadProfiles() {
    profiles = await window.bear.invoke('get-profiles');
    const conf = await window.bear.invoke('get-config');
    
    // Render Job List into the Backup Tab
    const listContainer = document.getElementById('job-list-container');
    listContainer.innerHTML = '';
    
    const keys = Object.keys(profiles);
    if(keys.length === 0) {
        listContainer.innerHTML = '<div class="col-12"><div class="text-secondary small">No saved profiles yet. Add sources and destinations, then save your job!</div></div>';
    } else {
        listContainer.innerHTML = keys.map(k => `
            <div class="col-md-6">
                <div class="card p-2 border-secondary d-flex flex-row align-items-center bg-black cursor-pointer" onclick="loadJob('${k}')" title="Click to load job into active engine">
                    <input type="radio" name="defaultJob" class="form-check-input mt-0 me-3" ${conf.defaultProfile === k ? 'checked' : ''} onclick="setDefaultJob(event, '${k}')" title="Set as default on app startup">
                    <div class="flex-grow-1 text-white fw-bold text-truncate">${k}</div>
                    <button class="btn btn-sm btn-outline-danger p-1 px-2 ms-2" onclick="delJob(event, '${k}')" title="Delete Profile"><i class="bi bi-trash"></i></button>
                </div>
            </div>
        `).join('');
    }
    
    // Schedule Tab & Restore Tab Population
    const s2 = document.getElementById('cron-profile'); 
    s2.innerHTML = '<option value="">-- Select Saved Job --</option>';
    
    const s3 = document.getElementById('res-profile-selector');
    if(s3) s3.innerHTML = '<option value="">-- Select Saved Job --</option>';

    keys.forEach(k => { 
        s2.innerHTML += `<option value="${k}">${k}</option>`; 
        if(s3) s3.innerHTML += `<option value="${k}">${k}</option>`; 
    });
    
    // Auto-load default profile on app startup
    if(conf.defaultProfile && profiles[conf.defaultProfile] && !window.defaultLoaded) {
        window.defaultLoaded = true;
        loadJob(conf.defaultProfile);
    }
}
loadProfiles();

window.loadJob = (name) => {
    const p = profiles[name]; 
    if (!p) {
        document.getElementById('btn-run-backup').innerText = "START BATCH BACKUP";
        return;
    }
    
    sources = (p.sources || []).map(s => ({ ...s, enabled: s.enabled !== false })); 
    destinations = (p.destinations || []).map(d => ({ ...d, enabled: d.enabled !== false })); 
    
    let loadedEx = p.excludes || [];
    if (loadedEx.length > 0 && typeof loadedEx[0] === 'string') { 
        loadedEx = loadedEx.map(str => ({ pattern: str, enabled: true, sys: false })); 
    }
    excludes = JSON.parse(JSON.stringify(defExcludes));
    excludes.forEach(sysDef => { 
        const found = loadedEx.find(l => l.pattern === sysDef.pattern); 
        if(found) sysDef.enabled = found.enabled; 
    });
    loadedEx.filter(l => !l.sys && !excludes.find(sysDef=>sysDef.pattern === l.pattern)).forEach(cust => excludes.push(cust));

    renderSources(); 
    renderDestinations(); 
    renderExcludes();
    
    document.getElementById('mode-full').checked = (p.mode === 'full'); 
    document.getElementById('mode-inc').checked = (p.mode === 'inc'); 
    document.getElementById('bak-comp').value = p.comp || 'none'; 
    document.getElementById('bak-enc').checked = p.encrypt || false; 
    document.getElementById('bak-key').value = p.key || ''; 
    document.getElementById('bak-key-confirm').value = p.key || ''; 
    document.getElementById('bak-bw-val').value = p.bwVal || ''; 
    document.getElementById('bak-bw-unit').value = p.bwUnit || 'M'; 
    document.getElementById('job-name-input').value = name; 
    
    document.getElementById('btn-run-backup').innerText = `START: ${name}`;
    updateCompInfo(); checkPw();
    
    const loadMsg = document.getElementById('job-load-msg');
    loadMsg.style.display = 'inline-block';
    setTimeout(() => { loadMsg.style.display = 'none'; }, 2000);
};

window.setDefaultJob = async (e, name) => {
    e.stopPropagation(); // Prevents loading the job when simply setting default
    await window.bear.invoke('save-config', { defaultProfile: name });
};

window.delJob = async (e, name) => {
    e.stopPropagation();
    if(confirm(`Delete profile: ${name}?`)) {
        profiles = await window.bear.invoke('save-profile', { name: name, delete: true }); 
        
        // Remove from defaults if it was the default
        const conf = await window.bear.invoke('get-config');
        if(conf.defaultProfile === name) {
            await window.bear.invoke('save-config', { defaultProfile: '' });
        }
        
        loadProfiles();
        if(document.getElementById('job-name-input').value === name) {
            document.getElementById('job-name-input').value = '';
            document.getElementById('btn-run-backup').innerText = "START BATCH BACKUP";
        }
    }
};

document.getElementById('btn-save-job').addEventListener('click', async () => {
    const n = document.getElementById('job-name-input').value.trim(); 
    if (!n) return alert("Enter a name!");
    const d = { 
        sources: JSON.parse(JSON.stringify(sources)), 
        destinations: JSON.parse(JSON.stringify(destinations)), 
        excludes: JSON.parse(JSON.stringify(excludes)), 
        mode: document.getElementById('mode-full').checked?'full':'inc', 
        comp: document.getElementById('bak-comp').value, 
        encrypt: document.getElementById('bak-enc').checked, 
        key: document.getElementById('bak-key').value, 
        bwVal: document.getElementById('bak-bw-val').value, 
        bwUnit: document.getElementById('bak-bw-unit').value 
    };
    profiles = await window.bear.invoke('save-profile', { name: n, data: d }); 
    loadProfiles(); 
    
    const b = document.getElementById('btn-save-job'); 
    b.innerText = "[OK] SAVED!"; 
    b.classList.replace('btn-success', 'btn-primary'); 
    setTimeout(() => { 
        b.innerText = "SAVE NEW / OVERWRITE"; 
        b.classList.replace('btn-primary', 'btn-success'); 
    }, 2000);
});

const pw1 = document.getElementById('bak-key'); 
const pw2 = document.getElementById('bak-key-confirm'); 
const pwStat = document.getElementById('pw-status');

function checkPw() { 
    if (!document.getElementById('bak-enc').checked) { 
        pw1.classList.remove('is-invalid','is-valid'); 
        pw2.classList.remove('is-invalid','is-valid'); 
        pwStat.innerHTML=''; 
        return; 
    } 
    if (pw1.value==='' && pw2.value==='') { pwStat.innerHTML=''; return; } 
    if (pw1.value===pw2.value && pw1.value.length>0) { 
        pw1.classList.remove('is-invalid'); pw2.classList.remove('is-invalid'); 
        pw1.classList.add('is-valid'); pw2.classList.add('is-valid'); 
        pwStat.innerHTML='<span class="text-success">Match</span>'; 
    } else { 
        pw1.classList.remove('is-valid'); pw2.classList.remove('is-valid'); 
        if (pw2.value.length>0) { 
            pw2.classList.add('is-invalid'); 
            pwStat.innerHTML='<span class="text-danger">Mismatch</span>'; 
        } else { 
            pw2.classList.remove('is-invalid'); 
            pwStat.innerHTML=''; 
        } 
    } 
}

pw1.addEventListener('input', () => { document.getElementById('bak-enc').checked=true; checkPw(); updateCompInfo(); }); 
pw2.addEventListener('input', () => { document.getElementById('bak-enc').checked=true; checkPw(); updateCompInfo(); }); 

function updateCompInfo() { 
    const c = document.getElementById('bak-comp').value; 
    const isInc = document.getElementById('mode-inc').checked;
    const isEnc = document.getElementById('bak-enc').checked;
    let text = "";
    if (c === 'archive') {
        document.getElementById('mode-full').checked = true; document.getElementById('mode-inc').disabled = true; 
        text += '<span class="text-warning"><b>ARCHIVE MODE:</b> Packs everything into a single .tar.gz file. <b>This forces Snapshot mode.</b> Incremental tracking is disabled.</span> ';
    } else {
        document.getElementById('mode-inc').disabled = false;
        if (c === 'transfer') { text += '<span class="text-info"><b>TRANSFER COMPRESSION:</b> Compresses files <i>during network transit</i>, then unzips them at the destination. <b>Best for remote NAS.</b></span> '; } 
        else { text += '<span class="text-success"><b>NO COMPRESSION:</b> Pure 1:1 file copying. <b>Best and fastest for local USB drives.</b></span> '; }
    }
    if (isEnc) { text += '<br><span class="text-danger mt-1 d-block"><b>ENCRYPTION ACTIVE:</b> Your destination files will be scrambled names and unreadable without BackupBear or your Rclone passphrase.</span>'; }
    document.getElementById('comp-info').innerHTML = text; 
}

document.getElementById('bak-comp').addEventListener('change', updateCompInfo); 
document.getElementById('mode-inc').addEventListener('change', updateCompInfo); 
document.getElementById('mode-full').addEventListener('change', updateCompInfo); 
document.getElementById('bak-enc').addEventListener('change', updateCompInfo); 
updateCompInfo();

window.tglSrc = (i) => { sources[i].enabled = !sources[i].enabled; }; window.rmSrc = (i) => { sources.splice(i,1); renderSources(); };
window.tglDest = (i) => { destinations[i].enabled = !destinations[i].enabled; }; window.rmDest = (i) => { destinations.splice(i,1); renderDestinations(); };
window.tglEx = (i) => { excludes[i].enabled = !excludes[i].enabled; }; window.rmEx = (i) => { excludes.splice(i,1); renderExcludes(); };

function renderSources() { 
    document.getElementById('source-container').innerHTML = sources.map((s,i)=>`<div class="dest-item"><i class="bi ${s.path === '/' ? 'bi-hdd-network-fill text-danger' : s.type === 'home' ? 'bi-house-door-fill text-info' : 'bi-folder-fill'} dest-icon"></i><div class="dest-path text-white" title="${s.path}">${s.path}</div><input type="checkbox" class="dest-check" ${s.enabled!==false?'checked':''} onchange="tglSrc(${i})"><button class="btn btn-sm text-danger ms-2 p-0" onclick="rmSrc(${i})"><i class="bi bi-x-lg"></i></button></div>`).join(''); 
}
function renderDestinations() { 
    document.getElementById('dest-container').innerHTML = destinations.map((d,i)=>`<div class="dest-item"><i class="bi ${d.type==='cloud'?'bi-cloud-fill text-warning':'bi-hdd-fill text-light'} dest-icon"></i><div class="dest-path text-white" title="${d.path}">${d.path}</div><input type="checkbox" class="dest-check" ${d.enabled!==false?'checked':''} onchange="tglDest(${i})"><button class="btn btn-sm text-danger ms-2 p-0" onclick="rmDest(${i})"><i class="bi bi-x-lg"></i></button></div>`).join(''); 
}
function renderExcludes() { 
    document.getElementById('sys-excludes-container').innerHTML = excludes.filter(e=>e.sys).map((e,i)=>`<div class="dest-item py-1"><i class="bi bi-shield-lock text-secondary me-2"></i><div class="dest-path text-white">${e.label}</div><input type="checkbox" class="dest-check" ${e.enabled?'checked':''} onchange="tglEx(${excludes.indexOf(e)})"></div>`).join(''); 
    document.getElementById('custom-excludes-container').innerHTML = excludes.filter(e=>!e.sys).map((e,i)=>`<div class="dest-item py-1"><i class="bi bi-file-earmark-x text-warning me-2"></i><div class="dest-path text-white font-monospace">${e.pattern}</div><input type="checkbox" class="dest-check" ${e.enabled?'checked':''} onchange="tglEx(${excludes.indexOf(e)})"><button class="btn btn-sm text-danger ms-2 p-0" onclick="rmEx(${excludes.indexOf(e)})"><i class="bi bi-x-lg"></i></button></div>`).join(''); 
}

document.getElementById('btn-add-custom-exclude').addEventListener('click', () => { 
    const v = document.getElementById('custom-exclude-input').value.trim(); 
    if(v) { 
        excludes.push({pattern:v, enabled:true, sys:false}); 
        document.getElementById('custom-exclude-input').value=''; 
        renderExcludes(); 
    } 
}); 
renderExcludes();

document.getElementById('btn-add-source-local').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) { sources.push({type:'folder',path:p,enabled:true}); renderSources(); }});
document.getElementById('btn-add-home').addEventListener('click', async () => { const h = await window.bear.getHome(); if (!sources.find(s=>s.path===h)) { sources.push({type:'home',path:h,enabled:true}); renderSources(); }});
document.getElementById('btn-add-root').addEventListener('click', () => { if (!sources.find(s=>s.path==='/')) { sources.push({type:'system',path:'/',enabled:true}); renderSources(); }});

document.getElementById('btn-add-local').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) { destinations.push({type:'local',path:p,enabled:true}); renderDestinations(); }});

// CLOUD AUTH BUTTONS
document.getElementById('btn-prompt-cloud').addEventListener('click', async () => { 
    cloudModalTarget = 'backup'; 
    const r = await window.bear.invoke('rclone-list'); 
    const s = document.getElementById('modal-cloud-list'); 
    s.innerHTML = r.map(x=>`<option value="${x}">${x}</option>`).join(''); 
    new bootstrap.Modal(document.getElementById('cloudModal')).show(); 
});
document.getElementById('btn-confirm-cloud').addEventListener('click', () => { 
    const v = document.getElementById('modal-cloud-list').value; 
    if (!v) return; 
    if (cloudModalTarget==='backup') { 
        if (!destinations.find(d=>d.path===v)) { destinations.push({type:'cloud',path:v,enabled:true}); renderDestinations(); } 
    } else { 
        document.getElementById('res-src').value = v+':'; 
        updateResInfo(); 
    } 
    bootstrap.Modal.getInstance(document.getElementById('cloudModal')).hide(); 
});

document.getElementById('btn-g-auth').addEventListener('click', async () => { const n = document.getElementById('g-name').value; if (!n) return alert("Enter Email"); document.getElementById('auth-overlay').style.display='flex'; const r = await window.bear.invoke('rclone-auth-drive', n); document.getElementById('auth-overlay').style.display='none'; if (r==="Success") { alert("Linked!"); document.getElementById('g-name').value=''; loadRemotes(); } else alert(r); });
document.getElementById('btn-n-auth').addEventListener('click', async () => { const u = document.getElementById('n-user').value; if (!u) return alert("Enter User"); const r = await window.bear.invoke('rclone-auth-nextcloud', {name:"Nextcloud_"+u, url:document.getElementById('n-url').value, user:u, pass:document.getElementById('n-pass').value}); if(r==="Success"){alert("Linked!"); document.getElementById('n-pass').value=''; loadRemotes();}else alert(r); });
document.getElementById('btn-b2-auth').addEventListener('click', async () => { const n = document.getElementById('b2-name').value; if (!n) return alert("Enter Name"); const r = await window.bear.invoke('rclone-auth-b2', {name:n, acc:document.getElementById('b2-acc').value, key:document.getElementById('b2-key').value}); if(r==="Success"){alert("Linked!"); document.getElementById('b2-key').value=''; loadRemotes();}else alert(r); });
document.getElementById('btn-dav-auth').addEventListener('click', async () => { const n = document.getElementById('dav-name').value; if (!n) return alert("Enter Name"); const r = await window.bear.invoke('rclone-auth-webdav', {name:n, url:document.getElementById('dav-url').value, user:document.getElementById('dav-user').value, pass:document.getElementById('dav-pass').value}); if(r==="Success"){alert("Linked!"); document.getElementById('dav-pass').value=''; loadRemotes();}else alert(r); });

async function loadRemotes() {
    const r = await window.bear.invoke('rclone-dump'); const remotes = Object.keys(r);
    const tc = document.getElementById('cloud-tabs'); 
    if (remotes.length===0) tc.innerHTML='<span class="text-secondary small py-2">No remotes.</span>'; 
    else tc.innerHTML = remotes.map(x=>`<div class="cloud-tab" onclick="openRemote('${x}',this)">${x}</div>`).join('');
    
    const ac = document.getElementById('connected-remotes-container');
    if (remotes.length===0) {
        ac.innerHTML='<div class="col-12"><div class="p-4 text-center text-secondary border border-secondary rounded">No cloud accounts connected yet. Go to Add Provider to link one.</div></div>';
    } else {
        ac.innerHTML = remotes.map(x => `<div class="col-md-6"><div class="card p-3 border-secondary d-flex flex-row align-items-center bg-black"><i class="bi bi-cloud-check-fill text-success fs-3 me-3"></i><div class="flex-grow-1"><div class="fw-bold fs-6 text-white text-truncate">${x}</div><div class="small text-warning" style="font-size:0.7rem; text-transform:uppercase;">${r[x].type || 'Cloud'}</div></div><button class="btn btn-sm btn-danger p-1 px-2 ms-2 shadow-sm" onclick="delRemote('${x}')" title="Remove Connection"><i class="bi bi-trash"></i></button></div></div>`).join('');
    }
}
window.delRemote = async (n) => { 
    if(confirm(`Remove connection to ${n}?`)) { 
        await window.bear.invoke('rclone-delete', n); 
        loadRemotes(); 
    } 
};
window.openRemote = async (r, t) => { 
    document.querySelectorAll('.cloud-tab').forEach(e=>e.classList.remove('active')); 
    t.classList.add('active'); 
    const g = document.getElementById('file-view'); 
    g.innerHTML='<div class="text-warning p-3">Loading...</div>'; 
    const f = await window.bear.invoke('rclone-ls', r); 
    if(f.length===0) g.innerHTML='<div class="text-secondary p-3">Folder empty.</div>'; 
    else g.innerHTML = f.map(x=>`<div class="file-item ${x.IsDir?'is-dir':''}"><i class="bi ${x.IsDir?'bi-folder-fill':'bi-file-earmark-text'} file-icon"></i><div class="file-name" title="${x.Name}">${x.Name}</div></div>`).join(''); 
};


// === RESTORE TAB LOGIC ===
const resSrc = document.getElementById('res-src'); 
const resDest = document.getElementById('res-dest'); 
const resFmtFolder = document.getElementById('res-fmt-folder'); 
const resFmtArchive = document.getElementById('res-fmt-archive'); 
const resEnc = document.getElementById('res-enc'); 
const resKey = document.getElementById('res-key'); 
const resInfoText = document.getElementById('res-info');

function updateResInfo() {
    let text = "";
    if (resFmtArchive.checked) text += '<span class="text-warning"><b>EXTRACT ARCHIVE:</b> The engine will un-zip the selected .tar.gz file directly into the destination folder.</span> ';
    else text += '<span class="text-success"><b>FOLDER RESTORE:</b> The engine will sync files from your backup directly into your destination.</span> ';
    if (resEnc.checked) text += '<br><span class="text-danger mt-1 d-block"><b>DECRYPTION ACTIVE:</b> The engine will unscramble the backup files on-the-fly using your passphrase.</span>';
    resInfoText.innerHTML = text;
}
resFmtFolder.addEventListener('change', updateResInfo); 
resFmtArchive.addEventListener('change', updateResInfo); 
resEnc.addEventListener('change', updateResInfo); 
resKey.addEventListener('input', () => { resEnc.checked = true; updateResInfo(); });

document.getElementById('res-profile-selector').addEventListener('change', (e) => { 
    const profName = e.target.value;
    if (profName && profiles[profName]) {
        const p = profiles[profName];
        if (p.destinations && p.destinations.length > 0) {
            resSrc.value = p.destinations[0].path + (p.destinations[0].type === 'cloud' && !p.destinations[0].path.includes(':') ? ':' : '');
        }
        if (p.sources && p.sources.length > 0) {
            resDest.value = p.sources[0].path;
        }
        if (p.key) {
            resKey.value = p.key;
            resEnc.checked = true;
        } else {
            resKey.value = '';
            resEnc.checked = false;
        }
        if (p.comp === 'archive') {
            resFmtArchive.checked = true;
        } else {
            resFmtFolder.checked = true;
        }
    }
    updateResInfo(); 
});
updateResInfo();

document.getElementById('btn-browse-restore-src').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) { resSrc.value=p; updateResInfo(); }});
document.getElementById('btn-browse-restore-dest').addEventListener('click', async () => { const p = await window.bear.invoke('dialog:open'); if(p) resDest.value=p; });
document.getElementById('btn-cloud-restore-src').addEventListener('click', async () => { cloudModalTarget = 'restore'; const r = await window.bear.invoke('rclone-list'); const s = document.getElementById('modal-cloud-list'); s.innerHTML = r.map(x=>`<option value="${x}">${x}</option>`).join(''); new bootstrap.Modal(document.getElementById('cloudModal')).show(); });

document.getElementById('btn-run-restore').addEventListener('click', () => {
    const s = resSrc.value.trim(); const d = resDest.value.trim();
    if (!s || !d) return alert("Select source and destination!");
    document.getElementById('btn-run-restore').style.display='none'; 
    document.getElementById('btn-stop-restore').style.display='block';
    window.bear.send('start-restore-task', { source:s, dest:d, isArchive:resFmtArchive.checked, encrypt:resEnc.checked, key:resKey.value });
});
document.getElementById('btn-stop-restore').addEventListener('click', () => window.bear.send('stop-task'));


// === MULTI-CRON SCHEDULE TAB LOGIC ===
const fE = document.getElementById('cron-freq'); 
const dD = document.getElementById('div-cron-day'); 
const dE = document.getElementById('cron-day');

fE.addEventListener('change', () => { 
    if(fE.value==='daily') dD.style.display='none'; 
    else if(fE.value==='weekly'){ dD.style.display='block'; dE.innerHTML=`<option value="1">Mon</option><option value="2">Tue</option><option value="3">Wed</option><option value="4">Thu</option><option value="5">Fri</option><option value="6">Sat</option><option value="0">Sun</option>`; } 
    else { dD.style.display='block'; let h=''; for(let i=1;i<=28;i++) h+=`<option value="${i}">${i}</option>`; dE.innerHTML=h; } 
});

async function loadSchedule() { 
    schedules = await window.bear.invoke('get-schedule'); 
    const con = document.getElementById('active-crons-container');
    
    if (!schedules || schedules.length === 0) {
        con.innerHTML = '<div class="p-3 text-center text-secondary">No automated jobs scheduled.</div>';
    } else {
        con.innerHTML = schedules.map(s => {
            let desc = s.freq;
            if (s.freq === 'weekly') { const ds = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]; desc += ` on ${ds[parseInt(s.day)]}`; }
            else if (s.freq === 'monthly') desc += ` on the ${s.day}`;
            desc += ` at ${s.time}`;
            
            return `<div class="card p-3 border-secondary mb-2 bg-black d-flex flex-row align-items-center">
                        <div class="flex-grow-1">
                            <div class="fw-bold text-white fs-6">${s.profile}</div>
                            <div class="small text-secondary">${desc}</div>
                        </div>
                        <button class="btn btn-sm btn-danger px-2 shadow-sm" onclick="delSchedule('${s.id}')" title="Delete Cron Job">DELETE</button>
                    </div>`;
        }).join('');
    }
}

document.getElementById('btn-add-cron').addEventListener('click', async () => { 
    const prof = document.getElementById('cron-profile').value;
    if (!prof) return alert("Select a Saved Profile to schedule!");
    
    const conf = await window.bear.invoke('get-config');
    const newId = 'job_' + Date.now();
    const newJob = { id: newId, profile: prof, freq: fE.value, day: fE.value !== 'daily' ? dE.value : null, time: document.getElementById('cron-time').value };
    
    schedules.push(newJob);
    const res = await window.bear.invoke('save-schedule', { schedules: schedules, profiles: profiles, appConf: conf }); 
    
    if(res.success){ loadSchedule(); alert("Cron Job Activated!"); } 
    else { alert("Error saving cron."); }
});

window.delSchedule = async (id) => {
    if(confirm("Remove this automated job?")) {
        const conf = await window.bear.invoke('get-config');
        schedules = schedules.filter(s => s.id !== id);
        const res = await window.bear.invoke('save-schedule', { schedules: schedules, profiles: profiles, appConf: conf });
        if(res.success) { loadSchedule(); } 
        else { alert("Failed to clear cron."); }
    }
};

// === CORE EXECUTION RUNNER ===
function getJobPayload(dryRun=false) { 
    return { 
        sources: sources.filter(x=>x.enabled!==false), 
        destinations: destinations.filter(x=>x.enabled!==false), 
        encrypt: document.getElementById('bak-enc').checked, 
        key: document.getElementById('bak-key').value, 
        mode: document.getElementById('mode-full').checked?'full':'inc', 
        comp: document.getElementById('bak-comp').value, 
        bwVal: document.getElementById('bak-bw-val').value, 
        bwUnit: document.getElementById('bak-bw-unit').value, 
        excludes: excludes.filter(e=>e.enabled).map(e=>e.pattern), 
        dryRun 
    }; 
}

document.getElementById('btn-run-backup').addEventListener('click', () => { 
    const p = getJobPayload(); 
    
    const t = document.getElementById('job-mini-terminal');
    t.textContent = 'Initializing Batch Sequence...\nValidating Payload...\n'; 
    t.textContent += `Validated Sources: ${p.sources.length}\nValidated Destinations: ${p.destinations.length}\n`;
    
    if(p.sources.length===0 || p.destinations.length===0) {
        t.textContent += 'ERROR: Add at least one Source and Destination!\n';
        return alert("Add at least one Source and Destination!"); 
    }
    if(p.encrypt && !p.key) {
        t.textContent += 'ERROR: Encryption checked but no password entered!\n';
        return alert("Encryption checked but no password entered!"); 
    }
    
    document.getElementById('btn-run-backup').style.display='none'; 
    document.getElementById('btn-run-dry').style.display='none'; 
    document.getElementById('btn-stop-backup').style.display='block'; 
    document.getElementById('val-stage').innerText = "Connecting...";
    window.bear.send('start-backup-batch', p); 
});

document.getElementById('btn-run-dry').addEventListener('click', () => { 
    const p = getJobPayload(true); 
    
    const t = document.getElementById('job-mini-terminal');
    t.textContent = 'Initializing Simulation Sequence...\nValidating Payload...\n'; 
    t.textContent += `Validated Sources: ${p.sources.length}\nValidated Destinations: ${p.destinations.length}\n`;
    
    if(p.sources.length===0 || p.destinations.length===0) {
        t.textContent += 'ERROR: Add at least one Source and Destination!\n';
        return alert("Add at least one Source and Destination!"); 
    }
    
    document.getElementById('btn-run-backup').style.display='none'; 
    document.getElementById('btn-run-dry').style.display='none'; 
    document.getElementById('btn-stop-backup').style.display='block'; 
    document.getElementById('val-stage').innerText = "Simulating...";
    window.bear.send('start-backup-batch', p); 
});

document.getElementById('btn-stop-backup').addEventListener('click', () => window.bear.send('stop-task'));

window.bear.on('progress', (d) => { 
    if(d.stage) { document.getElementById('val-stage').innerText = d.stage; document.getElementById('val-stage').className = `metric-val ${d.stageClass}`; } 
    document.getElementById('val-spd').innerText = d.speed||"--"; 
    document.getElementById('val-eta').innerText = d.eta||"--"; 
    const elRaw = document.getElementById('val-raw'); if(elRaw && d.raw) elRaw.innerText = d.raw;
    if(d.fullRaw){ const jt=document.getElementById('job-mini-terminal'); if(jt){jt.textContent+=d.fullRaw+'\n'; jt.scrollTop=jt.scrollHeight;} } 
});

window.bear.on('done', (m) => { 
    document.getElementById('btn-run-backup').style.display='block'; 
    document.getElementById('btn-run-dry').style.display='block'; 
    document.getElementById('btn-stop-backup').style.display='none'; 
    document.getElementById('val-stage').innerText=m; 
    document.getElementById('val-stage').className="metric-val text-success"; 
});

window.bear.on('restore-progress', (d) => { 
    if(d.stage) { document.getElementById('res-val-stage').innerText = d.stage; document.getElementById('res-val-stage').className = `metric-val ${d.stageClass}`; } 
    document.getElementById('res-val-spd').innerText = d.speed||"--"; 
    document.getElementById('res-val-eta').innerText = d.eta||"--"; 
});

window.bear.on('restore-done', (m) => { 
    document.getElementById('btn-run-restore').style.display='block'; 
    document.getElementById('btn-stop-restore').style.display='none'; 
    document.getElementById('res-val-stage').innerText=m; 
    document.getElementById('res-val-stage').className="metric-val text-success"; 
});

window.bear.on('update-available', (release) => {
    document.getElementById('update-ver-text').innerText = `Version ${release.tag_name} is available on GitHub.`;
    new bootstrap.Modal(document.getElementById('updateModal')).show();
    document.getElementById('btn-update-notes').onclick = () => window.bear.send('open-link', release.html_url);
});

document.getElementById('btn-run-update').addEventListener('click', () => {
    document.getElementById('btn-run-update').innerText = "Launching Installer...";
    window.bear.send('run-updater');
});

switchView('backup');
EOF

echo "Updating package.json..."
cat <<EOF > package.json
{ 
  "name": "backupbear", 
  "productName": "BackupBear", 
  "version": "16.4.0", 
  "description": "Enterprise-Grade Rclone/Rsync GUI", 
  "author": "Aureus K'Tharr <space-bear-taur@proton.me>", 
  "homepage": "https://github.com/Aureustaur/BackupBear", 
  "main": "main.js", 
  "scripts": { "dist": "electron-builder" }, 
  "build": { "appId": "com.aureus.backupbear", "linux": { "target": ["pacman", "deb"], "category": "Utility", "icon": "build/icons/512x512.png" } } 
}
EOF

echo "Installing build dependencies..."
npm install --save-dev electron electron-builder axios --no-audit --silent

echo "Compiling v16.4.0 Packages..."
npx electron-builder --linux pacman -c.compression=normal

PKG_FILE=$(find dist -maxdepth 1 -name "*.pacman" -type f | head -n 1)
if [ -n "$PKG_FILE" ]; then
    echo "Deploying to pacman..."
    sudo pacman -U --noconfirm "$APP_DIR/$PKG_FILE"
    rm -f ~/.cache/icon-cache.kcache
    kbuildsycoca6 --noincremental > /dev/null 2>&1
    echo "Installation Successful! Launch BackupBear from your application menu."
fi
