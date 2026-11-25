#!/usr/bin/env python3
"""Generate and optionally verify a headless Finder .DS_Store for a DMG volume."""

import argparse
import os
import plistlib
import struct

MAC_EPOCH_OFFSET = 2082844800


def mac_timestamp(unix_ts: float) -> int:
    return int(unix_ts) + MAC_EPOCH_OFFSET


def pad_pascal(raw: bytes, field_len: int) -> bytes:
    """Encode 1-byte length + ASCII/UTF-8 bytes padded with NULs to field_len+1 bytes."""
    clipped = raw[:field_len]
    return bytes([len(clipped)]) + clipped.ljust(field_len, b"\x00")


def pack_tag(tag: int, data: bytes) -> bytes:
    pad = b"\x00" if (len(data) % 2 == 1) else b""
    return struct.pack(">hH", tag, len(data)) + data + pad


def build_alias_v2(vol_name: str, vol_date: int, parent_cnid: int,
                   bg_filename: str, file_cnid: int, file_date: int) -> bytes:
    vol_utf8 = vol_name.encode("utf-8")
    fn_utf8 = bg_filename.encode("utf-8")

    tags = b"".join([
        pack_tag(0, vol_utf8),
        pack_tag(16, struct.pack(">Q", vol_date << 16)),
        pack_tag(17, struct.pack(">Q", file_date << 16)),
        pack_tag(2, f"{vol_name}:{bg_filename}".encode("utf-8")),
        pack_tag(14, struct.pack(">H", len(bg_filename)) + bg_filename.encode("utf-16-be")),
        pack_tag(15, struct.pack(">H", len(vol_name)) + vol_name.encode("utf-16-be")),
        pack_tag(18, f"/{bg_filename}".encode("utf-8")),
        pack_tag(19, f"/Volumes/{vol_name}".encode("utf-8")),
        struct.pack(">hH", -1, 0),
    ])

    total_len = 150 + len(tags)
    header = (
        struct.pack(">4sHHH", b"\x00\x00\x00\x00", total_len, 2, 0)
        + pad_pascal(vol_utf8, 27)
        + struct.pack(">I2sHI", vol_date, b"H+", 0, parent_cnid)
        + pad_pascal(fn_utf8, 63)
        + struct.pack(">II4s4shhIH10s", file_cnid, file_date, b"\x00\x00\x00\x00",
                      b"\x00\x00\x00\x00", -1, -1, 0, 0, b"\x00" * 10)
    )
    assert len(header) == 150, f"Unexpected alias header len: {len(header)}"
    return header + tags


def encode_record(filename: str, code: str, dtype: str, value) -> bytes:
    fn_utf16 = filename.encode("utf-16-be")
    header = (
        struct.pack(">I", len(filename))
        + fn_utf16
        + code.encode("ascii")
        + dtype.encode("ascii")
    )
    if dtype == "blob":
        payload = struct.pack(">I", len(value)) + value
    elif dtype == "long":
        payload = struct.pack(">I", value)
    elif dtype == "type":
        assert len(value) == 4
        payload = value
    elif dtype == "bool":
        payload = struct.pack(">B", 1 if value else 0)
    else:
        raise ValueError(f"Unsupported DS_Store record type: {dtype}")
    return header + payload


