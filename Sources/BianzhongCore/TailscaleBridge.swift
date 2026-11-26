import Foundation

public struct TailscaleStatusInfo: Codable, Sendable, Equatable {
    public let installed: Bool
    public let binaryPath: String?
    public let backendState: String
    public let dnsName: String?
    public let httpsBaseURL: String?
    public let serveEnabled: Bool
    public let pocketURL: String?
    public let errorMessage: String?

    public init(
        installed: Bool,
        binaryPath: String? = nil,
        backendState: String = "Unavailable",
        dnsName: String? = nil,
        httpsBaseURL: String? = nil,
        serveEnabled: Bool = false,
        pocketURL: String? = nil,
        errorMessage: String? = nil
    ) {
        self.installed = installed
        self.binaryPath = binaryPath
        self.backendState = backendState
        self.dnsName = dnsName
        self.httpsBaseURL = httpsBaseURL
        self.serveEnabled = serveEnabled
        self.pocketURL = pocketURL
        self.errorMessage = errorMessage
    }

    public var isRunning: Bool {
        backendState.lowercased() == "running"
    }
}

/// Manages zero-public-IP private Tailnet exposure (`tailscale serve`) and serves the Mobile Pocket Console PWA.
public enum TailscaleBridge {
    public static func resolveTailscaleBinary() -> String? {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return AgentDriverRegistry.resolveBinary(name: "tailscale")
    }

    public static func queryStatus(localPort: UInt16) -> TailscaleStatusInfo {
        guard let bin = resolveTailscaleBinary() else {
            return TailscaleStatusInfo(installed: false, errorMessage: "未检测到 Tailscale CLI")
        }

        let statusOut = runCLI(bin, args: ["status", "--json", "--peers=false"], timeout: 2.5)
        guard statusOut.exitCode == 0 || !statusOut.stdout.isEmpty,
              let data = statusOut.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let err = statusOut.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return TailscaleStatusInfo(installed: true, binaryPath: bin, backendState: "Stopped", errorMessage: err.isEmpty ? nil : err)
        }

        let state = (obj["BackendState"] as? String) ?? "Unknown"
        let rawDNS = ((obj["Self"] as? [String: Any])?["DNSName"] as? String) ?? ""
        let cleanDNS = rawDNS.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
        let httpsBase = cleanDNS.isEmpty ? nil : "https://\(cleanDNS)"

        var serveActive = false
        if state.lowercased() == "running" {
            let serveOut = runCLI(bin, args: ["serve", "status", "--json"], timeout: 2.5)
            if let sData = serveOut.stdout.data(using: .utf8),
               let sText = String(data: sData, encoding: .utf8) {
                serveActive = sText.contains(":\(localPort)") || sText.contains("127.0.0.1:\(localPort)") || sText.contains("localhost:\(localPort)")
            }
        }

