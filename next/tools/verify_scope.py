"""Validate the migration ledger without converting missing evidence to PASS."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPECTED = {344,337,336,335,334,331,330,329,328,327,326,324,309,305,304,303,281,273,272,261,260,254,253,199,191,190,174,173,168,148,141,139,137,135,133,123,121,119,118,115,113,112,109,101,100,99,97,93,92,91,90,89,88,87,83,82,81,75,73,71,69,64,62,60,57,55,52,51,49,46,44,40,37,36,34,29,27,26,24,20,19,15,14,13,11,10,9,8,6,5,4,3,2,1}


def validate(require_cutover=False):
    ledger = json.loads((ROOT / 'docs/issues.json').read_text())
    gates = json.loads((ROOT / 'docs/cutover.json').read_text())
    numbers = [item['number'] for item in ledger['issues']]
    if ledger['schema'] != 1 or set(numbers) != EXPECTED or len(numbers) != len(set(numbers)):
        raise ValueError('Issue coverage is missing, duplicated, or has an invalid schema')
    if not all(item.get('requirement') and item.get('area') for item in ledger['issues']):
        raise ValueError('An issue lacks an explicit migration requirement')
    if gates['schema'] != 1 or not gates['checks']:
        raise ValueError('Cutover requirements are missing')
    if len({item['id'] for item in gates['checks']}) != len(gates['checks']):
        raise ValueError('Cutover requirement IDs are duplicated')
    incomplete = [item['id'] for item in gates['checks'] if item.get('accepted') is not True or not item.get('evidence')]
    if gates['production_cutover'] and incomplete:
        raise ValueError('Production cutover claims acceptance without evidence')
    if require_cutover and (not gates['production_cutover'] or incomplete):
        raise ValueError('Production cutover remains blocked: ' + ', '.join(incomplete))
    return {'schema': 1, 'ledger_valid': True, 'issues': len(numbers), 'stage': gates['stage'], 'production_ready': gates['production_cutover'] and not incomplete, 'incomplete': incomplete}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--require-cutover', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(validate(args.require_cutover), indent=2))
    except (ValueError, KeyError, TypeError) as error:
        parser.exit(1, str(error) + '\n')
