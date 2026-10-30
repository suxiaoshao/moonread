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
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


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


def capture(root):
    state = root / 'build/StoreScreenshots'
    config = json.loads((state / 'session.json').read_text())
    uid, group = config['device'], config['group']
    dimensions = {'iphone-medium': (1206, 2622), 'ipad-13': (2064, 2752),
                  'duo-outer': (1398, 2034), 'duo-inner': (2853, 2007)}[group]
    seen = set()
    while not (state / 'stop').exists():
        try:
            container = Path(run('xcrun', 'simctl', 'get_app_container', uid,
                                 'dev.moonread.MoonreadUITests.xctrunner', 'data'))
        except subprocess.CalledProcessError:
            time.sleep(.5)
            continue
        gate = container / 'tmp/Moonread-StoreScreenshots'
        request = gate / 'request.json'
        if not request.exists():
            time.sleep(.2)
            continue
        item = json.loads(request.read_text())
        if item['token'] in seen:
            time.sleep(.2)
            continue
        page = item.get('kind') == 'page'
        scenes = ('book-details', 'reader-settings', 'settings', 'library-home', 'reader') if page else ('01', '01-paper', '01-kraft', '01-linen', '02', '03', '04', '05', '06', '07', '07-tags', '08')
        if item['language'] not in ('zh-Hans', 'zh-Hant', 'en') or item['scene'] not in scenes:
            raise ValueError('Invalid capture request')
        expected = dimensions
        if page:
            appearance, orientation = item.get('appearance'), item.get('orientation')
            if appearance not in ('light', 'dark') or orientation not in ('portrait', 'landscape', 'current'):
                raise ValueError('Invalid page appearance/orientation')
            short, long = sorted(dimensions)
            expected = (long, short) if orientation == 'landscape' else (short, long) if orientation == 'portrait' else None
            folder = root / 'build/PageShots' / group
            name = item['scene'] + '-' + ('浅' if appearance == 'light' else '深')
        else:
            folder = root / 'build/Release' / (config['version'] + '-screenshots') / item['language'] / group
            name = item['scene']
        folder.mkdir(parents=True, exist_ok=True)
        target = folder / (name + '.png')
        raw = state / 'raw.png'
        arguments = ['xcrun', 'simctl', 'io', uid, 'screenshot']
        if group.startswith('duo-'):
            ports = run('xcrun', 'simctl', 'io', uid, 'enumerate').split('Port:')
            width, height = sorted(dimensions)
            matches = [p for p in ports if f'Default width: {width}' in p and f'Default height: {height}' in p]
            if len(matches) != 1:
                raise ValueError('Cannot identify Duo display; open the requested display in DeviceHub')
            arguments.append('--display=' + re.search(r'UUID: ([A-F0-9-]+)', matches[0]).group(1))
        run(*arguments, str(raw))
        size = struct.unpack('>II', raw.read_bytes()[16:24])
        if (expected is not None and size != expected) or sorted(size) != sorted(dimensions):
            raise ValueError(f'Expected {expected or dimensions}, received {size}; check device/fullscreen/DeviceHub posture')
        if not opaque_pixels(raw, target, display_oriented=page):
            time.sleep(.5)
            continue  # Never acknowledge black frames.
        raw.unlink()
        if not page:
            manifest = folder / 'manifest.json'
            values = json.loads(manifest.read_text()) if manifest.exists() else {}
            values[name] = {key: value for key, value in item.items() if key != 'token'}
            values[name].update(source_commit=config['source_commit'], device=uid, dimensions=size,
                                sha256=hashlib.sha256(target.read_bytes()).hexdigest())
            manifest.write_text(json.dumps(values, ensure_ascii=False, indent=2) + '\n')
        seen.add(item['token'])
        (gate / 'ack').write_text(item['token'])
        print(f'Exported {item["language"]}/{group}/{target.name} ({size[0]}x{size[1]})', flush=True)


def prepare(root, device, group, version):
    state = root / 'build/StoreScreenshots'
    state.mkdir(parents=True, exist_ok=True)
    (state / 'session.json').unlink(missing_ok=True)
    group = group or 'iphone-medium'
    if group not in ('iphone-medium', 'ipad-13', 'duo-outer', 'duo-inner'):
        raise ValueError('Set STORE_SCREENSHOT_DEVICE to a documented device group')
    if not re.fullmatch(r'\d+(?:\.\d+)*', version):
        raise ValueError('Invalid MARKETING_VERSION')
    # The selected xcodebuild destination is the only simulator we operate on.
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', '--json'))['devices']
    selected = next(d for ds in devices.values() for d in ds if d['udid'] == device)
    if selected['state'] != 'Booted':
        run('xcrun', 'simctl', 'boot', device)
    run('xcrun', 'simctl', 'bootstatus', device, '-b')
    state = root / 'build/StoreScreenshots'
    state.mkdir(parents=True, exist_ok=True)
    (state / 'stop').unlink(missing_ok=True)
    (state / 'session.json').write_text(json.dumps({'device': device, 'group': group, 'version': version,
        'source_commit': run('git', '-C', str(root), 'rev-parse', 'HEAD')}))
    try:
        container = Path(run('xcrun', 'simctl', 'get_app_container', device, 'dev.moonread.MoonreadUITests.xctrunner', 'data'))
        for name in ('ack', 'request.json'):
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
    subprocess.run(['xcrun', 'simctl', 'shutdown', config['device']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


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