def build_dsstore_bytes(mount_dir: str, vol_name: str, bg_filename: str, app_name: str) -> bytes:
    bg_path = os.path.join(mount_dir, bg_filename)
    mount_st = os.stat(mount_dir)
    bg_st = os.stat(bg_path)

    vol_date = mac_timestamp(getattr(mount_st, "st_birthtime", mount_st.st_mtime))
    file_date = mac_timestamp(getattr(bg_st, "st_birthtime", bg_st.st_mtime))

    alias_bytes = build_alias_v2(
        vol_name=vol_name,
        vol_date=vol_date,
        parent_cnid=int(mount_st.st_ino),
        bg_filename=bg_filename,
        file_cnid=int(bg_st.st_ino),
        file_date=file_date,
    )

    bwsp = plistlib.dumps(
        {
            "ContainerShowSidebar": False,
            "PreviewPaneVisibility": False,
            "ShowPathbar": False,
            "ShowSidebar": False,
            "ShowStatusBar": False,
            "ShowTabView": False,
            "ShowToolbar": False,
            "SidebarWidth": 180,
            "WindowBounds": "{{280, 220}, {640, 460}}",
        },
        fmt=plistlib.FMT_BINARY,
        sort_keys=True,
    )

    icvp = plistlib.dumps(
        {
            "arrangeBy": "none",
            "backgroundColorBlue": 0.941,
            "backgroundColorGreen": 0.914,
            "backgroundColorRed": 0.902,
            "backgroundImageAlias": alias_bytes,
            "backgroundType": 2,
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "gridSpacing": 100.0,
            "iconSize": 120.0,
            "labelOnBottom": True,
            "scrollPositionX": 0.0,
            "scrollPositionY": 0.0,
            "showIconPreview": False,
            "showItemInfo": False,
            "textSize": 12.0,
            "viewOptionsVersion": 1,
        },
        fmt=plistlib.FMT_BINARY,
        sort_keys=True,
    )

    records = [
        (".", "bwsp", "blob", bwsp),
        (".", "icvl", "type", b"icnv"),
        (".", "icvp", "blob", icvp),
        (".", "vSrn", "long", 1),
        ("Applications", "Iloc", "blob", struct.pack(">II6sH", 474, 214, b"\xff" * 6, 0)),
        (app_name, "Iloc", "blob", struct.pack(">II6sH", 166, 214, b"\xff" * 6, 0)),
    ]
    records.sort(key=lambda r: (r[0].lower().encode("utf-16-be"), r[1].encode("ascii")))

    leaf = bytearray(struct.pack(">II", 0, len(records)))
    for fn, code, dtype, val in records:
        leaf.extend(encode_record(fn, code, dtype, val))
    assert len(leaf) <= 4096, f"B-tree leaf node overflow: {len(leaf)} bytes"

    # Allocate a standard 16388-byte Bud1 file:
    #   File bytes 0..4   : 0x00000001 alignment prefix
    #   Buddy 0x0000..0020 (file 4..36)    : Bud1 header
    #   Buddy 0x0020..0040 (file 36..68)   : block[1] DSDB superblock (32 bytes)
    #   Buddy 0x0800..1000 (file 2052..4100): block[0] Buddy allocator root (2048 bytes)
    #   Buddy 0x2000..4000 (file 8196..16388): block[2] B-tree leaf node (8192 bytes)
    total_file_size = 4 + 16384
    buf = bytearray(total_file_size)

    root_off = 2048
    root_size = 2048
    header = struct.pack(">I4sIII16s", 1, b"Bud1", root_off, root_size, root_off, b"\x00" * 16)
    buf[0:36] = header

    # block[1]: DSDB superblock at Buddy offset 0x20 (file 36)
    dsdb = struct.pack(">IIIII12x", 2, 0, len(records), 1, 4096)
    buf[36:68] = dsdb

    # block[0]: Buddy directory + TOC + free-list buckets at file offset 2052
    pos = 4 + root_off
    blocks = [
        (0x0800 | 11),  # block 0: 2^11 = 2048 bytes @ 0x0800
        (0x0020 | 5),   # block 1: 2^5  = 32 bytes   @ 0x0020
        (0x2000 | 13),  # block 2: 2^13 = 8192 bytes @ 0x2000
    ]
    struct.pack_into(">II", buf, pos, len(blocks), 0)
    pos += 8
    for i, addr in enumerate(blocks):
        struct.pack_into(">I", buf, pos + i * 4, addr)
    pos += 256 * 4

    # TOC: 1 entry ('DSDB' -> block 1)
    struct.pack_into(">I", buf, pos, 1)
    pos += 4
    buf[pos] = 4
    pos += 1
    buf[pos:pos + 4] = b"DSDB"
    pos += 4
    struct.pack_into(">I", buf, pos, 1)
    pos += 4

    # Free lists across 32 buddy powers (2^0 .. 2^31)
    free_buckets = {
        6: [0x40],
        7: [0x80],
        8: [0x100],
        9: [0x200],
        10: [0x400],
        12: [0x1000],
    }
    for exp in range(14, 31):
        free_buckets[exp] = [1 << exp]

    for exp in range(32):
        entries = free_buckets.get(exp, [])
        struct.pack_into(">I", buf, pos, len(entries))
        pos += 4
        for offset in entries:
            struct.pack_into(">I", buf, pos, offset)
            pos += 4

    assert pos <= 4 + root_off + root_size, f"Root directory overflowed: {pos}"

    # block[2]: B-tree leaf node at Buddy offset 0x2000 (file 8196)
    buf[4 + 0x2000:4 + 0x2000 + len(leaf)] = leaf
    return bytes(buf)


