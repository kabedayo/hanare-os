// VRAM/RAM Monitor — GNOME Shell 46 extension
// Shows NVIDIA VRAM (per GPU) and system RAM usage in the top bar.
// Also shows a HANARE status indicator (center panel) with a state dot
// and a dropdown listing service states and the latest event.

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';

const UPDATE_SECONDS = 2;
const HANARE_UPDATE_SECONDS = 5;
const HANARE_DASHBOARD_URI = 'http://127.0.0.1:8790';

const HANARE_STATE_JA = {
    running: '稼働中',
    stopped: '停止中',
    degraded: '劣化',
    'stuck-suspect': '固まり疑い',
};

const HANARE_COLOR_STUCK = '#f85149';
const HANARE_COLOR_DEGRADED = '#d29922';
const HANARE_COLOR_RUNNING = '#58a34c';
const HANARE_COLOR_INACTIVE = '#8a8a8a';

const HANARE_SERVICE_UNITS = {
    comfyui: 'hanare-comfyui',
    'llama-server': 'hanare-llama',
    strata: 'hanare-strata',
};

const HANARE_SERVICE_DISPLAY = {
    comfyui: 'ComfyUI',
    'llama-server': 'llama',
    strata: 'Strata',
};

function hanareFallbackModel() {
    const models = readHanareModels();
    return models.length > 0 ? models[0].name : '';
}

function mibToGib(mib) {
    return (mib / 1024).toFixed(1);
}

function shortGpuName(name, index) {
    if (name.includes('V100'))
        return 'V100';
    if (name.includes('1060'))
        return '1060';
    if (name.includes('3090'))
        return '3090';
    if (name.includes('4090'))
        return '4090';
    const cleaned = name
        .replace('NVIDIA', '')
        .replace('GeForce', '')
        .replace('Tesla', '')
        .trim();
    return cleaned !== '' ? cleaned : `GPU${index}`;
}

function readRam() {
    try {
        const [ok, contents] = GLib.file_get_contents('/proc/meminfo');
        if (!ok)
            return null;
        const text = new TextDecoder().decode(contents);
        let totalKb = 0;
        let availableKb = 0;
        for (const line of text.split('\n')) {
            if (line.startsWith('MemTotal:'))
                totalKb = parseInt(line.replace(/[^0-9]/g, ''), 10);
            else if (line.startsWith('MemAvailable:'))
                availableKb = parseInt(line.replace(/[^0-9]/g, ''), 10);
        }
        if (!totalKb)
            return null;
        const totalMib = totalKb / 1024;
        const usedMib = totalMib - availableKb / 1024;
        return {usedMib, totalMib};
    } catch (e) {
        return null;
    }
}

function hanareFilePath(name) {
    return GLib.build_filenamev([GLib.get_home_dir(), 'hanare-os', 'runtime', name]);
}

function hanareRepoFilePath(...parts) {
    return GLib.build_filenamev([GLib.get_home_dir(), 'hanare-os', ...parts]);
}

function readHanareModels() {
    try {
        const file = Gio.File.new_for_path(hanareRepoFilePath('models', 'models.tsv'));
        const [ok, contents] = file.load_contents(null);
        if (!ok)
            return null;
        const text = new TextDecoder().decode(contents);
        const models = [];
        for (const line of text.split('\n')) {
            const trimmed = line.trim();
            if (trimmed === '')
                continue;
            const fields = trimmed.split('\t');
            if (fields.length < 4)
                continue;
            const name = fields[0].trim();
            if (name === '' || name === 'name')
                continue;
            const ctx = parseInt(fields[3].trim(), 10);
            if (Number.isNaN(ctx) || ctx <= 0)
                continue;
            models.push({name, ctx});
        }
        return models;
    } catch (e) {
        return null;
    }
}

function readHanareCurrentModel() {
    try {
        const file = Gio.File.new_for_path(hanareRepoFilePath('runtime', 'current-model'));
        const [ok, contents] = file.load_contents(null);
        if (!ok)
            return hanareFallbackModel();
        const text = new TextDecoder().decode(contents).trim();
        return text !== '' ? text : hanareFallbackModel();
    } catch (e) {
        return hanareFallbackModel();
    }
}

