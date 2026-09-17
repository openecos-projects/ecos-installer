{ pkgs }:

let
  validator = ./archive-validate.py;
  python = pkgs.python3;
in
pkgs.runCommand "ecos-release-archive-check"
  {
    nativeBuildInputs = [
      python
      pkgs.gnutar
      pkgs.gzip
      pkgs.bzip2
    ];
  }
  ''
    set -euo pipefail
    mkdir work
    cd work

    python3 - <<'PY'
    import io, tarfile, pathlib
    from pathlib import Path

    def write(path, members, mode):
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode=mode) as tar:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                payload = data
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
        Path(path).write_bytes(buf.getvalue())

    write("ok.tar.gz", {"lib/cell.lib": b"library() {}\n", "readme": b"ok\n"}, "w:gz")
    write("empty-liberty.tar.bz2", {"readme.txt": b"no liberty\n"}, "w:bz2")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo("keep/../../outside")
        data = b"nope\n"
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    Path("traverse.tar.gz").write_bytes(buf.getvalue())

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo("/tmp/evil")
        data = b"x"
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    Path("abs.tar.gz").write_bytes(buf.getvalue())

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo("bad\nname")
        data = b"x"
        info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    Path("ctrl.tar.gz").write_bytes(buf.getvalue())

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo("link")
        info.type = tarfile.SYMTYPE
        info.linkname = "../outside"
        tar.addfile(info)
    Path("link.tar.gz").write_bytes(buf.getvalue())

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        info = tarfile.TarInfo("pipe")
        info.type = tarfile.FIFOTYPE
        tar.addfile(info)
    Path("fifo.tar.gz").write_bytes(buf.getvalue())
    PY

    python3 ${validator} --require-liberty ok.tar.gz
    python3 ${validator} --require-liberty empty-liberty.tar.bz2 && { echo "empty liberty accepted" >&2; exit 1; }
    python3 ${validator} traverse.tar.gz && { echo "traversal accepted" >&2; exit 1; }
    python3 ${validator} abs.tar.gz && { echo "absolute accepted" >&2; exit 1; }
    python3 ${validator} ctrl.tar.gz && { echo "control accepted" >&2; exit 1; }
    python3 ${validator} link.tar.gz && { echo "escaping link accepted" >&2; exit 1; }
    python3 ${validator} fifo.tar.gz && { echo "fifo accepted" >&2; exit 1; }
    echo ok > "$out"
  ''
