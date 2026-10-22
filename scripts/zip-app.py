#!/usr/bin/env python3
"""Archive an application with executable permissions and no owner or xattr metadata."""
from pathlib import Path
import stat
import sys
import zipfile

if len(sys.argv) != 3:
    raise SystemExit('Usage: zip-app.py <application> <output.zip>')
app = Path(sys.argv[1]).resolve(strict=True)
output = Path(sys.argv[2])
if not app.is_dir() or app.suffix != '.app' or output.exists():
    raise SystemExit('Choose an app directory and a new output path')
with zipfile.ZipFile(output, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for source in sorted(app.rglob('*')):
        if source.is_symlink():
            raise SystemExit('Symlinks inside the app are not supported')
        if not source.is_file():
            continue
        info = zipfile.ZipInfo(str(source.relative_to(app.parent)), (1980, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.compress_type = zipfile.ZIP_DEFLATED
        mode = 0o755 if source.stat().st_mode & 0o111 else 0o644
        info.external_attr = (stat.S_IFREG | mode) << 16
        archive.writestr(info, source.read_bytes())
print('Created ' + output.name)