function formatCtx(ctx) {
    const n = parseInt(ctx, 10);
    if (Number.isNaN(n) || n <= 0)
        return '';
    if (n % 1024 === 0) {
        const k = n / 1024;
        return Number.isInteger(k) ? `${k}K` : `${k.toFixed(1)}K`;
    }
    return String(n);
}

function escapeMarkup(text) {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;');
}

function readHanareSnapshot() {
    try {
        const file = Gio.File.new_for_path(hanareFilePath('last-status.json'));
        const [ok, contents] = file.load_contents(null);
        if (!ok)
            return null;
        const text = new TextDecoder().decode(contents);
        const parsed = JSON.parse(text);
        return (parsed && typeof parsed === 'object') ? parsed : null;
    } catch (e) {
        return null;
    }
}

function readHanareLatestEvent() {
    try {
        const file = Gio.File.new_for_path(hanareFilePath('events.jsonl'));
        const [ok, contents] = file.load_contents(null);
        if (!ok)
            return null;
        const text = new TextDecoder().decode(contents);
        const lines = text.split('\n')
            .map(l => l.trim())
            .filter(l => l !== '');
        if (lines.length === 0)
            return null;
        const parsed = JSON.parse(lines[lines.length - 1]);
        return (parsed && typeof parsed === 'object') ? parsed : null;
    } catch (e) {
        return null;
    }
}

function hanareDotColor(states) {
    if (states.includes('stuck-suspect'))
        return HANARE_COLOR_STUCK;
    if (states.includes('degraded'))
        return HANARE_COLOR_DEGRADED;
    if (states.includes('running'))
        return HANARE_COLOR_RUNNING;
    return HANARE_COLOR_INACTIVE;
}

function humanizeElapsed(sec) {
    if (sec === null || sec === undefined)
        return '';
    const s = Math.floor(Number(sec));
    if (Number.isNaN(s) || s < 0)
        return '';
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    if (h > 0)
        return m > 0 ? `${h}時間${m}分` : `${h}時間`;
    if (m > 0)
        return `${m}分`;
    return `${s}秒`;
}

function hanareServiceText(svc) {
    if (!svc || typeof svc.name !== 'string')
        return null;
    const state = (svc.state && typeof svc.state === 'string') ? svc.state : '';
    const ja = HANARE_STATE_JA[state] || state || '不明';
    let text = `${svc.name} — ${ja}`;
    const elapsed = humanizeElapsed(svc.elapsed_sec);
    if (elapsed !== '')
        text += ` · ${elapsed}`;
    return text;
}

function hanareEventText(event) {
    if (!event)
        return null;
    const head = [];
    const ts = (typeof event.ts === 'string') ? event.ts : '';
    const timeMatch = ts.match(/T(\d{2}):(\d{2})/);
    if (timeMatch)
        head.push(`${timeMatch[1]}:${timeMatch[2]}`);
    if (typeof event.kind === 'string' && event.kind !== '')
        head.push(event.kind);
    if (head.length === 0)
        return null;
    let text = head.join(' ');
    if (typeof event.actor === 'string' && event.actor !== '')
        text += ` · ${event.actor}`;
    if (typeof event.name === 'string' && event.name !== '')
        text += ` · ${event.name}`;
    return text;
}

export default class VramRamMonitorExtension extends Extension {
    enable() {
        this._gpus = null;
        this._gpuQueryRunning = false;
        this._timeoutId = 0;

        this._button = new PanelMenu.Button(0.0, 'VRAM/RAM Monitor', false);
        this._label = new St.Label({
            text: 'VRAM … / RAM …',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'vram-ram-label',
        });
        this._button.add_child(this._label);

        this._detailItem = new PopupMenu.PopupMenuItem('読み込み中…', {reactive: false});
        this._button.menu.addMenuItem(this._detailItem);
        this._button.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        const refreshItem = new PopupMenu.PopupMenuItem('今すぐ更新');
        refreshItem.connect('activate', () => this._update());
        this._button.menu.addMenuItem(refreshItem);
        const monitorItem = new PopupMenu.PopupMenuItem('システムモニターを開く');
        monitorItem.connect('activate', () => {
            try {
                Gio.Subprocess.new(['gnome-system-monitor'], Gio.SubprocessFlags.NONE);
            } catch (e) {
                logError(e, 'VRAM/RAM Monitor: failed to launch gnome-system-monitor');
            }
        });
        this._button.menu.addMenuItem(monitorItem);

        Main.panel.addToStatusArea('vram-ram-monitor', this._button, 0, 'right');

        this._update();
        this._timeoutId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, UPDATE_SECONDS, () => {
                this._update();
                return GLib.SOURCE_CONTINUE;
            });

