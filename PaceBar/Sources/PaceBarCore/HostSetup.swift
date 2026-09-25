import Darwin
import Foundation

/// Only app-generated UUIDs, SHA-256 hex digests and validated numeric ports enter these scripts.
/// Host names, URLs and labels remain exclusively in Process argv.
enum HostSetupScripts {
    static func inspect(port: Int) -> String {
        #"""
        set -eu
        if test "$(uname -s)" != Linux || ! test -x /usr/bin/python3; then
          printf '%s\n' '{"linux":"unsupported","python":"unsupported"}'
          exit 0
        fi
        /usr/bin/python3 - <<'PY'
        import os, pathlib, hashlib, json, subprocess, urllib.request
        def run(*args):
            try:
                p = subprocess.run(args, capture_output=True, text=True, timeout=5)
                return p.stdout.strip() if p.returncode == 0 else 'unavailable'
            except (OSError, subprocess.TimeoutExpired): return 'unavailable'
        home = pathlib.Path.home()
        script = home/'.local/lib/pace-bar/metrics.py'
        unit = home/'.config/systemd/user/pace-bar-metrics.service'
        def digest(p):
            try: return hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else 'missing'
            except OSError: return 'unreadable'
        def safe(p):
            chain = [q for q in [p] + list(p.parents) if q == home or home in q.parents]
            return all(not q.is_symlink() and (not q.exists() or q.stat().st_uid == os.getuid()) for q in chain)
        f = {'linux':'yes', 'python':'yes', 'identity':run('id', '-un') + ':' + run('hostname'),
             'systemd':'yes' if run('systemctl','--user','show-environment') != 'unavailable' else 'no',
             'script':digest(script), 'unit':digest(unit), 'safe':'yes' if safe(script) and safe(unit) else 'no'}
        listeners = run('ss', '-H', '-ltn')
        f['inferenceListener'] = 'unknown'
        if listeners != 'unavailable':
            f['inferenceListener'] = 'yes' if any(
                len(fields) > 3 and fields[3].rsplit(':', 1)[-1] == '__INFERENCE_PORT__'
                for fields in (line.split() for line in listeners.splitlines())) else 'no'
        for name, args in {'enabled':['is-enabled'], 'active':['is-active'], 'exec':['show','-p','ExecStart','--value'],
                           'pid':['show','-p','MainPID','--value']}.items():
            # is-active/is-enabled return useful stdout even on a negative result.
            try: f[name] = subprocess.run(['systemctl','--user']+args+['pace-bar-metrics.service'],
                                          capture_output=True, text=True, timeout=5).stdout.strip()
            except (OSError, subprocess.TimeoutExpired): f[name] = 'unavailable'
        f['expectedProcess'] = 'no'
        try:
            pid = int(f['pid'])
            cmd = pathlib.Path('/proc')/str(pid)/'cmdline'
            argv = cmd.read_bytes().split(b'\0')
            started = float((pathlib.Path('/proc')/str(pid)/'stat').read_text().rsplit(')',1)[1].split()[19])/os.sysconf('SC_CLK_TCK')
            boot = float(next(line.split()[1] for line in pathlib.Path('/proc/stat').read_text().splitlines() if line.startswith('btime ')))
            newest = max(script.stat().st_mtime, unit.stat().st_mtime)
            if argv[:2] == [b'/usr/bin/python3', str(script).encode()] and boot+started >= newest:
                f['expectedProcess'] = 'yes'
        except (OSError, ValueError, StopIteration, IndexError): pass
        f['linger'] = run('loginctl','show-user',str(os.getuid()),'-p','Linger','--value')
        try:
            with urllib.request.urlopen('http://127.0.0.1:8082/snapshot',timeout=5) as r:
                body = r.read(16385)
                f['snapshot'] = body.decode() if r.status == 200 and len(body) <= 16384 else ''
        except Exception: f['snapshot'] = ''
        try:
            serve = json.loads(run('tailscale','serve','status','--json'))
            port = serve.get('TCP',{}).get('8082')
            forwarded = port is not None and port.get('TCPForward') == '127.0.0.1:8082'
            funnel = any(serve.get('AllowFunnel',{}).values())
            f['serve'] = 'unmapped' if port is None else ('correct' if forwarded and not funnel else 'conflict')
        except (ValueError, AttributeError): f['serve'] = 'unavailable'
        print(json.dumps(f, sort_keys=True))
        PY
        """#.replacingOccurrences(of: "__INFERENCE_PORT__", with: String(port))
    }

    static func stage(_ id: String) -> String {
        """
        set -eu
        umask 077
        /usr/bin/python3 - <<'PY'
        import os, pathlib
        base = pathlib.Path.home()/'.local/share/pace-bar/setup'
        for p in [base] + [q for q in base.parents if q == pathlib.Path.home() or pathlib.Path.home() in q.parents]:
            if p.is_symlink() or (p.exists() and p.stat().st_uid != os.getuid()): raise RuntimeError('Unsafe staging path')
        base.mkdir(parents=True, exist_ok=True)
        (base/'\(id)').mkdir(mode=0o700)
        PY
        """
    }

    static func transaction(_ id: String, hashes: [String]) -> String {
        """
        import os, pathlib, hashlib, json, shutil, subprocess, time, urllib.request
        home = pathlib.Path.home()
        stage = home/'.local/share/pace-bar/setup/\(id)'
        targets = [home/'.local/lib/pace-bar/metrics.py', home/'.config/systemd/user/pace-bar-metrics.service']
        names = ['metrics.py', 'pace-bar-metrics.service']
        expected = ['\(hashes[0])', '\(hashes[1])']
        def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else 'missing'
        def safe(p):
            for q in [p] + [q for q in p.parents if q == home or home in q.parents]:
                if q.is_symlink() or (q.exists() and q.stat().st_uid != os.getuid()): raise RuntimeError('Unsafe path')
        def service(*args): subprocess.run(['systemctl','--user']+list(args), check=True, timeout=15)
        safe(stage)
        for p in targets: safe(p)
        receipt = stage/'receipt.json'
        """
    }

    static func install(_ id: String, hashes: [String]) -> String {
        "set -eu\numask 077\n/usr/bin/python3 - <<'PY'\n" + self.transaction(id, hashes: hashes) + """

        for name, expected_hash in zip(names, expected):
            p = stage/name
            safe(p)
            if digest(p) != expected_hash: raise RuntimeError('Staged hash mismatch')
        def unit_state(verb):
            return subprocess.run(['systemctl','--user',verb,'--quiet','pace-bar-metrics.service']).returncode == 0
        prior = {'hashes':[digest(p) for p in targets], 'enabled':unit_state('is-enabled'), 'active':unit_state('is-active')}
        for i,p in enumerate(targets):
            if p.exists(): shutil.copy2(p, stage/(names[i]+'.before'))
        with receipt.open('x') as f: json.dump(prior,f)
        for i,p in enumerate(targets):
            p.parent.mkdir(parents=True, exist_ok=True)
            temp = p.parent/(p.name+'.\(id).new')
            with temp.open('xb') as f: f.write((stage/names[i]).read_bytes())
            os.chmod(temp,0o600)
            temp.replace(p)
        service('daemon-reload')
        service('enable','pace-bar-metrics.service')
        service('restart','pace-bar-metrics.service')
        for attempt in range(20):
            try:
                with urllib.request.urlopen('http://127.0.0.1:8082/snapshot',timeout=2) as r:
                    data = r.read(16385)
                    if r.status != 200 or len(data)>16384: raise RuntimeError('Invalid snapshot')
                    print(data.decode())
                    break
            except Exception:
                if attempt == 19: raise
                time.sleep(0.25)
        PY
        """
    }

    static func rollback(_ id: String, hashes: [String]) -> String {
        "set -eu\n/usr/bin/python3 - <<'PY'\n" + self.transaction(id, hashes: hashes) + """

        if not receipt.exists():
            print('No installed transaction to restore')
            raise SystemExit(0)
        prior = json.loads(receipt.read_text())
        for i,p in enumerate(targets):
            if digest(p) not in (expected[i], prior['hashes'][i]): raise RuntimeError('Intervening changes; rollback refused')
            backup = stage/(names[i]+'.before')
            if prior['hashes'][i] != 'missing' and digest(backup) != prior['hashes'][i]:
                raise RuntimeError('Backup changed; rollback refused')
        service('disable','--now','pace-bar-metrics.service')
        for i,p in enumerate(targets):
            if prior['hashes'][i] == 'missing': p.unlink(missing_ok=True)
            else: shutil.copy2(stage/(names[i]+'.before'),p)
        service('daemon-reload')
        if prior['enabled']: service('enable','pace-bar-metrics.service')
        if prior['active']: service('start','pace-bar-metrics.service')
        print('Prior collector files and service state restored; energy state untouched; linger retained')
        PY
        """
    }

    static func serve(_ id: String) -> String {
        self.stage(id) + """

        /usr/bin/python3 - <<'PY'
        import pathlib, json, subprocess, urllib.request
        marker = pathlib.Path.home()/'.local/share/pace-bar/setup/\(id)/serve-created'
        config = json.loads(subprocess.check_output(['tailscale','serve','status','--json'],timeout=5))
        if config.get('TCP',{}).get('8082') is not None: raise RuntimeError('8082 changed; new consent required')
        with urllib.request.urlopen('http://127.0.0.1:8082/snapshot',timeout=5) as r:
            if r.status != 200: raise RuntimeError('Collector not healthy')
        subprocess.run(['tailscale','serve','--bg','--tcp=8082','tcp://127.0.0.1:8082'],check=True,timeout=15)
        marker.touch(exist_ok=False)
        PY
        """
    }

    static func undoServe(_ id: String) -> String {
        """
        set -eu
        /usr/bin/python3 - <<'PY'
        import pathlib, json, subprocess
        marker = pathlib.Path.home()/'.local/share/pace-bar/setup/\(id)/serve-created'
        if not marker.exists(): raise SystemExit(0)
        config = json.loads(subprocess.check_output(['tailscale','serve','status','--json'],timeout=5))
        port = config.get('TCP',{}).get('8082')
        if port is not None:
            if port != {'TCPForward':'127.0.0.1:8082'}: raise RuntimeError('Mapping changed; rollback refused')
            subprocess.run(['tailscale','serve','--tcp=8082','off'],check=True,timeout=15)
        marker.unlink()
        print('Removed only transaction-owned port 8082 mapping')
        PY
        """
    }
}

/// Output is drained concurrently and bounded even when a remote command is noisy.
/// Cancellation closes the SSH channel; it cannot promise the remote command stopped.
enum SetupProcess {
    static func run(_ step: CommandStep) async throws -> String {
        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = step.executable
        process.arguments = step.arguments
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS_REQUIRE"] = "never"
        environment.removeValue(forKey: "SSH_ASKPASS")
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = step.script == nil ? FileHandle.nullDevice : input
        try process.run()
        let reader = Task.detached { () throws -> Data in
            var result = Data()
            while let part = try output.fileHandleForReading.read(upToCount: 4096), !part.isEmpty {
                if result.count < 65537 { result.append(part.prefix(65537 - result.count)) }
            }
            return result
        }
        let writer = Task.detached {
            if let script = step.script { try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8)) }
            try? input.fileHandleForWriting.close()
        }
        do {
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw UsageError.message("SSH timed out; remote outcome unknown.") }
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(100))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw error
        }
        await writer.value
        let data = try await reader.value
        guard data.count <= 65536 else { throw UsageError.oversized }
        guard process.terminationStatus == 0 else {
            let output = String(bytes: data.prefix(4096), encoding: .utf8) ?? "(non-UTF-8 output)"
            throw UsageError.message("Command failed (\(process.terminationStatus)): \(output)")
        }
        guard let output = String(bytes: data, encoding: .utf8)
        else { throw UsageError.message("Output was not UTF-8.") }
        return output
    }

    static func fetch(_ url: URL) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        let http = response as? HTTPURLResponse
        if let http, http.statusCode == 503 { throw await Services.unavailable(bytes, response: http) }
        guard http?.statusCode == 200 else { throw UsageError.message("HTTP endpoint unavailable.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65536 else { throw UsageError.oversized }
            data.append(byte)
        }
        return data
    }
}
