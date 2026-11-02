#!/usr/bin/env python3
"""Prove five preserved split tips against an independent merge with current main."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

from audit_stack import Audit, INTERMEDIATE, check_stages

ORIGINAL_BASE = '19c79b7e9c47300558ee99bb5c4f756cc220817f'
ORIGINAL_FINAL = '41d8db0d9c09bff20981a9b10839634bd5fa6b36'
FROZEN = [
    'c22517f72156a20bcb3645d166a29be555df63dc',
    'd0c6e11a7a8ed00d6c22fe3d38ce2d62f4bf747a',
    '9d5783eeb3e55aabe3db5b287440325f33b7bed1',
    'ee35e79b3d729f284a86ab20a4dde6ec7fc49797',
    '43d004b3f645fcfa682e5a8843134d9379dfc013',
]
BACKLOG = 'release-media/backlog.json'
CAPTURE_SUPPORT = 'LiloTests/Support/ReleaseMediaCapture.swift'
CAPTURE_TESTS = 'LiloTests/Window/ReleaseMediaCaptureTests.swift'
CAPTURE_REPLACEMENTS = {
    CAPTURE_SUPPORT: [
        ('        let context = fixture.context\n', '        let context = fixture.context\n        let settingsStore = try XCTUnwrap(context.settingsStore)\n', 1),
        ('context.settingsStore.set(', 'settingsStore.set(', 4),
        ('context.settingsStore.didPromptDefaultBrowser', 'settingsStore.didPromptDefaultBrowser', 1),
        ('try context.profileManager.createProfile', 'try XCTUnwrap(context.profileManager).createProfile', 1),
        ('try context.spaceManager.createSpace', 'try XCTUnwrap(context.spaceManager).createSpace', 1),
        ('controller.applyTabLayout(context.settingsStore.tabLayout', 'controller.applyTabLayout(settingsStore.tabLayout', 1),
    ],
    CAPTURE_TESTS: [
        ('        capture.context.settingsStore.set("addressPlacement", value: "page")\n', '        let settingsStore = try XCTUnwrap(capture.context.settingsStore)\n        settingsStore.set("addressPlacement", value: "page")\n', 1),
        ('capture.context.settingsStore.tabLayout.address == .hidden', 'settingsStore.tabLayout.address == .hidden', 1),
    ],
}
FORK = ' $(if $(WEBKIT_FORK_URL),webkit-fork)'
ARCHIVE_TEST_REPLACEMENTS = [
    ('        let capture = try await ReleaseMediaCapture(version: "0.11.0", feature: "spaces")\n        defer { capture.close() }\n', '        let capture = try await ReleaseMediaCapture(version: "0.11.0", feature: "spaces")\n        defer { capture.close() }\n        let spaceManager = try XCTUnwrap(capture.context.spaceManager)\n', 1),
    ('capture.context.spaceManager.space(with:', 'spaceManager.space(with:', 1),
    ('try capture.context.spaceManager.createSpace(', 'try spaceManager.createSpace(', 1),
    ('        let capture = try await ReleaseMediaCapture(version: "0.12.0", feature: "site-colors")\n        defer { capture.close() }\n        capture.context.settingsStore.set(', '        let capture = try await ReleaseMediaCapture(version: "0.12.0", feature: "site-colors")\n        defer { capture.close() }\n        try XCTUnwrap(capture.context.settingsStore).set(', 1),
]


def tree_entries(audit, ref):
    records = audit.git('ls-tree', '-r', '-z', ref).stdout.split(b'\0')
    return {
        path.decode(): tuple(meta.decode().split())
        for record in records if record
        for meta, path in [record.split(b'\t', 1)]
    }


def release_sections(source):
    matches = list(re.finditer(r'^## \[([^\]]+)\][^\n]*\n', source, re.M))
    return {
        match.group(1): source[match.start():matches[index + 1].start() if index + 1 < len(matches) else len(source)]
        for index, match in enumerate(matches)
    }


def resolve_makefile(source):
    pattern = re.compile(r'^<<<<<<< [^\n]+\n(.*?)^=======\n(.*?)^>>>>>>> [^\n]+\n', re.M | re.S)
    resolved = []

    def combine(match):
        original, main = match.group(1, 2)
        if original.startswith('\trun-ui-dev '):
            expected_main = original.replace('vt-zip bootstrap', 'vt-zip webkit-fork bootstrap')
            expected_main = expected_main.replace('site-e2e site-lock', 'site-e2e site-release-capture site-capture-server site-capture-deps site-lock')
            if main != expected_main:
                raise ValueError('Unexpected .PHONY conflict; refusing a broad Makefile exception')
            resolved.append('.PHONY')
            return original.replace('vt-zip bootstrap', 'vt-zip webkit-fork bootstrap')
        for name, dependency in [('release-notarize', 'release-media-publish-check'), ('release-archive', 'release-media-stage')]:
            if original.startswith(name + ':'):
                expected_main = original.replace(dependency + ' ', '').rstrip('\n') + FORK + '\n'
                if main != expected_main:
                    raise ValueError(f'Unexpected {name} conflict; refusing a broad Makefile exception')
                resolved.append(name)
                return original.rstrip('\n') + FORK + '\n'
        raise ValueError('Unrecognized Makefile conflict')

    result = pattern.sub(combine, source)
    if re.search(r'^(?:<<<<<<<|=======|>>>>>>>)', result, re.M):
        raise ValueError('Unresolved Makefile conflict markers')
    return result.encode(), resolved


def adapt_capture(number, path, source):
    replacements = (ARCHIVE_TEST_REPLACEMENTS if number >= 4 and path == CAPTURE_TESTS else []) + CAPTURE_REPLACEMENTS[path]
    for old, new, count in replacements:
        if source.count(old) != count:
            raise ValueError(f'Unexpected optional-access shape in {path}; refusing a broad capture exception')
        source = source.replace(old, new)
    return source.encode()


def validate_catalog(audit, number, tip, expected_bytes, published, new_versions):
    actual = json.loads(audit.source(tip, BACKLOG))
    expected = json.loads(expected_bytes)
    audit.check({key: value for key, value in actual.items() if key != 'releases'} == {key: value for key, value in expected.items() if key != 'releases'}, f'PR{number}: catalog metadata changed outside the integration')
    releases = actual['releases']
    for version, entry in expected['releases'].items():
        audit.check(releases.get(version) == entry, f'PR{number}: original catalog decision changed: {version}')
    audit.check(set(releases) == set(published), f'PR{number}: catalog must cover exactly all {len(published)} published releases; missing {sorted(set(published) - set(releases))}, extra {sorted(set(releases) - set(published))}')
    for version in new_versions:
        entry = releases.get(version, {})
        audit.check(entry.get('kind') == 'none' and isinstance(entry.get('reason'), str) and bool(entry['reason'].strip()), f'PR{number}: new compatibility/performance release needs an explicit nonvisual decision: {version}')
        audit.check(set(entry) <= {'kind', 'reason', 'notesSha256'}, f'PR{number}: unexpected fields in new nonvisual decision: {version}')
        if 'notesSha256' in entry:
            audit.check(entry['notesSha256'] == hashlib.sha256(published[version].encode()).hexdigest(), f'PR{number}: stale release-notes binding: {version}')
    return len(releases)


def run(args):
    audit = Audit(str(Path(args.repo).resolve()))
    main = audit.resolve(args.main)
    base = audit.resolve(ORIGINAL_BASE)
    final = audit.resolve(ORIGINAL_FINAL)
    frozen = [audit.resolve(ref) for ref in FROZEN]
    tips = [audit.resolve(ref) for ref in args.stages]
    if len(tips) > 5 or not tips or (len(tips) != 5 and not args.partial):
        raise ValueError('Supply five tips, or use --partial with the contiguous completed prefix')
    covered, _ = check_stages(audit, main, final, tips)
    original_paths = audit.changed(base, final)
    main_paths = audit.changed(base, main)
    main_only = main_paths - original_paths
    main_entries = tree_entries(audit, main)
    published = release_sections(audit.source(main, 'CHANGELOG.md'))
    old_published = release_sections(audit.source(base, 'CHANGELOG.md'))
    new_versions = set(published) - set(old_published)
    audit.check(new_versions == {'0.14.2', '0.14.3'}, f'Integration release set changed; review the new decisions explicitly: {sorted(new_versions)}')
    stage_reports = []
    new_decisions = None
    with tempfile.TemporaryDirectory(prefix='lilo-integrated-audit-') as folder:
        scratch = str(Path(folder) / 'repo.git')
        result = subprocess.run(['git', 'clone', '--bare', '--shared', '--quiet', audit.repo, scratch], capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stderr.decode().strip())
        oracle = Audit(scratch)
        for number, (tip, original_tip) in enumerate(zip(tips, frozen), 1):
            for ancestor, label in [(main, 'current main'), (original_tip, 'immutable original split tip')]:
                audit.check(audit.git('merge-base', '--is-ancestor', ancestor, tip, okay=True).returncode == 0, f'PR{number}: {label} is not an ancestor')
            result = oracle.git('merge-tree', '--write-tree', original_tip, main, okay=True)
            if result.returncode not in (0, 1):
                raise RuntimeError(result.stderr.decode().strip())
            output = result.stdout.decode()
            expected_tree = output.splitlines()[0]
            conflicts = set(re.findall(r'^CONFLICT .* in (.+)$', output, re.M))
            audit.check(conflicts <= {'Makefile'} and (result.returncode == 0 or conflicts == {'Makefile'}), f'PR{number}: independent merge has unreviewed conflicts: {sorted(conflicts)}')
            expected = tree_entries(oracle, expected_tree)
            make_resolutions = []
            if conflicts == {'Makefile'}:
                expected_make, make_resolutions = resolve_makefile(oracle.source(expected_tree, 'Makefile'))
                actual_make = audit.blob(tip, 'Makefile')
                audit.check(actual_make == expected_make, f'PR{number}: Makefile differs from the independently combined fork/media dependencies')
                if actual_make == expected_make:
                    expected['Makefile'] = (*expected['Makefile'][:2], tree_entries(audit, tip)['Makefile'][2])
            catalog_count = None
            if number >= 3:
                catalog_count = validate_catalog(audit, number, tip, oracle.blob(expected_tree, BACKLOG), published, new_versions)
                decisions = {version: json.loads(audit.source(tip, BACKLOG))['releases'].get(version) for version in new_versions}
                if new_decisions is None:
                    new_decisions = decisions
                else:
                    audit.check(decisions == new_decisions, f'PR{number}: new release decisions changed after their PR3 introduction')
                actual_catalog_entry = tree_entries(audit, tip).get(BACKLOG)
                audit.check(actual_catalog_entry is not None and actual_catalog_entry[:2] == expected[BACKLOG][:2], f'PR{number}: catalog file mode or type changed')
                if actual_catalog_entry is not None:
                    expected[BACKLOG] = actual_catalog_entry
            capture_adaptations = []
            if number >= 3:
                for path in CAPTURE_REPLACEMENTS:
                    expected_capture = adapt_capture(number, path, oracle.source(expected_tree, path))
                    capture_matches = audit.blob(tip, path) == expected_capture
                    audit.check(capture_matches, f'PR{number}: capture compatibility fix differs from exact reviewed XCTUnwrap transformations: {path}')
                    if capture_matches:
                        expected[path] = (*expected[path][:2], tree_entries(audit, tip)[path][2])
                        capture_adaptations.append(path)
            documentation_adaptations = []
            if number >= 4:
                path = 'release-media/README.md'
                expected_readme = oracle.source(expected_tree, path)
                for old, new in [('archive covers 31 releases:', 'archive covers 33 releases:'), ('and seventeen text-only maintenance releases.', 'and nineteen text-only maintenance releases.')]:
                    if expected_readme.count(old) != 1:
                        raise ValueError('Unexpected archive-count wording; refusing a broad documentation exception')
                    expected_readme = expected_readme.replace(old, new)
                readme_matches = audit.blob(tip, path) == expected_readme.encode()
                audit.check(readme_matches, f'PR{number}: archive documentation differs beyond the exact 31-to-33 release and seventeen-to-nineteen nonvisual count updates')
                if readme_matches:
                    expected[path] = (*expected[path][:2], tree_entries(audit, tip)[path][2])
                    documentation_adaptations.append(path)
            actual = tree_entries(audit, tip)
            unexpected = sorted(path for path in set(expected) | set(actual) if expected.get(path) != actual.get(path))
            audit.check(not unexpected, f'PR{number}: files differ from the independent original-tip/main merge outside reviewed Makefile/catalog adaptations: {unexpected}')
            changed_main_only = sorted(path for path in main_only if actual.get(path) != main_entries.get(path))
            audit.check(not changed_main_only, f'PR{number}: changed main-only paths were lost or modified: {changed_main_only}')
            stage_reports.append({'stage': number, 'tip': tip, 'frozen_tip': original_tip, 'independent_merge_tree': expected_tree, 'actual_tree': audit.git('rev-parse', f'{tip}^{{tree}}').stdout.decode().strip(), 'make_conflict_resolutions': make_resolutions, 'capture_optional_access_adaptations': capture_adaptations, 'documentation_count_adaptations': documentation_adaptations, 'catalog_decisions': catalog_count, 'unexpected_paths': unexpected, 'main_only_preservation_failures': changed_main_only})
    if len(tips) == 5:
        audit.check(original_paths <= covered, f'Original changed paths missing from integrated stack: {sorted(original_paths - covered)}')
        audit.check(covered - original_paths == INTERMEDIATE, f'Integrated stack has unrelated changed paths: {sorted(covered - original_paths)}')
        for path in INTERMEDIATE:
            audit.check(audit.blob(tips[-1], path) == audit.blob(main, path), f'Temporary config was not restored to current-main bytes: {path}')
    report = {'passed': not audit.failures, 'complete_stack': len(tips) == 5, 'checks': audit.checks, 'original_base': base, 'original_final': final, 'current_main': main, 'original_changed_paths': len(original_paths), 'new_main_changed_paths': len(main_paths), 'main_only_changed_paths_preserved_per_stage': len(main_only), 'overlapping_changed_paths': len(original_paths & main_paths), 'covered_paths': len(covered), 'published_releases': len(published), 'new_nonvisual_releases': sorted(new_versions), 'stages': stage_reports, 'failures': audit.failures}
    print(json.dumps(report, indent=2))
    return 1 if audit.failures else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--main', required=True)
    parser.add_argument('--partial', action='store_true', help='Check a contiguous completed prefix without claiming the complete stack passes')
    parser.add_argument('stages', nargs='+', help='New immutable tips or branch refs in PR order')
    try:
        raise SystemExit(run(parser.parse_args()))
    except (RuntimeError, KeyError, ValueError) as error:
        parser.exit(2, f'Audit error: {error}\n')
