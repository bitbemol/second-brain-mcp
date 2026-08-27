"""Bounded real-stdio test client; operates only on explicitly owned disposable vaults."""
import hashlib
import json
import os
from pathlib import Path
import signal
import select
import shutil
import stat
import subprocess
import tempfile
import threading
import time

ROOT = None
SUPPORT_PARENT = Path.home() / 'Library/Application Support/SecondBrainMCP'
MAX_FRAME = 8 * 1024 * 1024
MAX_STDERR = 32768


def require_unoptimized():
    if not __debug__:
        raise RuntimeError('Optimized Python disables benchmark checks; run without -O/PYTHONOPTIMIZE')


def close_owned_client(client, report, key):
    """Return whether the child was reaped; verification failure is retained separately."""
    try:
        report[key] = client.close()
    except BaseException as error:
        report['shutdown_error'] = repr(error)
        return False
    if report[key].get('exit_code') != 0 or report[key].get('forced_signals') != 0:
        report['shutdown_error'] = 'Server did not exit cleanly: ' + repr(report[key])
    return True


def cleanup_fixture(vault, identity, support, report):
    """Remove only verified owned roots; retain every cleanup failure in evidence."""
    outcomes = report.setdefault('cleanup', [])
    errors = report.setdefault('cleanup_errors', [])
    for path in [vault] + list(support):
        try:
            if path == vault:
                if ROOT is None or path.parent != ROOT:
                    raise RuntimeError('Refusing cleanup outside the owned evidence root')
            elif (path.parent != SUPPORT_PARENT or len(path.name) != 32
                  or any(c not in '0123456789abcdef' for c in path.name)):
                raise RuntimeError('Refusing an unexpected support directory')
            if path != vault and not (path.exists() or path.is_symlink()):
                continue
            current = path.lstat()
            if (not stat.S_ISDIR(current.st_mode) or stat.S_ISLNK(current.st_mode)
                    or current.st_uid != os.getuid()):
                raise RuntimeError('Refusing cleanup of a substituted or unowned directory')
            if path == vault and (current.st_dev, current.st_ino) != (identity.st_dev, identity.st_ino):
                raise RuntimeError('Refusing cleanup after owned vault identity changed')
            shutil.rmtree(path)
            outcomes.append({'removed_owned_directory': str(path)})
        except BaseException as error:
            errors.append({'path': str(path), 'error': repr(error)})
    return not errors


def artifact_root(output=None):
    """Create a fresh evidence directory, never reuse or delete an existing directory."""
    global ROOT
    if output is None:
        ROOT = Path(tempfile.mkdtemp(prefix='second-brain-validation-')).resolve()
    else:
        destination = output.expanduser().absolute()
        destination.mkdir(parents=False, exist_ok=False)
        ROOT = destination.resolve()
    print(json.dumps({'artifacts': str(ROOT)}), flush=True)
    return ROOT


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def owned(path):
    path = path.resolve()
    if ROOT is None or not path.is_relative_to(ROOT) or path == ROOT:
        raise RuntimeError('Refusing a non-harness-owned path')
    return path


def support_candidates(vault):
    canonical = str(owned(vault))
    spellings = {canonical}
    for original, alias in [('/private/tmp/', '/tmp/'), ('/private/var/', '/var/')]:
        if canonical.startswith(original):
            spellings.add(canonical.replace(original, alias, 1))
    return sorted(SUPPORT_PARENT / hashlib.sha256(p.encode()).hexdigest()[:32]
                  for p in spellings)


def structured(value):
    if not value['success']:
        raise RuntimeError(f'Tool failed: {value["response"]}')
    result = value['response']['result']
    if 'structuredContent' not in result:
        raise RuntimeError('Required structured result missing')
    return result['structuredContent']


class Ticket:
    def __init__(self, identifier, method, start, request_bytes, deadline):
        self.id, self.method, self.start_ns, self.request_bytes = identifier, method, start, request_bytes
        self.deadline = deadline


