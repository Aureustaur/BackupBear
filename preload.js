const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('bear', { 
    invoke: (c, d) => ipcRenderer.invoke(c, d), 
    send: (c, d) => ipcRenderer.send(c, d), 
    on: (c, f) => ipcRenderer.on(c, (e, ...a) => f(...a)), 
    getHome: () => ipcRenderer.invoke('get-home') 
});
