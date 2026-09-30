#!/usr/bin/env python3
"""Require successful Android acceptance for the exact main release commit."""
import json
import os
import re
import subprocess
import time


def api(path):
    result = subprocess.run(['gh', 'api', path], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Unable to read Android acceptance from GitHub')
    return json.loads(result.stdout)


def inspect_runs(runs, sha, repository):
    matching = [run for run in runs
                if run.get('head_sha') == sha and run.get('head_branch') == 'main'
                and run.get('event') == 'push'
                and run.get('head_repository', {}).get('full_name') == repository]
    if not matching:
        return None
    run = max(matching, key=lambda item: item['id'])
    if run.get('status') != 'completed':
        return None
    if run.get('conclusion') != 'success':
        raise RuntimeError('Android acceptance failed for the release commit')
    return run['id']


def verify_jobs(jobs):
    required = {'Simulation harness contracts', 'Android 15 / KernelSU / x86_64',
                'Android Simulation Gate'}
    found = set()
    for job in jobs:
        if job.get('name') in required:
            if job.get('status') != 'completed' or job.get('conclusion') != 'success':
                raise RuntimeError('A required Android acceptance job did not succeed')
            found.add(job['name'])
    if found != required:
        raise RuntimeError('Required Android acceptance jobs are missing')


def require_acceptance(repository, sha, *, timeout=5100, query=api,
                       clock=time.monotonic, sleep=time.sleep):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository identity')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Invalid release commit')
    deadline = clock() + timeout
    path = (f'repos/{repository}/actions/workflows/android-kernelsu-acceptance.yml/runs'
            f'?head_sha={sha}&branch=main&event=push&per_page=100')
    while clock() < deadline:
        run_id = inspect_runs(query(path)['workflow_runs'], sha, repository)
        if run_id is not None:
            verify_jobs(query(f'repos/{repository}/actions/runs/{run_id}/jobs?per_page=100')['jobs'])
            print(f'Android acceptance succeeded for {sha}: run {run_id}', flush=True)
            return run_id
        print('Waiting for Android acceptance of the release commit', flush=True)
        sleep(min(30, max(0, deadline - clock())))
    raise RuntimeError('Android acceptance did not complete before the release deadline')


if __name__ == '__main__':
    try:
        require_acceptance(os.environ['GITHUB_REPOSITORY'], os.environ['RELEASE_COMMIT_SHA'])
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f'::error::{error}') from error
