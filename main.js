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

