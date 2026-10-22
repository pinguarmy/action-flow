#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Set CLI_BIN to a previously built binary to avoid any SwiftPM activity.
if [[ -z "${CLI_BIN:-}" ]]; then
  swift build --package-path "$ROOT" --product actionflow-cli
  BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
  CLI_BIN="$BIN/actionflow-cli"
fi
[[ -x "$CLI_BIN" ]] || { printf 'CLI binary is not executable: %s\n' "$CLI_BIN" >&2; exit 1; }
export CLI_BIN
python3 - <<'PY'
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

binary = str(Path(os.environ['CLI_BIN']).resolve(strict=True))
assertions = 0

def check(value, label):
    global assertions
    if not value:
        raise AssertionError(label)
    assertions += 1
    print('PASS ' + label)

def invoke(*args, code=0):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True, timeout=20)
    check(result.returncode == code, 'exit ' + str(code) + ' for ' + ' '.join(map(str, args[:1])))
    if code:
        check(result.stdout == '' and isinstance(json.loads(result.stderr).get('error'), str), 'failure is JSON on stderr only')
    return result

with tempfile.TemporaryDirectory(prefix='actionflow-cli-checks-') as temporary:
    root = Path(temporary).resolve()
    # Only this freshly allocated fixture directory is cleaned up by the context.
    assert root.is_absolute() and root.name.startswith('actionflow-cli-checks-')
    fixture = root / 'example.json'
    check('never executes' in invoke('help').stdout, 'help discloses offline behavior')
    check('Usage:' in invoke('--help').stdout, 'help alias')
    invoke(code=2)
    invoke('unknown', code=2)
    invoke('validate', code=2)
    invoke('example', fixture, 'extra', code=2)
    created = json.loads(invoke('example', fixture).stdout)
    check(created['created'] and created['rulesDisabled'], 'example reports safe creation')
    config = json.loads(fixture.read_text())
    check(not config['automationEnabled'] and not config['allowScripts'] and not config['launchAtLogin'], 'all example execution opt-ins disabled')
    check(all(not rule['enabled'] for rule in config['rules']), 'every example rule disabled')
    check(stat.S_IMODE(fixture.stat().st_mode) == 0o600, 'example is private mode 0600')
    digest = hashlib.sha256(fixture.read_bytes()).hexdigest()
    validation = json.loads(invoke('validate', fixture).stdout)
    check(validation == {'valid': True, 'ruleCount': 2, 'schemaVersion': 1}, 'validation returns expected schema and count')
    check(hashlib.sha256(fixture.read_bytes()).hexdigest() == digest, 'validate leaves bytes unchanged')
    summary1 = invoke('summarize', fixture).stdout
    summary2 = invoke('summarize', fixture).stdout
    check(summary1 == summary2, 'summary output deterministic')
    summary = json.loads(summary1)
    check(summary['counts']['enabledRules'] == 0 and summary['counts']['actionsByKind']['window'] == 2, 'summary counts disabled rules and window actions')
    check(hashlib.sha256(fixture.read_bytes()).hexdigest() == digest, 'summarize leaves bytes unchanged')
    invoke('example', fixture, code=1)
    check(hashlib.sha256(fixture.read_bytes()).hexdigest() == digest, 'example never overwrites existing bytes')
    second = root / 'second.json'
    invoke('example', second)
    check(second.read_bytes() == fixture.read_bytes(), 'example fixtures are reproducible')
    symlink = root / 'existing-link.json'
    symlink.symlink_to(fixture)
    invoke('example', symlink, code=1)
    check(symlink.is_symlink() and hashlib.sha256(fixture.read_bytes()).hexdigest() == digest, 'example does not replace symlink or its target')
    dangling = root / 'dangling.json'
    dangling.symlink_to(root / 'does-not-exist.json')
    invoke('example', dangling, code=1)
    check(dangling.is_symlink() and not (root / 'does-not-exist.json').exists(), 'example refuses dangling symlink')
    missing = root / 'missing.json'
    invoke('validate', missing, code=1)
    invoke('summarize', missing, code=1)
    check(not missing.exists(), 'inspection never creates missing files')
    corrupt = root / 'corrupt.json'
    corrupt.write_text('{bad json')
    invoke('validate', corrupt, code=1)
    check(corrupt.read_text() == '{bad json', 'invalid JSON not modified')
    future = root / 'future.json'
    future.write_text(json.dumps({'schemaVersion': 999, 'rules': []}))
    invoke('validate', future, code=1)
    oversized = root / 'oversized.json'
    with oversized.open('wb') as handle:
        handle.truncate(8 * 1024 * 1024 + 1)
    invoke('validate', oversized, code=1)
    invoke('summarize', root, code=1)
    sensitive = root / 'sensitive.json'
    secret = 'ACTIONFLOW_MUST_NOT_PRINT_SCRIPT_OR_TEXT'
    fixture_config = json.loads(fixture.read_text())
    # A disabled script is inspectable, never executed, even if allowScripts=true.
    script = dict(fixture_config['rules'][0]['actions'][0])
    script.update(kind='shellScript', text=secret + '; touch ' + str(root / 'MUST_NOT_EXIST'))
    fixture_config['rules'][0]['actions'] = [script]
    fixture_config['allowScripts'] = True
    sensitive.write_text(json.dumps(fixture_config))
    sensitive_summary = invoke('summarize', sensitive).stdout
    check(secret not in sensitive_summary and 'MUST_NOT_EXIST' not in sensitive_summary, 'summary omits script contents')
    check(json.loads(sensitive_summary)['counts']['actionsByKind']['shellScript'] == 1, 'summary counts scripts without evaluating them')
    check(not (root / 'MUST_NOT_EXIST').exists(), 'summary does not execute script')
    check(all(set(rule) == {'id', 'name', 'trigger', 'actionCount'} for rule in json.loads(sensitive_summary)['rules']), 'rule summary exposes metadata only')
    check('plan <path>' in invoke('help').stdout, 'help documents offline plan command')
    invoke('plan', code=2)
    invoke('plan', missing, code=1)
    invoke('plan', corrupt, code=1)
    invoke('plan', future, code=1)
    plan1 = invoke('plan', fixture).stdout
    plan2 = invoke('plan', fixture).stdout
    check(plan1 == plan2, 'plan output is deterministic')
    default_plan = json.loads(plan1)
    check(default_plan['schemaVersion'] == 1 and len(default_plan['rules']) == 2, 'plan includes schema and every disabled example rule')
    check(all(set(rule) == {'id', 'plan'} for rule in default_plan['rules']), 'plan omits rule names and trigger values')
    check(all(not rule['plan']['validationErrors'] for rule in default_plan['rules']), 'safe example plans have no validation errors')
    check(hashlib.sha256(fixture.read_bytes()).hexdigest() == digest, 'plan leaves source bytes unchanged')
    plan_fixture = root / 'plan-sensitive.json'
    plan_config = json.loads(fixture.read_text())
    rule = plan_config['rules'][0]
    rule['name'] = 'PERSONAL_RULE_NAME_' + secret
    def action(number, kind, text='', **changes):
        value = dict(rule['actions'][0])
        value.update(id=f'30000000-0000-4000-8000-{number:012d}', kind=kind, text=text)
        value.update(changes)
        return value
    rule['actions'] = [
        action(1, 'shellScript', secret + '; touch ' + str(root / 'MUST_NOT_EXIST')),
        action(2, 'insertText', 'PRIVATE_INSERT_' + secret),
        action(3, 'openURL', 'https://example.invalid/private/' + secret),
        action(4, 'launchApp', 'test.private.' + secret.replace('_', '')),
        action(5, 'notification', 'PRIVATE_NOTIFICATION_' + secret),
        action(6, 'delay', delaySeconds=0.25),
    ]
    plan_config['allowScripts'] = True
    plan_fixture.write_text(json.dumps(plan_config))
    plan_digest = hashlib.sha256(plan_fixture.read_bytes()).hexdigest()
    redacted = invoke('plan', plan_fixture).stdout
    check(secret not in redacted and 'MUST_NOT_EXIST' not in redacted and 'PERSONAL_RULE_NAME' not in redacted,
          'plan redacts script, text, URL, app identifier, notification, and rule name')
    detailed = json.loads(redacted)['rules'][0]['plan']
    check([step['kind'] for step in detailed['steps']] == ['shellScript', 'insertText', 'openURL', 'launchApp', 'notification', 'delay'], 'plan preserves ordered action kinds')
    check(detailed['totalDelaySeconds'] == 0.25, 'plan reports bounded total delay')
    check(set(detailed['requiredCapabilities']) == {'inputMonitoring', 'accessibility', 'notifications', 'scripts'}, 'plan reports required capabilities without requesting them')
    check(not detailed['validationErrors'], 'disabled valid payloads still produce valid plan')
    check(not (root / 'MUST_NOT_EXIST').exists(), 'plan never executes opted-in script')
    check(hashlib.sha256(plan_fixture.read_bytes()).hexdigest() == plan_digest, 'sensitive plan does not modify source')
    # Disabled drafts remain inspectable even when a later action is invalid.
    rule['actions'].append(action(7, 'delay', delaySeconds=61))
    plan_fixture.write_text(json.dumps(plan_config))
    invalid_digest = hashlib.sha256(plan_fixture.read_bytes()).hexdigest()
    invalid_plan = invoke('plan', plan_fixture).stdout
    invalid_details = json.loads(invalid_plan)['rules'][0]['plan']
    check(bool(invalid_details['validationErrors']) and len(invalid_details['steps']) == 7, 'plan reports invalid later action without rejecting disabled draft')
    check(secret not in invalid_plan and 'PERSONAL_RULE_NAME' not in invalid_plan, 'invalid plan errors remain redacted')
    check(hashlib.sha256(plan_fixture.read_bytes()).hexdigest() == invalid_digest and not (root / 'MUST_NOT_EXIST').exists(), 'invalid later action causes no writes or execution')
    check('template <id> <new-path>' in invoke('help').stdout, 'help documents template export command')
    template_output = invoke('templates').stdout
    check(template_output == invoke('templates').stdout, 'template catalog output is deterministic')
    catalog = json.loads(template_output)
    ids = [item['id'] for item in catalog]
    check(len(catalog) >= 6 and len(ids) == len(set(ids)), 'template catalog contains at least six unique packs')
    check(all(item['name'] and item['detail'] and item['ruleCount'] > 0 for item in catalog), 'template catalog has descriptive metadata')
    check(all(set(item) == {'id', 'name', 'detail', 'ruleCount', 'capabilities'} for item in catalog), 'template list only exposes fixed metadata')
    check(all('scripts' not in item['capabilities'] for item in catalog), 'template catalog requires no script capability')
    invoke('templates', 'extra', code=2)
    invoke('template', code=2)
    invoke('template', ids[0], code=2)
    unknown_output = root / 'unknown-template.json'
    invoke('template', 'not-a-template', unknown_output, code=1)
    check(not unknown_output.exists(), 'unknown template does not create output')
    exported = []
    for item in catalog:
        first = root / ('template-' + item['id'] + '.json')
        second_template = root / ('template-' + item['id'] + '-copy.json')
        invoke('template', item['id'], first)
        invoke('template', item['id'], second_template)
        check(first.read_bytes() == second_template.read_bytes(), 'template bytes reproducible for ' + item['id'])
        cfg = json.loads(first.read_text())
        check(all(not cfg[key] for key in ['automationEnabled', 'allowScripts', 'launchAtLogin']), 'template opts out of execution for ' + item['id'])
        check(all(not rule['enabled'] for rule in cfg['rules']), 'template rules disabled for ' + item['id'])
        check(all(action['kind'] != 'shellScript' for rule in cfg['rules'] for action in rule['actions']), 'template has no scripts for ' + item['id'])
        check(len(cfg['rules']) == item['ruleCount'] and stat.S_IMODE(first.stat().st_mode) == 0o600, 'template count and private mode for ' + item['id'])
        check(json.loads(invoke('validate', first).stdout)['valid'], 'exported template validates for ' + item['id'])
        template_plan = json.loads(invoke('plan', first).stdout)
        check(all(not rule['plan']['validationErrors'] for rule in template_plan['rules']), 'template plan has no errors for ' + item['id'])
        exported.append(first)
    kept = exported[0].read_bytes()
    invoke('template', ids[0], exported[0], code=1)
    check(exported[0].read_bytes() == kept, 'template export never overwrites existing bytes')
    template_link = root / 'template-link.json'
    template_link.symlink_to(exported[0])
    invoke('template', ids[0], template_link, code=1)
    check(template_link.is_symlink() and exported[0].read_bytes() == kept, 'template export refuses symlink destination')
    invoke('template', ids[0], root / 'absent-parent' / 'template.json', code=1)
    check(not (root / 'absent-parent').exists(), 'template export does not create missing parent directories')
    real_parent = root / 'real-parent'
    real_parent.mkdir()
    linked_parent = root / 'linked-parent'
    linked_parent.symlink_to(real_parent, target_is_directory=True)
    invoke('template', ids[0], linked_parent / 'template.json', code=1)
    check(not (real_parent / 'template.json').exists(), 'template export refuses symlink parent directory')
    raced = root / 'raced.json'
    def race(_):
        return subprocess.run([binary, 'example', str(raced)], capture_output=True, text=True, timeout=20).returncode
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        codes = list(pool.map(race, range(4)))
    check(sorted(codes) == [0, 1, 1, 1], 'concurrent example creation has exactly one winner')
    check(raced.read_bytes() == fixture.read_bytes() and stat.S_IMODE(raced.stat().st_mode) == 0o600, 'racing creation leaves complete private JSON')
    check(not list(root.glob('.actionflow-cli-*')), 'private staging files are cleaned up')
    check(not list(root.glob('*.backup')), 'read-only inspection produces no backups')
print(f'Verified {assertions} offline CLI assertions. No desktop input, permissions, app launches, or live configuration access.')
PY