class RPC:
    """A reader thread timestamps complete frames even while the other server is awaited."""
    def __init__(self, binary, vault, read_only):
        command = [str(binary), '--vault', str(vault)]
        if read_only:
            command.append('--read-only')
        self.p = subprocess.Popen(command, cwd=vault, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  bufsize=0, start_new_session=True)
        os.set_blocking(self.p.stdin.fileno(), False)
        self.request_timeout = 45
        self.lock = threading.Condition()
        self.write_lock = threading.Lock()
        self.counter = 0
        self.responses = {}
        self.fatal = None
        self.stderr = bytearray()
        self.stderr_total = 0
        self.notifications = 0
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.errors = threading.Thread(target=self._errors, daemon=True)
        self.reader.start()
        self.errors.start()

    def _read(self):
        buffer = bytearray()
        try:
            while True:
                block = os.read(self.p.stdout.fileno(), 65536)
                if not block:
                    raise EOFError('server stdout closed')
                buffer.extend(block)
                if len(buffer) > MAX_FRAME:
                    raise RuntimeError('RPC frame exceeded 8MiB ceiling')
                while b'\n' in buffer:
                    line, _, rest = buffer.partition(b'\n')
                    buffer = bytearray(rest)
                    arrived = time.perf_counter_ns()
                    value = json.loads(line)
                    with self.lock:
                        if 'id' in value:
                            if len(self.responses) >= 16:
                                raise RuntimeError('Too many unmatched RPC frames')
                            self.responses[value['id']] = (value, arrived, len(line) + 1)
                        else:
                            self.notifications += 1
                        self.lock.notify_all()
        except Exception as error:
            with self.lock:
                self.fatal = repr(error)
                self.lock.notify_all()

    def _errors(self):
        while True:
            block = os.read(self.p.stderr.fileno(), 8192)
            if not block:
                return
            self.stderr_total += len(block)
            self.stderr.extend(block[:max(0, MAX_STDERR - len(self.stderr))])

    def begin(self, method, params, notification=False):
        deadline = time.perf_counter() + self.request_timeout
        if not self.write_lock.acquire(timeout=self.request_timeout):
            raise TimeoutError(f'{method} exceeded its request deadline while waiting to write')
        try:
            if self.fatal:
                raise RuntimeError(self.fatal)
            self.counter += 1
            request = {'jsonrpc': '2.0', 'method': method, 'params': params}
            if not notification:
                request['id'] = self.counter
            raw = json.dumps(request, separators=(',', ':')).encode() + b'\n'
            start = time.perf_counter_ns()
            offset = 0
            while offset < len(raw):
                remaining = deadline - time.perf_counter()
                if remaining <= 0:
                    raise TimeoutError(f'{method} exceeded its request deadline while writing')
                try:
                    written = os.write(self.p.stdin.fileno(), memoryview(raw)[offset:])
                except BlockingIOError:
                    select.select([], [self.p.stdin.fileno()], [], remaining)
                    continue
                except InterruptedError:
                    continue
                if not written:
                    raise BrokenPipeError('Server stdin closed while writing a request')
                offset += written
            return Ticket(self.counter, method, start, len(raw), deadline)
        except BaseException as error:
            # A failed partial frame cannot be retried on this connection.
            with self.lock:
                self.fatal = repr(error)
                self.lock.notify_all()
            raise
        finally:
            self.write_lock.release()

    def done(self, ticket):
        with self.lock:
            return ticket.id in self.responses

    def wait(self, ticket, timeout=None):
        deadline = ticket.deadline
        if timeout is not None:
            deadline = min(deadline, time.perf_counter() + timeout)
        with self.lock:
            while ticket.id not in self.responses:
                if self.fatal:
                    raise RuntimeError(f'{ticket.method}: {self.fatal}; stderr={self.stderr.decode(errors="replace")}')
                remaining = deadline - time.perf_counter()
                if remaining <= 0:
                    raise TimeoutError(f'{ticket.method} exceeded its request deadline')
                self.lock.wait(remaining)
            response, arrived, size = self.responses.pop(ticket.id)
        if arrived / 1e9 > deadline:
            raise TimeoutError(f'{ticket.method} response arrived after its request deadline')
        result = response.get('result', {})
        return {'start_ns': ticket.start_ns, 'arrived_ns': arrived,
                'elapsed_ms': (arrived - ticket.start_ns) / 1e6,
                'request_bytes': ticket.request_bytes, 'response_bytes': size,
                'success': 'error' not in response and not result.get('isError', False),
                'response': response}

    def call(self, name, arguments):
        return self.begin('tools/call', {'name': name, 'arguments': arguments})

    def initialize(self):
        value = self.wait(self.begin('initialize', {
            'protocolVersion': '2025-06-18', 'capabilities': {},
            'clientInfo': {'name': 'second-brain-writer-gate0', 'version': '1'}}))
        if not value['success']:
            raise RuntimeError('Initialization failed')
        self.begin('notifications/initialized', {}, notification=True)
        return value

    def close(self):
        try:
            self.p.stdin.close()
        except BrokenPipeError:
            pass
        deadline = time.monotonic() + 5
        sent = 0
        while True:
            pid, status, usage = os.wait4(self.p.pid, os.WNOHANG)
            if pid:
                break
            if time.monotonic() >= deadline:
                sent += 1
                os.killpg(self.p.pid, signal.SIGTERM if sent == 1 else signal.SIGKILL)
                deadline = time.monotonic() + 2
            time.sleep(.01)
        self.p.returncode = os.waitstatus_to_exitcode(status)
        self.reader.join(1)
        self.errors.join(1)
        self.p.stdout.close()
        self.p.stderr.close()
        return {'exit_code': self.p.returncode, 'forced_signals': sent,
                'peak_rss_bytes': usage.ru_maxrss, 'user_cpu_s': usage.ru_utime,
                'system_cpu_s': usage.ru_stime, 'stderr_bytes': self.stderr_total,
                'stderr_prefix': self.stderr.decode(errors='replace')}
