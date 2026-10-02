"""Audit whether a built MaterialIcons font actually covers the icons this app uses.

Instead of guessing icon names, this reads:
  1. every `Icons.<name>` reference in lib/
  2. the real code point of each from Flutter's icons.dart
  3. the code points the font's cmap actually maps
and reports the intersection.

ASCII-only output (the Windows console mangles CJK).
"""
import os
import re
import struct
import sys


def read_codepoints(path):
    with open(path, "rb") as handle:
        data = handle.read()
    num_tables = struct.unpack(">H", data[4:6])[0]
    tables = {}
    for i in range(num_tables):
        off = 12 + i * 16
        tag = data[off:off + 4].decode("latin-1")
        toff, tlen = struct.unpack(">II", data[off + 8:off + 16])
        tables[tag] = (toff, tlen)
    if "cmap" not in tables:
        return None
    coff, _ = tables["cmap"]
    n = struct.unpack(">H", data[coff + 2:coff + 4])[0]
    subs = []
    for i in range(n):
        rec = coff + 4 + i * 8
        pid, eid, soff = struct.unpack(">HHI", data[rec:rec + 8])
        subs.append((pid, eid, coff + soff))
    cps = set()
    for _pid, _eid, soff in subs:
        fmt = struct.unpack(">H", data[soff:soff + 2])[0]
        if fmt == 4:
            seg = struct.unpack(">H", data[soff + 6:soff + 8])[0] // 2
            ends = struct.unpack(">%dH" % seg, data[soff + 14:soff + 14 + seg * 2])
            so = soff + 14 + seg * 2 + 2
            starts = struct.unpack(">%dH" % seg, data[so:so + seg * 2])
            for s, e in zip(starts, ends):
                if s == 0xFFFF and e == 0xFFFF:
                    continue
                cps.update(range(s, e + 1))
        elif fmt == 12:
            ngroups = struct.unpack(">I", data[soff + 12:soff + 16])[0]
            for g in range(ngroups):
                go = soff + 16 + g * 12
                sc, ec, _ = struct.unpack(">III", data[go:go + 12])
                cps.update(range(sc, ec + 1))
    return cps


def load_icon_table(icons_dart):
    text = open(icons_dart, encoding="utf-8").read()
    # NOTE: some icons are declared with the code point on the NEXT line:
    #     static const IconData chevron_left = IconData(
    #         0xe15e,
    # so the pattern must tolerate whitespace (including newlines) after "(".
    # Getting this wrong silently under-reports coverage, which is worse than
    # reporting nothing -- an unverified icon looks verified.
    pattern = re.compile(
        r"static const IconData (\w+) = IconData\(\s*(0x[0-9a-fA-F]+)"
    )
    return {m.group(1): int(m.group(2), 16) for m in pattern.finditer(text)}


def used_icon_names(lib_dir):
    pattern = re.compile(r"\bIcons\.(\w+)\b")
    names = set()
    for root, _dirs, files in os.walk(lib_dir):
        for name in files:
            if not name.endswith(".dart"):
                continue
            with open(os.path.join(root, name), encoding="utf-8") as handle:
                names.update(pattern.findall(handle.read()))
    return names


def main():
    icons_dart = sys.argv[1]
    lib_dir = sys.argv[2]
    fonts = sys.argv[3:]

    table = load_icon_table(icons_dart)
    used = used_icon_names(lib_dir)

    resolved = {}
    unknown = []
    for name in sorted(used):
        if name in table:
            resolved[name] = table[name]
        else:
            unknown.append(name)

    print("icons referenced in lib/ : %d" % len(used))
    print("code points resolved     : %d" % len(resolved))
    if unknown:
        print("names not found in icons.dart (check manually): %s" % ", ".join(unknown))
    print()

    for font in fonts:
        cps = read_codepoints(font)
        size = os.path.getsize(font)
        if cps is None:
            print("%s -> cannot parse" % font)
            continue
        present = [n for n, cp in resolved.items() if cp in cps]
        missing = [n for n, cp in resolved.items() if cp not in cps]
        print("=" * 68)
        print("FONT: %s" % font)
        print("  size=%d bytes  codepoints_in_font=%d" % (size, len(cps)))
        print("  app icons present : %d / %d" % (len(present), len(resolved)))
        print("  app icons MISSING : %d" % len(missing))
        if missing:
            for name in missing:
                print("      missing  %-32s U+%05X" % (name, resolved[name]))
        print()


if __name__ == "__main__":
    main()
