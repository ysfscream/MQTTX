import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import traceback

from PIL import Image

out = Path('visual-results').resolve()
checks = []
processes = []


def check(name, passed, detail):
    checks.append(dict(name=name, pass_=bool(passed), detail=detail))
    data = [{('pass' if k == 'pass_' else k): v for k, v in c.items()} for c in checks]
    (out / 'linux-checks.json').write_text(json.dumps(data, indent=2) + '\n')
    print(name, bool(passed), detail, flush=True)


def run(args):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def start(args, logfile):
    with (out / logfile).open('w') as log:
        p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT)
    processes.append(p)
    return p


def find_window(executable):
    result = run(['xdotool', 'search', '--onlyvisible', '--name', 'MQTTX'])
    for wid in result.stdout.splitlines():
        pid_text = run(['xprop', '-id', wid, '_NET_WM_PID']).stdout
        match = re.search(r'= (\d+)', pid_text)
        if match:
            try:
                if Path('/proc', match[1], 'exe').resolve() == executable.resolve():
                    return wid
            except FileNotFoundError:
                pass
    return None


try:
    check('environment', True, dict(os=run(['uname', '-a']).stdout.strip(), commit=os.getenv('GITHUB_SHA')))
    debs = list(Path('dist_electron').glob('*.deb'))
    check('deb-x64-package', len(debs) == 1, [str(p) for p in debs])
    deb = debs[0]
    architecture = run(['dpkg-deb', '-f', str(deb), 'Architecture']).stdout.strip()
    check('deb-architecture', architecture == 'amd64', architecture)
    install = run(['sudo', 'apt-get', 'install', '-y', './' + str(deb)])
    (out / 'linux-install.log').write_text(install.stdout)
    check('native-deb-install', install.returncode == 0, dict(exitCode=install.returncode, command='sudo apt-get install -y ./dist_electron/*.deb'))
    package = run(['dpkg-deb', '-f', str(deb), 'Package']).stdout.strip()
    listing = run(['dpkg', '-L', package])
    (out / 'linux-dpkg-files.txt').write_text(listing.stdout)
    paths = listing.stdout.splitlines()
    icons = [Path(p) for p in paths if re.fullmatch(r'/usr/share/icons/hicolor/512x512/apps/[^/]+\.png', p)]
    check('hicolor-512-installed', listing.returncode == 0 and len(icons) == 1, [str(p) for p in icons])
    icon = icons[0]
    with Image.open(icon) as image:
        check('installed-icon-size', image.size == (512, 512), list(image.size))
        image.save(out / 'linux-installed-icon-512.png')
    installed_sha = hashlib.sha256(icon.read_bytes()).hexdigest()
    source_sha = hashlib.sha256(Path('public/icons/512x512.png').read_bytes()).hexdigest()
    check('installed-icon-sha256', installed_sha == source_sha, dict(installed=installed_sha, source=source_sha))
    desktop = next(Path(p) for p in paths if p.startswith('/usr/share/applications/') and p.endswith('.desktop'))
    desktop_text = desktop.read_text()
    (out / 'linux-desktop-entry.txt').write_text(desktop_text)
    icon_value = re.search(r'^Icon=(.+)$', desktop_text, re.M).group(1)
    check('desktop-icon-resolution', icon_value in (icon.stem, str(icon)), dict(desktop=str(desktop), Icon=icon_value, resolved=str(icon)))
    validation = run(['desktop-file-validate', str(desktop)])
    check('desktop-file-validate', validation.returncode == 0, dict(exitCode=validation.returncode, output=validation.stdout))
    executable = Path(shlex.split(re.search(r'^Exec=(.+)$', desktop_text, re.M).group(1))[0])
    check('installed-executable', executable.is_file() and str(executable) in paths, str(executable))
    os.environ['DISPLAY'] = ':99'
    runtime = out / 'runtime'
    runtime.mkdir(mode=0o700, exist_ok=True)
    os.environ['XDG_RUNTIME_DIR'] = str(runtime)
    start(['Xvfb', ':99', '-screen', '0', '1920x1080x24', '-ac'], 'linux-xvfb.log')
    for _ in range(30):
        if run(['xdpyinfo']).returncode == 0:
            break
        time.sleep(1)
    # Openbox N in titleLayout is the client icon; keep the normal system theme.
    rc = Path('/etc/xdg/openbox/rc.xml').read_text()
    rc = re.sub(r'<titleLayout>.*?</titleLayout>', '<titleLayout>NLIMC</titleLayout>', rc)
    (out / 'openbox-rc.xml').write_text(rc)
    start(['openbox', '--config-file', str(out / 'openbox-rc.xml')], 'linux-openbox.log')
    panel = '''panel_items = TSC
panel_size = 100% 40
panel_position = bottom center horizontal
panel_background_id = 0
taskbar_mode = single_desktop
task_icon = 1
task_text = 1
task_maximum_size = 240 36
task_padding = 8 4 8
task_font = Sans 12
task_font_color = #ffffff 100
time1_format = %H:%M
time1_font = Sans 12
clock_font_color = #ffffff 100
systray_icon_size = 24
'''
    (out / 'tint2.conf').write_text(panel)
    start(['tint2', '-c', str(out / 'tint2.conf')], 'linux-tint2.log')
    time.sleep(4)
    app = start([str(executable)], 'linux-app.log')
    wid = None
    for _ in range(60):
        wid = find_window(executable)
        if wid or app.poll() is not None:
            break
        time.sleep(1)
    log = (out / 'linux-app.log').read_text(errors='replace')
    sandbox_failure = not wid and app.poll() is not None and re.search(r'sandbox|Failed to move to new namespace|Operation not permitted', log, re.I)
    if sandbox_failure:
        check('sandbox-launch', True, dict(fallback='--no-sandbox', reason=log, initialExitCode=app.returncode))
        app = start([str(executable), '--no-sandbox'], 'linux-app-no-sandbox.log')
        for _ in range(60):
            wid = find_window(executable)
            if wid or app.poll() is not None:
                break
            time.sleep(1)
    else:
        check('sandbox-launch', bool(wid), dict(fallback=None, exitCode=app.poll(), log=log))
    check('installed-main-window-visible', bool(wid), dict(windowID=wid, executable=str(executable), launchedPID=app.pid))
    if not wid:
        raise RuntimeError('No visible installed MQTTX main window')
    run(['xdotool', 'windowactivate', '--sync', wid])
    run(['xdotool', 'windowmove', wid, '300', '80'])
    time.sleep(10)
    initial = run(['scrot', str(out / 'linux-initial-desktop.png')])
    check('initial-desktop-screenshot', initial.returncode == 0, initial.stdout)
    notes = run(['xdotool', 'search', '--onlyvisible', '--name', 'MQTTX.*Release Note']).stdout.splitlines()
    for note in notes:
        run(['xdotool', 'windowclose', note])
    check('release-note-dismissed', True, dict(windows=notes, reason='Initial desktop retained; capture unobstructed main window'))
    time.sleep(2)
    run(['xdotool', 'windowactivate', '--sync', wid])
    # xprop defaults to 250000 bytes, truncating a 512x512 ARGB property.
    props = run(['xprop', '-id', wid, '-len', '16777216', '-notype', '-f', '_NET_WM_ICON', '32c', '_NET_WM_ICON'])
    (out / 'linux-net-wm-icon.txt').write_text(props.stdout)
    values = [int(v) for v in re.findall(r'\d+', props.stdout.partition('=')[2])]
    dimensions = []
    offset = 0
    while offset + 2 <= len(values):
        w, h = values[offset:offset + 2]
        offset += 2
        if not (0 < w <= 2048 and 0 < h <= 2048 and offset + w * h <= len(values)):
            raise RuntimeError('Malformed _NET_WM_ICON')
        image = Image.new('RGBA', (w, h))
        image.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255, (v >> 24) & 255) for v in values[offset:offset + w * h]])
        image.save(out / f'linux-window-icon-{w}x{h}.png')
        dimensions.append([w, h])
        offset += w * h
    check('net-wm-icon-dimensions', bool(dimensions) and offset == len(values), dimensions)
    (out / 'linux-window-properties.txt').write_text(run(['xprop', '-id', wid, 'WM_CLASS', 'WM_NAME', '_NET_WM_PID']).stdout)
    screenshot = run(['scrot', str(out / 'linux-fullscreen.png')])
    check('full-desktop-screenshot', screenshot.returncode == 0, dict(display='1920x1080x24', WM='openbox (titleLayout NLIMC)', panel='tint2 (task_icon=1)', output=screenshot.stdout))
except Exception:
    detail = traceback.format_exc()
    (out / 'linux-error.log').write_text(detail)
    check('harness-completed', False, detail)
finally:
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()

raise SystemExit(0 if checks and all(c['pass_'] for c in checks) else 1)
