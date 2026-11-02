#!/usr/bin/env python3
"""Audit five PR tips against explicit immutable base and final references."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

PIP = {
    'Lilo/Engine/MediaControl.swift',
    'LiloTests/PictureInPicture/DocumentPiPControllerTests.swift',
    '.changes/unreleased/Fixed-20261101-134845.757200.yaml',
}
INTERMEDIATE = {'site/playwright.changelog.config.ts'}
APPROVED = [f'release-media/assets/0.8.0/tab-share.{ext}' for ext in ('mp4', 'png')]
LEGACY = [
    'lilo-ui/src/components/whatsnew/WhatsNewArt.svelte',
    'site/src/components/ReleaseRecording.astro',
    'site/src/assets/releases/0.7.0/capture.json',
    'site/src/assets/releases/0.7.0/peek-native.png',
    'site/src/assets/releases/0.7.0/peek-native.webp',
]
AUTHOR = re.compile(r'^release-media/(?:author|check|fixtures|import|inspect|pipeline|png-cutouts|render)(?:\.test)?\.mjs$|^release-media/(?:hyperframes|public/native)/|^release-media/package(?:-lock)?\.json$|^LiloTests/(?:Support/ReleaseMediaCapture|Window/ReleaseMediaCaptureTests)\.swift$')
HISTORICAL = re.compile(r'^release-media/(?:assets|public/native)/(?!0\.8\.0(?:/|$))|^release-media/hyperframes/archive/(?!0\.8\.0(?:/|$))(?:\d+\.)')


class Audit:
    def __init__(self, repo):
        self.repo = repo
        self.failures = []
        self.checks = 0
        self.cache = {}

    def git(self, *args, okay=False):
        result = subprocess.run(['git', '-C', self.repo, *args], capture_output=True)
        if result.returncode and not okay:
            raise RuntimeError(result.stderr.decode().strip())
        return result

    def resolve(self, ref):
        return self.git('rev-parse', '--verify', f'{ref}^{{commit}}').stdout.decode().strip()

    def files(self, ref):
        return set(self.git('ls-tree', '-r', '--name-only', '-z', ref).stdout.decode().split('\0')) - {''}

    def changed(self, left, right):
        return set(self.git('diff', '--no-renames', '--name-only', '-z', left, right).stdout.decode().split('\0')) - {''}

    def blob(self, ref, path):
        key = (ref, path)
        if key not in self.cache:
            result = self.git('show', f'{ref}:{path}', okay=True)
            self.cache[key] = result.stdout if result.returncode == 0 else None
        return self.cache[key]

    def source(self, ref, path):
        return (self.blob(ref, path) or b'').decode()

    def check(self, condition, message):
        self.checks += 1
        if not condition:
            self.failures.append(message)

    def matches(self, ref, path, expected, label):
        data = self.blob(ref, path)
        self.check(data is not None and hashlib.sha256(data).hexdigest() == expected, f'{label}: hash mismatch or missing {path}')

    def receipts(self, ref, label):
        paths = self.files(ref)
        renders = sorted(p for p in paths if re.fullmatch(r'release-media/assets/[^/]+/render\.json', p))
        for path in renders:
            render_bytes = self.blob(ref, path)
            render = json.loads(render_bytes)
            folder = path.rsplit('/', 1)[0]
            for name, digest in render['hashes'].items():
                self.matches(ref, f'{folder}/{name}', digest, label)
            for name, digest in render['recipeHashes'].items():
                self.matches(ref, f'release-media/{name}', digest, label)
            for receipt in render['nativeReceipts']:
                native_path = f"release-media/{receipt['path']}"
                self.matches(ref, native_path, receipt['sha256'], label)
                native_bytes = self.blob(ref, native_path)
                if native_bytes is None:
                    continue
                native = json.loads(native_bytes)
                for asset in native['assets']:
                    self.matches(ref, native_path.rsplit('/', 1)[0] + '/' + asset['file'], asset['sha256'], label)
            quality_path = folder + '/quality.json'
            quality_bytes = self.blob(ref, quality_path)
            self.check(quality_bytes is not None, f'{label}: missing {quality_path}')
            if quality_bytes is None:
                continue
            quality = json.loads(quality_bytes)
            for key in ('passed', 'sourceHashes', 'renderHashes', 'cutoutsVerified', 'strictCompositionCheck'):
                self.check(quality.get(key) is True, f'{label}: {quality_path} lacks {key}')
            self.check(quality.get('renderSha256') == hashlib.sha256(render_bytes).hexdigest(), f'{label}: stale quality receipt for {path}')
        return len(renders)


def target(source, name):
    lines = source.splitlines()
    for index, line in enumerate(lines):
        if line.startswith(name + ':'):
            result = [line]
            for following in lines[index + 1:]:
                if following and not following.startswith('\t'):
                    break
                result.append(following)
            return '\n'.join(result).rstrip()
    return ''


def check_stages(audit, base, final, tips):
    covered = set()
    previous = base
    stage_paths = []
    for number, tip in enumerate(tips, 1):
        label = f'PR{number}'
        ancestor = audit.git('merge-base', '--is-ancestor', previous, tip, okay=True).returncode == 0
        audit.check(ancestor, f'{label}: its previous stage is not an ancestor')
        changes = audit.changed(previous, tip)
        audit.check(bool(changes), f'{label}: empty diff against its previous stage')
        covered.update(changes)
        paths = audit.files(tip)
        stage_paths.append(paths)
        if number == 1:
            audit.check(changes == PIP, f'{label}: PiP diff must contain exactly the fix, test and release fragment; got {sorted(changes)}')
        if number >= 2:
            for path in APPROVED:
                audit.check(audit.blob(tip, path) == audit.blob(final, path) is not None, f'{label}: approved 0.8.0 binary changed or absent: {path}')
            staging = audit.source(tip, 'release-media/stage-native.mjs')
            audit.check(bool(re.search(r'entry\s*&&\s*entry\.kind', staging)), f'{label}: staging lacks missing-catalog-entry guard')
            for name in ('ui-build', 'release-archive'):
                audit.check('release-media-stage' in target(audit.source(tip, 'Makefile'), name), f'{label}: {name} does not stage native media')
        if number < 3:
            forbidden = sorted(p for p in paths if AUTHOR.search(p))
            audit.check(not forbidden, f'{label}: authoring files arrived early: {forbidden}')
            make = audit.source(tip, 'Makefile')
            audit.check(not re.search(r'^release-media-(?:capture|author|render|check|ci|import):', make, re.M), f'{label}: authoring Make targets arrived early')
        if number < 4:
            for path in LEGACY:
                audit.check(audit.blob(tip, path) == audit.blob(base, path) is not None, f'{label}: legacy artwork/recording was removed or changed early: {path}')
            historical = sorted(p for p in paths if HISTORICAL.search(p))
            audit.check(not historical, f'{label}: historical media arrived early: {historical}')
            if number >= 2:
                catalog = json.loads(audit.source(tip, 'release-media/backlog.json'))
                visual = [v for v, entry in catalog['releases'].items() if entry['kind'] != 'none']
                audit.check(visual == ['0.8.0'], f'{label}: minimal catalog has unexpected visual releases: {visual}')
                story = audit.source(tip, 'site/src/lib/release-stories.ts')
                audit.check('capture:' in story, f'{label}: legacy strict story parser no longer accepts retained capture metadata')
                notes = audit.source(tip, 'lilo-ui/src/components/whatsnew/releaseNotes.ts')
                sheet = audit.source(tip, 'lilo-ui/src/components/whatsnew/WhatsNewSheet.svelte')
                audit.check('illustration:' in notes and 'WhatsNewArt' in sheet, f'{label}: native legacy art types or fallback disappeared early')
        if number < 5:
            for path in ('.github/workflows/release.yml', 'scripts/release.py', 'scripts/release_test.py', 'docs/RELEASING.md'):
                audit.check(audit.blob(tip, path) == audit.blob(base, path), f'{label}: mandatory release integration changed early: {path}')
            make = audit.source(tip, 'Makefile')
            audit.check('release-media' not in target(make, 'release-version'), f'{label}: release-version mandates media early')
            audit.check('release-media' not in target(make, 'release-notarize'), f'{label}: release-notarize mandates media early')
            audit.check(not target(make, 'release-media-ci') and not target(make, 'site-deploy-verified'), f'{label}: mandatory capture/deploy target arrived early')
            deploy = json.loads(audit.source(tip, 'site/package.json'))['scripts']['deploy']
            old_deploy = json.loads(audit.source(base, 'site/package.json'))['scripts']['deploy']
            audit.check(deploy == old_deploy, f'{label}: site deploy has an early publication gate')
            workflow = audit.source(tip, '.github/workflows/build.yml')
            audit.check(not re.search(r'^  release-media:', workflow, re.M) and 'make release-media-author' not in workflow, f'{label}: media CI job or global publication check arrived early')
        if number in (3, 4, 5):
            count = audit.receipts(tip, label)
            audit.check(count == (1 if number == 3 else 14), f'{label}: expected {1 if number == 3 else 14} media receipts, found {count}')
        previous = tip
    return covered, stage_paths


def run(args):
    audit = Audit(args.repo)
    base, final = audit.resolve(args.base), audit.resolve(args.final)
    tips = [audit.resolve(ref) for ref in args.stages]
    original = audit.changed(base, final)
    covered, stage_paths = check_stages(audit, base, final, tips)
    audit.check(original <= covered, f'Original changed paths missing from stack: {sorted(original - covered)}')
    audit.check(covered - original == INTERMEDIATE, f'Stack has unexpected intermediate-only paths: {sorted(covered - original)}')
    for path in INTERMEDIATE:
        original_config = audit.blob(base, path)
        audit.check(original_config is not None and audit.blob(final, path) == original_config, f'Intermediate-only config differs between original base and verified final: {path}')
        audit.check(audit.blob(tips[-1], path) == original_config, f'Intermediate-only config was not restored to base: {path}')
        expected_config = original_config.replace(b'testMatch: \"changelog.spec.ts\",', b'testMatch: [\"changelog.spec.ts\", \"release-media.spec.ts\"],') if original_config is not None else None
        for number, tip in enumerate(tips, 1):
            audit.check(audit.blob(tip, path) == (expected_config if number in (2, 3) else original_config), f'PR{number}: intermediate-only config has unexpected contents: {path}')
    final_tree = audit.git('rev-parse', f'{final}^{{tree}}').stdout.decode().strip()
    actual_tree = audit.git('rev-parse', f'{tips[-1]}^{{tree}}').stdout.decode().strip()
    audit.check(actual_tree == final_tree, f'Final tree differs from verified source: expected {final_tree}, got {actual_tree}')
    print(json.dumps({'passed': not audit.failures, 'checks': audit.checks, 'base': base, 'final': final, 'stages': tips, 'changed_paths': len(original), 'covered_paths': len(covered), 'final_tree': actual_tree, 'failures': audit.failures}, indent=2))
    return 1 if audit.failures else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--base', required=True)
    parser.add_argument('--final', required=True)
    parser.add_argument('stages', nargs=5, help='Five branch refs or immutable tips in merge order')
    try:
        raise SystemExit(run(parser.parse_args()))
    except (RuntimeError, KeyError, ValueError) as error:
        parser.exit(2, f'Audit error: {error}\n')
