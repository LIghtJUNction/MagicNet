from pathlib import Path
import hashlib
root=Path('.')
p=root/'scripts/fake-magisk-smoke.sh'
raw=p.read_bytes()
assert hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()=='abd591500ae35c2861c6be2f87ea6387a1ca3ca5'
s=raw.decode()
s=s.replace('HOST_ENV="$(command -v env)"', 'HOST_ENV="$(command -v env)"\nMAGICNET_FAKE_PYTHON="$(command -v python3)"\nexport MAGICNET_FAKE_PYTHON\nexport MAGICNET_FAKE_KERNEL="$ROOT/scripts/fake-magisk-kernel.py"\ntest -f "$MAGICNET_FAKE_KERNEL"')
s=s.replace('kill ln ls mkdir mkfifo mv nohup printf ps pwd readlink realpath rm sed sh sleep sort', 'kill ln ls mkdir mkfifo mktemp stat cmp mv nohup printf ps pwd readlink realpath rm sed sh sleep sort')
start=s.index("write_mock ip '\n")
end=s.index('\ncp "$MOCK_BIN/iptables"',start)
s=s[:start]+'''write_mock ip '
exec "$MAGICNET_FAKE_PYTHON" -I "$MAGICNET_FAKE_KERNEL" ip "$@"
'

# Each read observes the same private fixture state as the preceding mutation.
# No host route/firewall command is ever invoked by this smoke-model boundary.
# shellcheck disable=SC2016
write_mock iptables '
exec "$MAGICNET_FAKE_PYTHON" -I "$MAGICNET_FAKE_KERNEL" "${0##*/}" "$@"
'
'''.rstrip()+s[end:]
s=s.replace('printf "%s" "sing-box" >/proc/$$/comm 2>/dev/null || true\n        while :;', 'printf "%s" "sing-box" >/proc/$$/comm 2>/dev/null || true\n        "$MAGICNET_FAKE_PYTHON" -I "$MAGICNET_FAKE_KERNEL" core-start "$$" "${3:?}" || exit 1\n        while :;')
marker='install_runtime_path_fixtures\n\n"$HOST_JQ"'
assert marker in s
s=s.replace(marker,'''install_runtime_path_fixtures

# Replace only the external /sys fact inside this extracted host fixture. The
# real lifecycle/ownership algorithms and their return values remain untouched.
cat >>"$MODDIR/lib/magicnet/network.sh" <<'SH'

magicnet_iface_exists() {
    magicnet_iface_name_valid "$1" && ip link show dev "$1" >/dev/null 2>&1
}
SH

"$HOST_JQ"''',1)
old='''    rg -q '^iptables -t nat -D OUTPUT -j magicnet-dns-output$' "$log_file"
    rg -q '^iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT$' "$log_file"'''
assert old in s
s=s.replace(old,'''    if rg -q '^iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT$' "$log_file"; then
        echo "cleanup attempted to remove a foreign DNS reject" >&2
        return 1
    fi
    MAGICNET_FAKE_LOG="$log_file" "$MAGICNET_FAKE_PYTHON" -I "$MAGICNET_FAKE_KERNEL" assert-clean''')
old='''capture = next((i for i, line in enumerate(lines) if line == "iptables -t nat -D OUTPUT -j magicnet-dns-output"), None)
guard = next((i for i, line in enumerate(lines) if line == "iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT"), None)
run = next((i for i, line in enumerate(lines) if line.startswith("sing-box run")), None)
if capture is None or guard is None or run is None or capture > run or guard > run:
    raise SystemExit("kernel bootstrap did not clear DNS interception before starting sing-box")'''
assert old in s
s=s.replace(old,'''capture = next((i for i, line in enumerate(lines) if line.startswith("iptables -t nat -L")), None)
guard = next((i for i, line in enumerate(lines) if line == "iptables -S OUTPUT"), None)
run = next((i for i, line in enumerate(lines) if line.startswith("sing-box run")), None)
if capture is None or guard is None or run is None or capture > run or guard > run:
    raise SystemExit("kernel bootstrap did not inspect existing DNS ownership before starting sing-box")
if "iptables -D OUTPUT -o lo -p udp --dport 53 -j REJECT" in lines:
    raise SystemExit("kernel bootstrap attempted to remove a foreign DNS reject")''')
raw=s.encode()
assert hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()=='cf8da74e1b3e98b0c8fdc65d8affaf7a62a29343'
p.write_bytes(raw)
for name,digest in [('fake-magisk-kernel.py','7d741f55149ef18ad7990025aab5142dac0ad2ee'),('test-fake-magisk-kernel.py','000a24e65311eceb82536015a633bad2ef480bd8')]:
    raw=(root/'.github/fixture-candidate'/name).read_bytes()
    assert hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()==digest
    dest=root/'scripts'/name
    assert not dest.exists()
    dest.write_bytes(raw)
print('Verified exact old/new fixture source hashes; no production source modified')
