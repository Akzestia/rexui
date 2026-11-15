# Copyright (c) 2026-present アクゼスティア
# SPDX-License-Identifier: MIT
import fnmatch, io, os, sys, urllib.request, zipfile

class Remote(io.RawIOBase):
    def __init__(self, url):
        self.url, self.pos = url, 0
        req = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "rexui-fonts"})
        with urllib.request.urlopen(req, timeout=60) as r:
            self.url = r.geturl()
            self.size = int(r.headers["Content-Length"])
            if r.headers.get("Accept-Ranges", "") != "bytes":
                print("zipget: no range requests at %s" % self.url, file=sys.stderr)
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else self.pos + off if whence == 1 else self.size + off
        return self.pos
    def readinto(self, b):
        if self.pos >= self.size: return 0
        end = min(self.size, self.pos + len(b)) - 1
        req = urllib.request.Request(self.url, headers={"Range": "bytes=%d-%d" % (self.pos, end), "User-Agent": "rexui-fonts"})
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)

args = sys.argv[1:]
url = args.pop(0)
into = None
if "--into" in args:
    i = args.index("--into"); into = args[i + 1]; del args[i:i + 2]
listing = "--list" in args
globs = [a for a in args if a != "--list"]
z = zipfile.ZipFile(io.BufferedReader(Remote(url), buffer_size=1 << 20))
for info in z.infolist():
    if listing:
        print(info.file_size, info.filename)
        continue
    name = os.path.basename(info.filename)
    if not name or not any(fnmatch.fnmatch(info.filename, g) for g in globs): continue
    out = os.path.join(into, name)
    with z.open(info) as src, open(out + ".part", "wb") as dst:
        while chunk := src.read(1 << 20): dst.write(chunk)
    os.replace(out + ".part", out)
    print("  %s (%d KB)" % (name, info.file_size // 1024))