        this._hanareTimeoutId = 0;
        this._hanareMenuItems = [];

        this._hanareButton = new PanelMenu.Button(0.0, 'HANARE Status', false);
        this._hanareBox = new St.BoxLayout({
            style_class: 'hanare-box',
        });
        this._hanareLabel = new St.Label({
            text: 'HANARE',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'hanare-label',
        });
        this._hanareDot = new St.Label({
            text: '●',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'hanare-dot',
        });
        this._hanareDot.set_style(`color: ${HANARE_COLOR_INACTIVE};`);
        this._hanareBox.add_child(this._hanareLabel);
        this._hanareBox.add_child(this._hanareDot);
        this._hanareButton.add_child(this._hanareBox);

        Main.panel.addToStatusArea('hanare-status', this._hanareButton, 0, 'center');

        this._refreshHanare();
        this._hanareTimeoutId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT, HANARE_UPDATE_SECONDS, () => {
                this._refreshHanare();
                return GLib.SOURCE_CONTINUE;
            });
    }

    disable() {
        if (this._timeoutId) {
            GLib.source_remove(this._timeoutId);
            this._timeoutId = 0;
        }
        if (this._hanareTimeoutId) {
            GLib.source_remove(this._hanareTimeoutId);
            this._hanareTimeoutId = 0;
        }
        if (this._button) {
            this._button.destroy();
            this._button = null;
        }
        this._label = null;
        this._detailItem = null;
        this._gpus = null;
        this._gpuQueryRunning = false;
        if (this._hanareButton) {
            this._hanareButton.destroy();
            this._hanareButton = null;
        }
        this._hanareBox = null;
        this._hanareLabel = null;
        this._hanareDot = null;
        this._hanareMenuItems = [];
    }

    _update() {
        this._refreshLabel();
        this._queryGpus();
    }

    _refreshLabel() {
        if (!this._label)
            return;
        const ram = readRam();
        const ramText = ram
            ? `RAM ${mibToGib(ram.usedMib)}/${mibToGib(ram.totalMib)}G`
            : 'RAM --';
        let vramText = 'VRAM …';
        if (this._gpus && this._gpus.length > 0) {
            vramText = this._gpus
                .map(g => `${g.short} ${mibToGib(g.usedMib)}/${mibToGib(g.totalMib)}G`)
                .join('  ');
        } else if (this._gpus) {
            vramText = 'VRAM --';
        }
        this._label.set_text(`${vramText}   ${ramText}`);

        if (this._detailItem) {
            const lines = [];
            if (this._gpus && this._gpus.length > 0) {
                for (const g of this._gpus)
                    lines.push(`${g.name}: ${g.usedMib} / ${g.totalMib} MiB`);
            } else {
                lines.push('GPU情報を取得できませんでした');
            }
            if (ram) {
                const pct = Math.round(ram.usedMib / ram.totalMib * 100);
                lines.push(`RAM: ${mibToGib(ram.usedMib)} / ${mibToGib(ram.totalMib)} GiB (${pct}%)`);
            }
            this._detailItem.label.set_text(lines.join('\n'));
        }
    }

    _queryGpus() {
        if (this._gpuQueryRunning)
            return;
        this._gpuQueryRunning = true;
        try {
            const proc = Gio.Subprocess.new(
                ['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total',
                 '--format=csv,noheader,nounits'],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.communicate_utf8_async(null, null, (p, res) => {
                this._gpuQueryRunning = false;
                try {
                    const [, stdout] = p.communicate_utf8_finish(res);
                    const gpus = [];
                    for (const line of stdout.split('\n')) {
                        const parts = line.split(',').map(s => s.trim());
                        if (parts.length < 4)
                            continue;
                        const index = parseInt(parts[0], 10);
                        const usedMib = parseInt(parts[2], 10);
                        const totalMib = parseInt(parts[3], 10);
                        if (Number.isNaN(usedMib) || Number.isNaN(totalMib))
                            continue;
                        gpus.push({
                            index,
                            name: parts[1],
                            short: shortGpuName(parts[1], index),
                            usedMib,
                            totalMib,
                        });
                    }
                    this._gpus = gpus;
                } catch (e) {
                    this._gpus = [];
                }
                this._refreshLabel();
            });
        } catch (e) {
            this._gpuQueryRunning = false;
            this._gpus = [];
            this._refreshLabel();
        }
    }

    _refreshHanare() {
        try {
            const snapshot = readHanareSnapshot();
            const event = readHanareLatestEvent();
            const services = (snapshot && Array.isArray(snapshot.services))
                ? snapshot.services
                : [];
            const states = services
                .map(s => (s && typeof s.state === 'string') ? s.state : null)
                .filter(s => s !== null);
            if (this._hanareDot) {
                this._hanareDot.set_style(`color: ${hanareDotColor(states)};`);
            }
            this._rebuildHanareMenu(services, event);
        } catch (e) {
            logError(e, 'HANARE status: refresh failed');
        }
    }

    _rebuildHanareMenu(services, event) {
        if (!this._hanareButton)
            return;
        const menu = this._hanareButton.menu;
        for (const item of this._hanareMenuItems) {
            try {
                item.destroy();
            } catch (e) {
                // Item already destroyed; ignore.
            }
        }
        this._hanareMenuItems = [];

        for (const svc of services) {
            const text = hanareServiceText(svc);
            if (text === null)
                continue;
            const item = new PopupMenu.PopupMenuItem(text, {reactive: false});
            menu.addMenuItem(item);
            this._hanareMenuItems.push(item);

            const unit = HANARE_SERVICE_UNITS[svc.name];
            if (!unit)
                continue;
            const display = HANARE_SERVICE_DISPLAY[svc.name] || svc.name;
            const state = (svc.state && typeof svc.state === 'string') ? svc.state : '';
            const active = state === 'running' || state === 'degraded' || state === 'stuck-suspect';
            const actions = active
                ? [['stop', `${display} を停止`], ['restart', `${display} を再起動`]]
                : [['start', `${display} を起動`]];
            for (const [action, label] of actions) {
                const controlItem = new PopupMenu.PopupMenuItem(label);
                controlItem.connect('activate', () => {
                    this._runSystemctlUser(action, unit);
                    this._refreshHanare();
                });
                menu.addMenuItem(controlItem);
                this._hanareMenuItems.push(controlItem);
            }
        }

        const eventText = hanareEventText(event);
        if (eventText !== null) {
            const eventItem = new PopupMenu.PopupMenuItem(eventText, {reactive: false});
            menu.addMenuItem(eventItem);
            this._hanareMenuItems.push(eventItem);
        }

        const modelHeader = new PopupMenu.PopupMenuItem('モデル', {reactive: false});
        menu.addMenuItem(modelHeader);
        this._hanareMenuItems.push(modelHeader);

        const models = readHanareModels();
        const currentModel = readHanareCurrentModel();
        const modelStates = services
            .map(s => (s && typeof s.state === 'string') ? s.state : null)
            .filter(s => s !== null);
        const dotColor = hanareDotColor(modelStates);
        if (models === null) {
            const noneItem = new PopupMenu.PopupMenuItem('モデル一覧なし', {reactive: false});
            menu.addMenuItem(noneItem);
            this._hanareMenuItems.push(noneItem);
        } else {
            for (const model of models) {
                const ctxText = formatCtx(model.ctx);
                const suffix = ctxText !== '' ? ` · ${ctxText}` : '';
                const isCurrent = model.name === currentModel;
                const modelItem = new PopupMenu.PopupMenuItem(
                    `${isCurrent ? '●' : '○'} ${model.name}${suffix}`);
                if (isCurrent) {
                    try {
                        modelItem.label.clutter_text.set_markup(
                            `<span foreground="${dotColor}">●</span> ${escapeMarkup(model.name)}${escapeMarkup(suffix)}`);
                    } catch (e) { /* plain marker stays */ }
                }
                modelItem.connect('activate', () => this._selectModel(model.name));
                menu.addMenuItem(modelItem);
                this._hanareMenuItems.push(modelItem);
            }
        }

        const agentItem = new PopupMenu.PopupMenuItem('Strata Agent を開く');
        agentItem.connect('activate', () => this._openStrataAgent());
        menu.addMenuItem(agentItem);
        this._hanareMenuItems.push(agentItem);
        const panelItem = new PopupMenu.PopupMenuItem('パネルを開く');
        panelItem.connect('activate', () => this._openPanel());
        menu.addMenuItem(panelItem);
        this._hanareMenuItems.push(panelItem);
        const sep = new PopupMenu.PopupSeparatorMenuItem();
        menu.addMenuItem(sep);
        this._hanareMenuItems.push(sep);
        const dashItem = new PopupMenu.PopupMenuItem('ダッシュボードを開く');
        dashItem.connect('activate', () => this._openDashboard());
        menu.addMenuItem(dashItem);
        this._hanareMenuItems.push(dashItem);
    }

    _runSystemctlUser(action, unit) {
        try {
            const proc = Gio.Subprocess.new(
                ['systemctl', '--user', action, unit],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.connect('process-exited', () => {});
        } catch (e) {
            logError(e, `HANARE status: systemctl ${action} ${unit} failed`);
        }
        if (action === 'stop')
            this._stopExternal(unit);
    }

    _stopExternal(unit) {
        // A unit stop cannot see a same-service process that was started
        // outside systemd; ask the helper to reap it (it refuses anything
        // that does not match the service identity).
        const svcName = Object.keys(HANARE_SERVICE_UNITS).find(k => HANARE_SERVICE_UNITS[k] === unit);
        if (!svcName)
            return;
        try {
            const proc = Gio.Subprocess.new(
                [hanareRepoFilePath('scripts', 'hanare-service.sh'), 'stop-external', svcName],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            proc.connect('process-exited', () => {});
        } catch (e) {
            logError(e, `HANARE status: stop-external ${svcName} failed`);
        }
    }

    _selectModel(name) {
        try {
            const file = Gio.File.new_for_path(hanareRepoFilePath('runtime', 'current-model'));
            file.replace_contents(`${name}\n`, null, false, Gio.FileCreateFlags.NONE, null, null);
        } catch (e) {
            logError(e, 'HANARE status: failed to write current-model');
        }
        this._runSystemctlUser('restart', 'hanare-llama.service');
        this._refreshHanare();
    }

    _openPanel() {
        try {
            Gio.Subprocess.new(
                ['python3', GLib.get_home_dir() + '/hanare-os/panel/hanare-panel.py'],
                Gio.SubprocessFlags.NONE);
        } catch (e) {
            logError(e, 'HANARE status: failed to launch panel');
        }
    }

    _openStrataAgent() {
        try {
            Gio.Subprocess.new(
                ['/bin/sh', GLib.build_filenamev([GLib.get_home_dir(), 'hanare-apps', 'strata-agent', 'run.sh'])],
                Gio.SubprocessFlags.NONE);
        } catch (e) {
            logError(e, 'HANARE status: failed to launch Strata Agent');
        }
    }

    _openDashboard() {
        try {
            Gio.AppInfo.launch_default_for_uri(HANARE_DASHBOARD_URI, null);
        } catch (e) {
            try {
                Gio.Subprocess.new(
                    ['xdg-open', HANARE_DASHBOARD_URI],
                    Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE);
            } catch (e2) {
                logError(e2, 'HANARE status: failed to open dashboard');
            }
        }
    }
}
