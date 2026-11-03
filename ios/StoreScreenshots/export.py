"""Scheme pre/post action: capture/export only; builds remain owned by xcodebuild."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import time
import zlib


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE, timeout=120).strip()


def opaque_pixels(source, target, display_oriented=False):
    """Unfilter native 8-bit PNG pixels; test RGB and strip alpha losslessly.

    Preserve color-profile chunks and native dimensions. No third-party image
    package, resampling, or JPEG round-trip is involved.
    """
    image = source.read_bytes()
    chunks, offset = [], 8
    while offset < len(image):
        count = struct.unpack_from('>I', image, offset)[0]
        kind = image[offset + 4:offset + 8]
        chunks.append((kind, image[offset + 8:offset + 8 + count]))
        offset += count + 12
    header = chunks[0][1]
    width, height, depth, color, compression, filtering, interlace = struct.unpack('>IIBBBBB', header)
    if depth != 8 or color not in (2, 6) or interlace != 0:
        raise ValueError('Expected a native 8-bit RGB/RGBA screenshot')
    channels = 4 if color == 6 else 3
    stride = width * channels
    data = zlib.decompress(b''.join(value for kind, value in chunks if kind == b'IDAT'))
    previous = bytearray(stride)
    rgb_rows, total = [], 0
    for y in range(height):
        start = y * (stride + 1)
        method = data[start]
        row = bytearray(data[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            above = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            if method == 1:
                predictor = left
            elif method == 2:
                predictor = above
            elif method == 3:
                predictor = (left + above) // 2
            elif method == 4:
                estimate = left + above - upper_left
                distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
                predictor = (left, above, upper_left)[distances.index(min(distances))]
            elif method == 0:
                predictor = 0
            else:
                raise ValueError('Invalid PNG filter')
            row[x] = (row[x] + predictor) & 255
        rgb = bytearray(width * 3)
        for channel in range(3):
            rgb[channel::3] = row[channel::channels]
        total += sum(rgb)
        rgb_rows.append(b'\0' + rgb)
        previous = row
    if total <= width * height * 3 * 255 * .001:
        return False

    def chunk(kind, value):
        return struct.pack('>I', len(value)) + kind + value + struct.pack('>I', zlib.crc32(kind + value))

    output = bytearray(image[:8])
    wrote_pixels = False
    for kind, value in chunks:
        # simctl supplies pixels in display orientation. Page shots must not be
        # rotated a second time by viewers honoring an EXIF orientation tag.
        if display_oriented and kind == b'eXIf':
            continue
        if kind == b'IHDR':
            value = struct.pack('>IIBBBBB', width, height, 8, 2, compression, filtering, interlace)
        elif kind == b'IDAT':
            if wrote_pixels:
                continue
            value = zlib.compress(b''.join(rgb_rows))
            wrote_pixels = True
        output += chunk(kind, value)
    target.write_bytes(output)
    return True


DIMENSIONS = {'iphone-medium': (1206, 2622), 'ipad-13': (2064, 2752),
              'ipad-portrait': (2064, 2752), 'ipad-landscape': (2752, 2064),
              'duo-outer': (1398, 2034), 'duo-inner': (2853, 2007)}
SCENES = [f'R{i:02}' for i in range(1, 14)]
PAGES = ['book-details', 'reader-settings', 'settings', 'library-home', 'reader']
LANGUAGES = ['zh-Hans', 'zh-Hant', 'en']


def option(name, default=''):
    value = os.environ.get(name, '')
    return value if value and not value.startswith('$(') else default


def csv(name, default=''):
    return option(name, default).split(',')


def validate(item):
    if item['scene'] not in SCENES + PAGES or item['language'] not in LANGUAGES:
        raise ValueError('Invalid scene/language')
    if item['group'] not in DIMENSIONS or item['appearance'] not in ('light', 'dark') or item['systemAppearance'] not in ('light', 'dark'):
        raise ValueError('Invalid device/appearance')
    if item['orientation'] not in ('portrait', 'landscape', 'current'):
        raise ValueError('Invalid orientation')
    if not re.fullmatch(r'[A-Z]{3}', item['storefront']) or not isinstance(item['readerTextureEnabled'], bool):
        raise ValueError('Invalid storefront/texture switch')
    # The App resolves/validates these production IDs through Rust and returns a
    # receipt; exporter checks receipt before acknowledging any pixels.
    if not all(re.fullmatch(r'[a-z0-9-]+', item[k]) for k in ('appPalette', 'readerPalette')):
        raise ValueError('Invalid palette ID')
    if not re.fullmatch(r'[A-Za-z0-9-]+', item['id']):
        raise ValueError('Invalid capture ID')
    path = f"raw/{item['language']}/{item['group']}/{item['appearance']}/{item['scene']}.png"
    if item.get('rawPath', path) != path:
        raise ValueError('Capture path differs from canonical scene/device/language/appearance path')
    return item


def make_plan(root, group):
    matrix = option('STORE_SCREENSHOT_MATRIX')
    languages = csv('STORE_SCREENSHOT_LANGUAGES', 'zh-Hans' if option('PAGE_SHOT_SCENE') else 'zh-Hans,zh-Hant,en')
    scenes = csv('STORE_SCREENSHOT_SCENES')
    ids = csv('STORE_SCREENSHOT_IDS')
    appearances = csv('STORE_SCREENSHOT_APPEARANCES', 'light,dark' if matrix else 'light')
    if not set(languages) <= set(LANGUAGES) or not set(appearances) <= {'light', 'dark'}:
        raise ValueError('Invalid language/appearance filter')
    if matrix:
        path = Path(matrix)
        doc = json.loads((path if path.is_absolute() else root / path).read_text())
        rows = []
        for row in doc['captures']:
            d = doc['devices'][row['device']]
            if tuple(d['pixels']) != DIMENSIONS[d['group']]: raise ValueError('Matrix device dimensions differ from capture contract')
            item = dict(row, group=d['group'], orientation=d['orientation'])
            rows.append(validate(item))
        if len({r['id'] for r in rows}) != len(rows) or len({r['rawPath'] for r in rows}) != len(rows):
            raise ValueError('Matrix has duplicate IDs/paths')
        rows = [r for r in rows if (r['group'] == group or group == 'ipad-13' and r['group'].startswith('ipad-'))
                and r['language'] in languages and r['appearance'] in appearances
                and (scenes == [''] or r['scene'] in scenes) and (ids == [''] or r['id'] in ids)]
    else:
        page = option('PAGE_SHOT_SCENE')
        selected = [page] if page else (scenes if scenes != [''] else SCENES)
        if page: appearances = [option('PAGE_SHOT_APPEARANCE', 'light')]
        rows = []
        for language in languages:
            for appearance in appearances:
                for scene in selected:
                    app = 'apricot-' + appearance
                    reader = ('mint-' + appearance if scene == 'R12' else 'bean-light' if scene == 'R13'
                              else ('black-dark' if appearance == 'dark' else 'white-light') if scene in ('R03', 'R08', 'R09') else app)
                    orientation = option('PAGE_SHOT_ORIENTATION') if page else option('STORE_SCREENSHOT_ORIENTATION')
                    orientation = orientation or ('landscape' if group in ('duo-inner', 'ipad-landscape') or page and group == 'ipad-13' else 'current' if group.startswith('duo-') else 'portrait')
                    rows.append(validate(dict(id=f'{scene}-{group}-{language}-{appearance}', scene=scene, group=group,
                        language=language, appearance=appearance, systemAppearance=appearance,
                        appPalette=option('STORE_SCREENSHOT_APP_PALETTE', app), readerPalette=option('STORE_SCREENSHOT_READER_PALETTE', reader),
                        readerTextureEnabled=scene in ('R01', 'R12', 'R13'), orientation=orientation,
                        storefront=option('STORE_SCREENSHOT_STOREFRONT', 'CHN' if page else 'USA'))))
    if not rows:
        raise ValueError('No captures match the selected matrix batch')
    return rows


def capture(root):
    state = root / 'build/StoreScreenshots'
    config = json.loads((state / 'session.json').read_text())
    uid, seen, active = config['device'], set(), None
    desktop_language = None
    gate = None
    try:
        while not (state / 'stop').exists():
            try:
                container = Path(run('xcrun', 'simctl', 'get_app_container', uid,
                                     'dev.moonread.MoonreadUITests.xctrunner', 'data'))
            except subprocess.CalledProcessError:
                time.sleep(.5); continue  # Runner is not installed yet.
            gate = container / 'tmp/Moonread-StoreScreenshots'
            request = gate / 'request.json'
            if not request.exists():
                time.sleep(.2); continue
            request_item = json.loads(request.read_text())
            if request_item['token'] in seen:
                time.sleep(.2); continue
            kind = request_item['kind']
            if kind == 'plan':
                (gate / 'plan.json').write_text(json.dumps(config['plan']))
            elif kind == 'setup':
                item = validate(request_item['capture'])
                if not any(all(item.get(k) == row.get(k) for k in item) for row in config['plan']):
                    raise ValueError('Request was not part of the prepared plan')
                run('xcrun', 'simctl', 'ui', uid, 'appearance', item['systemAppearance'])
                desktop_language = None
                if item['scene'] == 'R04':
                    languages = run('xcrun', 'simctl', 'spawn', uid, 'defaults', 'read', 'NSGlobalDomain', 'AppleLanguages')
                    desktop_language = re.findall(r'[A-Za-z]+(?:-[A-Za-z0-9]+)*', languages)[0]
                    if not desktop_language.startswith(item['language']):
                        raise ValueError(f"R04 needs system language {item['language']}; current {desktop_language}. Change it in simulator Settings first.")
                active = item
            elif kind == 'photo':
                item = validate(request_item['capture'])
                if item != active: raise ValueError('Photo has no matching setup')
                app_container = Path(run('xcrun', 'simctl', 'get_app_container', uid, 'dev.moonread.Moonread', 'data'))
                receipt = json.loads((app_container / 'tmp/StoreScreenshots-fixture.json').read_text())
                for key in ('id', 'language', 'storefront', 'appPalette', 'readerPalette', 'readerTextureEnabled'):
                    if receipt[key] != item[key]: raise ValueError(f'Applied fixture differs: {key}')
                if receipt['pendingCount'] or receipt['unsupportedCount'] or receipt['libraryCount'] != 6:
                    raise ValueError('Synthetic library is not ready')
                page, group = item['scene'] in PAGES, item['group']
                dimensions = DIMENSIONS[group]
                short, long = sorted(dimensions)
                orientation = item['orientation']
                expected = (long, short) if orientation == 'landscape' else (short, long) if orientation == 'portrait' else dimensions
                base = root / 'build/Release' / (config['version'] + '-screenshots')
                target = (root / 'build/PageShots' / group / (item['scene'] + '-' + ('浅' if item['appearance'] == 'light' else '深') + '.png')) if page else base / item.get('rawPath', f"raw/{item['language']}/{group}/{item['appearance']}/{item['scene']}.png")
                target.parent.mkdir(parents=True, exist_ok=True)
                raw = state / 'raw.png'
                arguments = ['xcrun', 'simctl', 'io', uid, 'screenshot']
                if group.startswith('duo-'):
                    ports = run('xcrun', 'simctl', 'io', uid, 'enumerate').split('Port:')
                    matches = [p for p in ports if f'Default width: {short}' in p and f'Default height: {long}' in p]
                    if len(matches) != 1: raise ValueError('Cannot identify Duo display; select posture in DeviceHub')
                    arguments.append('--display=' + re.search(r'UUID: ([A-F0-9-]+)', matches[0]).group(1))
                run(*arguments, str(raw))
                size = struct.unpack('>II', raw.read_bytes()[16:24])
                if size != expected: raise ValueError(f'Expected {expected}, received {size}; check fullscreen/posture')
                if not opaque_pixels(raw, target, display_oriented=True): raise ValueError('Black screenshot; not acknowledged')
                raw.unlink()
                if not page:
                    manifest = base / 'raw/manifest.json'
                    values = json.loads(manifest.read_text()) if manifest.exists() else {}
                    plan_row = next(r for r in config['plan'] if r['id'] == item['id'])
                    values[item['id']] = dict(plan_row, state='captured-unreviewed', fixtureVersion=receipt['fixtureVersion'], applied=receipt, source_commit=config['source_commit'],
                        source_dirty=config['source_dirty'], source_diff_sha256=config['source_diff_sha256'],
                        device=uid, device_model=config['model'], runtime=config['runtime'], system_language=desktop_language, dimensions=size,
                        captured_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                        sha256=hashlib.sha256(target.read_bytes()).hexdigest(), pixel_check='nonblack-native-rgb',
                        review='pending-visual-review')
                    manifest.write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n')
                print(f'Exported {item["id"]} {size}', flush=True)
            else: raise ValueError('Unknown exporter operation')
            seen.add(request_item['token'])
            (gate / 'ack').write_text(request_item['token'])
    except Exception as error:
        if gate is not None:
            gate.mkdir(parents=True, exist_ok=True)
            (gate / 'error.txt').write_text(str(error))
        raise


def prepare(root, device, group, version):
    state = root / 'build/StoreScreenshots'
    state.mkdir(parents=True, exist_ok=True)
    (state / 'session.json').unlink(missing_ok=True)
    group = group or 'iphone-medium'
    if group not in DIMENSIONS:
        raise ValueError('Set STORE_SCREENSHOT_DEVICE to a documented device group')
    if not re.fullmatch(r'\d+(?:\.\d+)*', version):
        raise ValueError('Invalid MARKETING_VERSION')
    # The selected xcodebuild destination is the only simulator we operate on.
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', '--json'))['devices']
    runtime, selected = next((runtime, d) for runtime, ds in devices.items() for d in ds if d['udid'] == device)
    if selected['state'] != 'Booted':
        run('xcrun', 'simctl', 'boot', device)
    run('xcrun', 'simctl', 'bootstatus', device, '-b')
    state = root / 'build/StoreScreenshots'
    state.mkdir(parents=True, exist_ok=True)
    (state / 'stop').unlink(missing_ok=True)
    (state / 'session.json').write_text(json.dumps({'device': device, 'group': group, 'version': version,
        'source_commit': run('git', '-C', str(root), 'rev-parse', 'HEAD'),
        'source_dirty': bool(run('git', '-C', str(root), 'status', '--porcelain')),
        'source_diff_sha256': hashlib.sha256(run('git', '-C', str(root), 'diff', 'HEAD').encode()).hexdigest(),
        'original_appearance': run('xcrun', 'simctl', 'ui', device, 'appearance').lower(),
        'model': selected['name'], 'runtime': runtime, 'plan': make_plan(root, group)}))
    try:
        container = Path(run('xcrun', 'simctl', 'get_app_container', device, 'dev.moonread.MoonreadUITests.xctrunner', 'data'))
        for name in ('ack', 'request.json', 'plan.json', 'error.txt'):
            (container / 'tmp/Moonread-StoreScreenshots' / name).unlink(missing_ok=True)
    except subprocess.CalledProcessError:
        pass  # First install of the test runner.
    run('xcrun', 'simctl', 'status_bar', device, 'override', '--time', '9:41', '--dataNetwork', 'wifi',
        '--wifiMode', 'active', '--wifiBars', '3', '--cellularMode', 'active', '--cellularBars', '4',
        '--batteryState', 'charged', '--batteryLevel', '100')
    run('xcrun', 'simctl', 'ui', device, 'content_size', 'large')
    with (state / 'export.log').open('w') as log:
        subprocess.Popen([sys.executable, __file__, 'capture', '--root', str(root)],
                         stdout=log, stderr=subprocess.STDOUT, start_new_session=True)


def finish(root):
    state = root / 'build/StoreScreenshots'
    if not (state / 'session.json').exists():
        return
    (state / 'stop').touch()
    config = json.loads((state / 'session.json').read_text())
    try:
        group = Path(run('xcrun', 'simctl', 'get_app_container', config['device'],
                         'dev.moonread.Moonread', 'group.dev.moonread.Moonread'))
        # Only our separately named, synthetic widget fixture; not SystemReading/v1.
        shutil.rmtree(group / 'StoreScreenshots', ignore_errors=True)
        subprocess.run(['defaults', 'delete', str(group / 'Library/Preferences/group.dev.moonread.Moonread'),
                        'StoreScreenshots.language'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        pass  # No App/Group installed if the build failed before running.
    if config.get('original_appearance') in ('light', 'dark'):
        run('xcrun', 'simctl', 'ui', config['device'], 'appearance', config['original_appearance'])
    subprocess.run(['xcrun', 'simctl', 'shutdown', config['device']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=120)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['prepare', 'capture', 'finish'])
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--device')
    parser.add_argument('--group')
    parser.add_argument('--version')
    args = parser.parse_args()
    if args.action == 'prepare':
        prepare(args.root, args.device, args.group, args.version)
    elif args.action == 'capture':
        capture(args.root)
    else:
        finish(args.root)