def verify_dsstore(dsstore_path: str, app_name: str, bg_filename: str) -> None:
    with open(dsstore_path, "rb") as f:
        buf = f.read()

    magic, bud1, off, size, off2 = struct.unpack(">I4sIII", buf[:20])
    assert magic == 1 and bud1 == b"Bud1", "Bad Bud1 header"
    assert off == off2 and off + 4 + size <= len(buf), "Invalid root bounds"

    pos = off + 4
    count, _ = struct.unpack(">II", buf[pos:pos + 8])
    pos += 8
    padded = (count + 255) & ~255
    blocks = struct.unpack(f">{padded}I", buf[pos:pos + padded * 4])[:count]
    pos += padded * 4

    (toc_len,) = struct.unpack(">I", buf[pos:pos + 4])
    pos += 4
    toc = {}
    for _ in range(toc_len):
        nl = buf[pos]
        pos += 1
        name = buf[pos:pos + nl].decode("ascii")
        pos += nl
        (bid,) = struct.unpack(">I", buf[pos:pos + 4])
        pos += 4
        toc[name] = bid
    assert "DSDB" in toc, "Missing DSDB in TOC"

    def block_slice(bid: int) -> bytes:
        addr = blocks[bid]
        b_off = (addr & ~0x1F) + 4
        b_size = 1 << (addr & 0x1F)
        return buf[b_off:b_off + b_size]

    root_blk, levels, n_records, n_nodes, page_size = struct.unpack(">IIIII", block_slice(toc["DSDB"])[:20])
    assert levels == 0 and n_records == 6 and n_nodes == 1 and page_size == 4096, "Unexpected DSDB stats"

    b = block_slice(root_blk)
    next_ptr, rcount = struct.unpack(">II", b[:8])
    assert next_ptr == 0 and rcount == 6, "Unexpected leaf header"
    p = 8
    parsed = {}
    for _ in range(rcount):
        (fn_len,) = struct.unpack(">I", b[p:p + 4])
        p += 4
        fn = b[p:p + fn_len * 2].decode("utf-16-be")
        p += fn_len * 2
        code = b[p:p + 4].decode("ascii")
        dtype = b[p + 4:p + 8].decode("ascii")
        p += 8
        if dtype in ("long", "shor"):
            (val,) = struct.unpack(">I", b[p:p + 4])
            p += 4
        elif dtype == "type":
            val = b[p:p + 4]
            p += 4
        elif dtype == "blob":
            (blen,) = struct.unpack(">I", b[p:p + 4])
            p += 4
            val = b[p:p + blen]
            p += blen
        else:
            raise AssertionError(f"Unexpected dtype: {dtype}")
        parsed[(fn, code)] = val

    bwsp = plistlib.loads(parsed[(".", "bwsp")])
    assert bwsp["ShowToolbar"] is False and bwsp["ShowSidebar"] is False
    assert bwsp["WindowBounds"] == "{{280, 220}, {640, 460}}"
    assert parsed[(".", "icvl")] == b"icnv"
    assert parsed[(".", "vSrn")] == 1

    icvp = plistlib.loads(parsed[(".", "icvp")])
    assert icvp["iconSize"] == 120.0 and icvp["backgroundType"] == 2
    alias = icvp["backgroundImageAlias"]
    assert alias[6:10] == b"\x00\x02\x00\x00" and bg_filename.encode("utf-8") in alias

    app_x, app_y = struct.unpack(">II", parsed[(app_name, "Iloc")][:8])
    apps_x, apps_y = struct.unpack(">II", parsed[("Applications", "Iloc")][:8])
    assert (app_x, app_y) == (166, 214) and (apps_x, apps_y) == (474, 214)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build Finder .DS_Store for a mounted DMG volume.")
    parser.add_argument("--mount-dir", required=True, help="Mounted HFS+ volume root directory")
    parser.add_argument("--vol-name", required=True, help="Volume name (e.g. 'Bianzhong 0.2.0')")
    parser.add_argument("--bg-filename", default=".background.tiff", help="Background filename in volume root")
    parser.add_argument("--app-name", default="Bianzhong.app", help="App bundle name in volume root")
    parser.add_argument("--verify", action="store_true", help="Re-read and validate generated .DS_Store")
    parser.add_argument("--verify-only", help="Validate an existing .DS_Store file without writing")
    args = parser.parse_args()

    if args.verify_only:
        verify_dsstore(args.verify_only, args.app_name, args.bg_filename)
        print(f"Verified existing .DS_Store: {args.verify_only}")
        return

    dsstore_path = os.path.join(args.mount_dir, ".DS_Store")
    raw = build_dsstore_bytes(args.mount_dir, args.vol_name, args.bg_filename, args.app_name)
    with open(dsstore_path, "wb") as f:
        f.write(raw)

    if args.verify:
        verify_dsstore(dsstore_path, args.app_name, args.bg_filename)
        print(f"Generated and verified .DS_Store ({len(raw)} bytes): {dsstore_path}")
    else:
        print(f"Generated .DS_Store ({len(raw)} bytes): {dsstore_path}")


if __name__ == "__main__":
    main()
