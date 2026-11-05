#!/usr/bin/env python3
"""Prepare isolated local fixtures and capture repeatable native launch traces."""
import argparse
import csv
import json
from pathlib import Path
import shutil
import statistics
import xml.etree.ElementTree as ET
import subprocess
import tempfile
import wave

BUNDLE = 'com.elsterlee.NeoMusic'


def run(*args, check=True):
    return subprocess.run(args, check=check, text=True, capture_output=True)


def audio_fixtures(directory, count, artwork):
    # Silence keeps playback deterministic and avoids audible test output.
    base = directory / 'fixture-source.wav'
    with wave.open(str(base), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(bytes(8000 * 2 * 60))
    if not artwork:
        return [base]
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise SystemExit('--artwork requires the installed ffmpeg command.')
    assets = Path(__file__).resolve().parents[1] / 'NeoMusic/Resources/HomeAssets.xcassets'
    covers = sorted(assets.glob('AlbumSample*.imageset/cover.jpg'))[:(count + 14) // 15]
    if not covers:
        raise SystemExit('Performance artwork fixtures require the bundled album covers.')
    sources = []
    for index, cover in enumerate(covers):
        target = directory / f'fixture-{index:02d}.mp3'
        # AVFoundation exposes the ID3 APIC picture as commonKeyArtwork.
        run(ffmpeg, '-hide_banner', '-loglevel', 'error', '-y',
            '-i', str(base), '-i', str(cover), '-map', '0:a:0', '-map', '1:v:0',
            '-c:a', 'libmp3lame', '-b:a', '32k', '-ar', '22050', '-c:v', 'copy',
            '-id3v2_version', '3', '-disposition:v', 'attached_pic',
            '-metadata:s:v', 'title=Album cover', '-metadata:s:v', 'comment=Cover (front)', str(target))
        sources.append(target)
    return sources


def seed(simulator, count=180, artwork=False):
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', '--json').stdout)
    device = next(d for group in devices['devices'].values() for d in group if d['udid'] == simulator)
    if not device['name'].startswith('NeoMusic Performance'):
        raise SystemExit('Fixture writes require a dedicated NeoMusic Performance simulator.')
    run('xcrun', 'simctl', 'terminate', simulator, BUNDLE, check=False)
    container = Path(run('xcrun', 'simctl', 'get_app_container', simulator, BUNDLE, 'data').stdout.strip())
    music = container / 'Documents/音乐'
    store = container / 'Library/Application Support/LocalLibrary'
    music.mkdir(parents=True, exist_ok=True)
    store.mkdir(parents=True, exist_ok=True)
    ids = []
    with tempfile.TemporaryDirectory(prefix='neomusic-performance-') as temporary:
        sources = audio_fixtures(Path(temporary), count, artwork)
        # Re-seeding this dedicated container replaces only generated audio,
        # including the previous format when switching between WAV and MP3.
        for extension in ('wav', 'mp3'):
            for existing in music.glob(f'Album [0-9]*/Track [0-9]*.{extension}'):
                existing.unlink()
        for index in range(1, count + 1):
            album_index = (index - 1) // 15
            album = music / f'Album {album_index + 1:02d}'
            album.mkdir(exist_ok=True)
            source = sources[album_index % len(sources)]
            target = album / f'Track {index:03d}{source.suffix}'
            shutil.copy2(source, target)
            ids.append(str(target.relative_to(music)))
    playlist = dict(id='performance-playlist', title='Performance Playlist', description='',
                    showsOnProfile=False, isFavorite=False, isPinned=True, isSystem=False,
                    addedOrder=1, lastPlayedOrder=0, updatedOrder=1, songs=ids)
    favorite = dict(playlist, id='favorites', title='喜爱歌曲', isFavorite=True, isSystem=True,
                    songs=[], addedOrder=0)
    (store / 'playlists.json').write_text(json.dumps(dict(playlists=[favorite, playlist], folders=[], placement={}, nextOrder=2)))
    (store / 'playback.json').write_text(json.dumps(dict(ids=ids, index=0, elapsed=0, repeatMode='all', shuffled=False, source='Performance Playlist')))
    print(json.dumps(dict(simulator=simulator, songs=len(ids), albums=(count + 14) // 15,
                         artwork=artwork, container=str(container))))


def launch_traces(simulator, app, output, count):
    output.mkdir(parents=True, exist_ok=True)
    for index in range(1, count + 1):
        run('xcrun', 'simctl', 'terminate', simulator, BUNDLE, check=False)
        trace = output / f'launch-{index}.trace'
        result = run('xcrun', 'xctrace', 'record', '--template', 'App Launch', '--device', simulator,
                     '--time-limit', '5s', '--output', str(trace), '--launch', '--', app, check=False)
        (output / f'launch-{index}.log').write_text(result.stdout + result.stderr)
        if result.returncode:
            raise SystemExit(result.stdout + result.stderr)
        exported = run('xcrun', 'xctrace', 'export', '--input', str(trace), '--toc').stdout
        (output / f'launch-{index}-toc.xml').write_text(exported)
        lifecycle = run('xcrun', 'xctrace', 'export', '--input', str(trace), '--xpath',
                        '/trace-toc/run[@number="1"]/data/table[@schema="life-cycle-period"]').stdout
        (output / f'launch-{index}-lifecycle.xml').write_text(lifecycle)
        print(f'Captured {trace}', flush=True)
    measurements = []
    for file in sorted(output.glob('launch-*-lifecycle.xml')):
        tree = ET.fromstring(file.read_text())
        refs = {e.attrib['id']: e for e in tree.iter() if 'id' in e.attrib}
        stages = []
        for row in tree.findall('.//row'):
            values = [refs.get(e.attrib.get('ref'), e) for e in row]
            stage = {e.tag: e.text for e in values if e.tag in ('start-time', 'duration', 'app-period')}
            if len(stage) == 3: stages.append(stage)
        initial = next((s for s in stages if 'System Interface Initialization' in s['app-period']), None)
        frame = next((s for s in stages if 'Initial Frame Rendering' in s['app-period']), None)
        if frame:
            measurements.append(dict(trace=file.name, initial_frame_ms=int(frame['duration']) / 1e6,
                system_to_frame_ms=(int(frame['start-time']) + int(frame['duration']) - int(initial['start-time'])) / 1e6 if initial else None))
    summary = {'samples': measurements, 'lifecycle_available': bool(measurements)}
    if not measurements:
        summary['note'] = 'The exported lifecycle table contains no Initial Frame Rendering rows.'
    for key in ('initial_frame_ms', 'system_to_frame_ms'):
        values = [m[key] for m in measurements if m[key] is not None]
        if values: summary[key] = dict(median=statistics.median(values), worst=max(values))
    (output / 'launch-summary.json').write_text(json.dumps(summary, indent=2))


def metrics(result, output):
    output.mkdir(parents=True, exist_ok=True)
    if not (output / 'manifest.json').exists():
        run('xcrun', 'xcresulttool', 'export', 'metrics', '--path', result, '--output-path', str(output))
    summary = {}
    for file in sorted(output.glob('*.csv')):
        with file.open() as handle:
            rows = list(csv.reader(handle))
        summary[file.name] = rows
    (output / 'measurements.json').write_text(json.dumps(summary, indent=2))
    measured = {}
    for entry in json.loads((output / 'manifest.json').read_text()):
        file = output / entry['metricsFileName']
        # Xcode 27 can append the CSV extension twice in its manifest.
        if not file.exists() and file.suffix == '.csv': file = file.with_suffix('')
        with file.open() as handle: row = next(csv.DictReader(handle))
        values = {}
        for key, text in row.items():
            if key.endswith(' (Iterations)'):
                samples = json.loads(text)
                values[key.removesuffix(' (Iterations)')] = dict(samples=samples,
                    median=statistics.median(samples), worst=max(samples))
        measured[entry['testIdentifier']] = values
    (output / 'summary.json').write_text(json.dumps(measured, indent=2))
    print(json.dumps(measured, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    fixture = sub.add_parser('seed')
    fixture.add_argument('--simulator', required=True)
    fixture.add_argument('--count', type=int, default=180, help='Number of fixture tracks (default: 180).')
    fixture.add_argument('--artwork', action='store_true', help='Embed bundled covers in MP3 fixtures using ffmpeg.')
    trace = sub.add_parser('launch-traces')
    trace.add_argument('--simulator', required=True)
    trace.add_argument('--app', required=True)
    trace.add_argument('--output', type=Path, required=True)
    trace.add_argument('--count', type=int, default=5)
    export = sub.add_parser('metrics')
    export.add_argument('--result', required=True)
    export.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'seed':
        if args.count < 1: parser.error('--count must be positive')
        seed(args.simulator, args.count, args.artwork)
    elif args.command == 'launch-traces': launch_traces(args.simulator, args.app, args.output, args.count)
    else: metrics(args.result, args.output)


if __name__ == '__main__':
    main()