        let pocket = httpsBase.map { "\($0)/pocket" }
        return TailscaleStatusInfo(
            installed: true,
            binaryPath: bin,
            backendState: state,
            dnsName: cleanDNS.isEmpty ? nil : cleanDNS,
            httpsBaseURL: httpsBase,
            serveEnabled: serveActive,
            pocketURL: pocket,
            errorMessage: nil
        )
    }

    public static func setServe(enabled: Bool, localPort: UInt16) -> (ok: Bool, status: TailscaleStatusInfo, message: String) {
        guard let bin = resolveTailscaleBinary() else {
            return (false, TailscaleStatusInfo(installed: false), "未检测到 Tailscale 应用")
        }
        let current = queryStatus(localPort: localPort)
        if enabled && !current.isRunning {
            return (false, current, "请先打开 Tailscale 并登录（当前状态：\(current.backendState)）")
        }

        if enabled {
            let target = "http://127.0.0.1:\(localPort)"
            let res = runCLI(bin, args: ["serve", "--bg", target], timeout: 8.0)
            let updated = queryStatus(localPort: localPort)
            if res.exitCode == 0 || updated.serveEnabled {
                return (true, updated, "已开启私网映射：\(updated.pocketURL ?? target)")
            }
            let err = (res.stderr.isEmpty ? res.stdout : res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, updated, err.isEmpty ? "tailscale serve 启动失败" : err)
        } else {
            guard current.serveEnabled else {
                return (true, current, "当前未开启映射")
            }
            var res = runCLI(bin, args: ["serve", "--https=443", "off"], timeout: 6.0)
            var updated = queryStatus(localPort: localPort)
            if updated.serveEnabled {
                res = runCLI(bin, args: ["serve", "off"], timeout: 6.0)
                updated = queryStatus(localPort: localPort)
            }
            if res.exitCode == 0 || !updated.serveEnabled {
                return (true, updated, "已关闭 Tailscale 私网映射")
            }
            return (false, updated, res.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func runCLI(_ path: String, args: [String], timeout: TimeInterval) -> (exitCode: Int32, stdout: String, stderr: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        final class PipeBuffer: @unchecked Sendable {
            var data = Data()
        }
        let outBox = PipeBuffer()
        let errBox = PipeBuffer()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        if proc.isRunning {
            proc.terminate()
            _ = group.wait(timeout: .now() + 0.5)
            return (124, "", "Timed out")
        }
        _ = group.wait(timeout: .now() + 1.0)
        let out = String(data: outBox.data, encoding: .utf8) ?? ""
        let err = String(data: errBox.data, encoding: .utf8) ?? ""
        return (proc.terminationStatus, out, err)
    }
}

/// Self-contained zero-dependency Mobile Pocket Console PWA served at `/pocket`.
public enum PocketConsoleAssets {
    public static let manifestJSON = """
    {
      "name": "编钟 Bianzhong",
      "short_name": "编钟",
      "start_url": "/pocket",
      "display": "standalone",
      "background_color": "#0b0d10",
      "theme_color": "#0b0d10",
      "icons": [
        { "src": "/pocket/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable" }
      ]
    }
    """

    public static let serviceWorkerJS = """
    self.addEventListener('install', () => self.skipWaiting());
    self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
    """

    public static let iconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
      <rect width="128" height="128" rx="28" fill="#11141a"/>
      <path d="M36 30h56l-6 10H42z" fill="#d4a259"/>
      <path d="M42 44h44l8 50c-18 8-42 8-60 0z" fill="#c79246"/>
      <circle cx="64" cy="68" r="5" fill="#11141a"/>
    </svg>
    """

    public static let indexHTML = #"""
    <!doctype html>
    <html lang="zh-CN">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,viewport-fit=cover">
      <meta name="apple-mobile-web-app-capable" content="yes">
      <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
      <meta name="theme-color" content="#0b0d10">
      <link rel="manifest" href="/pocket/manifest.json">
      <link rel="apple-touch-icon" href="/pocket/icon.svg">
      <title>编钟 · 口袋控制台</title>
      <style>
        :root {
          --bg: #0b0d10; --card: #151921; --border: #252b37;
          --fg: #eef1f6; --muted: #8b94a5; --accent: #3b82f6;
          --ok: #22c55e; --warn: #f59e0b; --danger: #ef4444; --code: #0e1117;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; -webkit-tap-highlight-color: transparent; }
        body {
          background: var(--bg); color: var(--fg);
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          padding: calc(env(safe-area-inset-top, 12px) + 12px) 14px calc(env(safe-area-inset-bottom, 16px) + 24px);
          max-width: 600px; margin: 0 auto;
        }
        header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 14px; }
        .brand { display: flex; align-items: center; gap: 8px; font-size: 18px; font-weight: 700; }
        .pill { font-size: 11px; padding: 3px 9px; border-radius: 999px; background: var(--card); border: 1px solid var(--border); color: var(--muted); }
        .pill.ok { color: var(--ok); border-color: rgba(34,197,94,.35); }
        .pill.warn { color: var(--warn); border-color: rgba(245,158,11,.35); }
        .toolbar { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 16px; }
        button {
          appearance: none; border: 1px solid var(--border); background: var(--card); color: var(--fg);
          font-size: 13px; font-weight: 600; padding: 9px 12px; border-radius: 10px; cursor: pointer;
        }
        button:active { opacity: 0.75; transform: scale(0.99); }
        button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
        button.danger { background: rgba(239,68,68,.15); border-color: rgba(239,68,68,.4); color: #fca5a5; }
        .sec-title { font-size: 12px; font-weight: 600; color: var(--muted); margin: 14px 2px 8px; text-transform: uppercase; letter-spacing: .03em; }
        .card { background: var(--card); border: 1px solid var(--border); border-radius: 14px; padding: 13px; margin-bottom: 10px; }
        .card-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 8px; margin-bottom: 6px; }
        .card-title { font-size: 15px; font-weight: 600; line-height: 1.35; }
        .tag { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 10px; padding: 2px 6px; border-radius: 5px; background: var(--code); color: var(--muted); white-space: nowrap; }
        .tag.warm { color: var(--warn); border: 1px solid rgba(245,158,11,.4); }
        .meta { font-size: 11px; color: var(--muted); margin-bottom: 8px; }
        .summary { font-size: 13px; line-height: 1.5; white-space: pre-wrap; word-break: break-word; color: #d5dbe6; margin-bottom: 10px; }
        pre.diff {
          background: var(--code); border: 1px solid var(--border); border-radius: 9px;
          padding: 9px; font-family: ui-monospace, SFMono-Regular, monospace; font-size: 11px;
          line-height: 1.45; overflow-x: auto; margin-bottom: 10px; color: #c9d1d9;
        }
        .d-add { color: #4ade80; } .d-del { color: #f87171; }
        input, textarea {
          width: 100%; background: var(--code); border: 1px solid var(--border); color: var(--fg);
          border-radius: 9px; padding: 9px 10px; font-size: 13px; margin-bottom: 9px;
        }
        .btn-row { display: flex; gap: 8px; }
        .btn-row button { flex: 1; }
        .empty { text-align: center; color: var(--muted); font-size: 13px; padding: 22px 10px; background: var(--card); border: 1px dashed var(--border); border-radius: 14px; }
        #auth-box { margin-top: 24px; }
        .toast { position: fixed; bottom: 20px; left: 50%; transform: translateX(-50%); background: #1e293b; color: #fff; font-size: 12px; padding: 8px 14px; border-radius: 999px; border: 1px solid var(--border); display: none; z-index: 99; }
      </style>
    </head>
    <body>
      <header>
        <div class="brand">🔔 编钟 <span id="status-pill" class="pill">连接中</span></div>
        <button onclick="refreshState()" style="padding:6px 10px;font-size:12px">刷新</button>
      </header>

      <div id="auth-box" class="card" style="display:none">
        <div class="card-title" style="margin-bottom:8px">输入配对 Token</div>
        <div class="meta">在 Mac「编钟 -> 控制台 -> 集成」扫码或粘贴 Bearer Token：</div>
        <input id="tok-input" type="password" placeholder="BIANZHONG_WEBHOOK_TOKEN">
        <button class="primary" style="width:100%" onclick="saveToken()">配对连接</button>
      </div>

      <div id="app-body" style="display:none">
        <div class="toolbar">
          <button id="pause-btn" onclick="togglePause()">暂停 1h</button>
          <button class="danger" onclick="stopAllRuns()">紧急停止全部运行</button>
        </div>

        <div class="sec-title">实时运行 (<span id="active-count">0</span>)</div>
        <div id="active-list"></div>

        <div class="sec-title">待办审批 (<span id="pending-count">0</span>)</div>
        <div id="pending-list"></div>

        <div class="sec-title">远程触发信号</div>
        <div class="card">
          <input id="emit-title" placeholder="标题（如：检查线上订单接口状态）">
          <textarea id="emit-body" rows="2" placeholder="补充说明或指令..."></textarea>
          <button class="primary" style="width:100%" onclick="emitSignal()">发送到 Mac</button>
        </div>

        <div class="sec-title">最近记录</div>
        <div id="runs-list"></div>
      </div>

      <div id="toast" class="toast"></div>

      <script>
        if ('serviceWorker' in navigator) { navigator.serviceWorker.register('/pocket/sw.js').catch(() => {}); }

        (function bootstrapHashToken() {
          if (location.hash.startsWith('#token=')) {
            const t = decodeURIComponent(location.hash.slice(7)).trim();
            if (t) localStorage.setItem('bz_token', t);
            history.replaceState(null, '', location.pathname + location.search);
          }
        })();

        let currentPaused = false;

        function getToken() { return localStorage.getItem('bz_token') || ''; }
        function saveToken() {
          const v = document.getElementById('tok-input').value.trim();
          if (!v) return;
          localStorage.setItem('bz_token', v);
          refreshState();
        }
        function toast(msg) {
          const el = document.getElementById('toast');
          el.textContent = msg; el.style.display = 'block';
          setTimeout(() => { el.style.display = 'none'; }, 2200);
        }
        function esc(s) {
          return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
        }
        function renderDiff(raw) {
          if (!raw) return '';
          const lines = String(raw).split('\n').map(l => {
            if (l.startsWith('+')) return '<span class="d-add">' + esc(l) + '</span>';
            if (l.startsWith('-')) return '<span class="d-del">' + esc(l) + '</span>';
            return esc(l);
          }).join('\n');
          return '<pre class="diff">' + lines + '</pre>';
        }

        async function api(path, method = 'GET', body = null) {
          const tok = getToken();
          if (!tok) { showAuth(); return null; }
          const opts = { method, headers: { 'Authorization': 'Bearer ' + tok, 'Content-Type': 'application/json' } };
          if (body) opts.body = JSON.stringify(body);
          const res = await fetch(path, opts);
          if (res.status === 401) { showAuth(); return null; }
          return await res.json();
        }

        function showAuth() {
          document.getElementById('auth-box').style.display = 'block';
          document.getElementById('app-body').style.display = 'none';
          const pill = document.getElementById('status-pill');
          pill.className = 'pill warn'; pill.textContent = '待配对';
        }

        async function refreshState() {
          try {
            const data = await api('/v1/pocket/state');
            if (!data) return;
            document.getElementById('auth-box').style.display = 'none';
            document.getElementById('app-body').style.display = 'block';
            currentPaused = !!data.paused;
            const pill = document.getElementById('status-pill');
            pill.className = currentPaused ? 'pill warn' : 'pill ok';
            pill.textContent = currentPaused ? '已暂停' : ('在线 · 今日 $' + Number(data.today_cost_usd || 0).toFixed(2));
            document.getElementById('pause-btn').textContent = currentPaused ? '恢复运行' : '暂停 1h';

            const active = data.active_runs || [];
            document.getElementById('active-count').textContent = active.length;
            document.getElementById('active-list').innerHTML = active.length === 0
              ? '<div class="empty">当前无活跃运行</div>'
              : active.map(r => `
                <div class="card">
                  <div class="card-head">
                    <div class="card-title">${esc(r.title || r.chimeID)}</div>
                    <span class="tag ${r.status === 'warm_hold' ? 'warm' : ''}">${esc(r.driver)} · ${r.status === 'warm_hold' ? '热挂起待批' : esc(r.phase)}</span>
                  </div>
                  <div class="meta">${esc(r.currentActivity)}</div>
                  ${r.streamPreview ? '<div class="summary">' + esc(r.streamPreview.slice(-360)) + '</div>' : ''}
                  ${renderDiff(r.diffPreview)}
                  <button class="danger" style="width:100%" onclick="act({action:'stop_run', run_id:'${esc(r.runID)}'})">中止此任务</button>
                </div>`).join('');

            const pending = data.approvals || [];
            document.getElementById('pending-count').textContent = pending.length;
            document.getElementById('pending-list').innerHTML = pending.length === 0
              ? '<div class="empty">暂无待办</div>'
              : pending.map(a => `
                <div class="card">
                  <div class="card-head">
                    <div class="card-title">${esc(a.title)}</div>
                    <span class="tag">${esc(a.riskLevel)}</span>
                  </div>
                  <div class="meta">${esc(a.provenanceSummary)}</div>
                  <div class="summary">${esc(a.proposedAction)}</div>
                  ${renderDiff(a.diffPreview)}
                  <input id="note-${esc(a.id)}" placeholder="可选：输入调整指令或审批备注...">
                  <div class="btn-row">
                    <button class="primary" onclick="resolveItem('${esc(a.id)}', 'approve')">批准执行</button>
                    <button onclick="resolveItem('${esc(a.id)}', 'steer')">指示重调</button>
                    <button onclick="resolveItem('${esc(a.id)}', 'reject')">忽略</button>
                  </div>
                </div>`).join('');

            const runs = (data.recent_runs || []).slice(0, 6);
            document.getElementById('runs-list').innerHTML = runs.map(r => `
              <div class="card" style="padding:10px 12px">
                <div class="card-head" style="margin-bottom:2px">
                  <strong style="font-size:13px">${esc(r.chimeID)}</strong>
                  <span class="tag">${esc(r.driver)} · ${esc(r.status)}</span>
                </div>
                ${r.outputSummary ? '<div class="meta" style="margin:4px 0 0">' + esc(r.outputSummary.slice(0, 180)) + '</div>' : ''}
              </div>`).join('');
          } catch (e) {
            toast('连接异常');
          }
        }

        async function act(payload) {
          const res = await api('/v1/pocket/act', 'POST', payload);
          if (res) { toast(res.message || '已执行'); refreshState(); }
        }
        function resolveItem(id, action) {
          const noteEl = document.getElementById('note-' + id);
          const comment = noteEl ? noteEl.value.trim() : '';
          act({ action, approval_id: id, comment });
        }
        function togglePause() { act({ action: currentPaused ? 'resume' : 'pause' }); }
        function stopAllRuns() { act({ action: 'stop_all' }); }
        function emitSignal() {
          const title = document.getElementById('emit-title').value.trim();
          const body = document.getElementById('emit-body').value.trim();
          if (!title && !body) return;
          act({ action: 'emit', title: title || '手机远程触发', body });
          document.getElementById('emit-title').value = '';
          document.getElementById('emit-body').value = '';
        }

        refreshState();
        setInterval(() => { if (!document.hidden && getToken()) refreshState(); }, 3500);
      </script>
    </body>
    </html>
    """#
}
