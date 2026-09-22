from pathlib import Path
import base64, lzma, hashlib, subprocess, shutil
root = Path('.github/tailscale-patch')
encoded = ''.join((root / str(i)).read_text().strip() for i in range(1, 6))
assert len(encoded) == 29336, len(encoded)
patch = lzma.decompress(base64.b64decode(encoded, validate=True))
assert hashlib.sha256(patch).hexdigest() == 'a62ef4ee8626fee64825397eb6b6234c1a5d7605b3b73ca1385e271d24f89ab6'
subprocess.run(['git', 'apply', '--check', '-'], input=patch, check=True)
subprocess.run(['git', 'apply', '-'], input=patch, check=True)
subprocess.run(['cargo', 'fmt', '--all'], check=True)
shutil.rmtree(root)
Path(__file__).unlink()
