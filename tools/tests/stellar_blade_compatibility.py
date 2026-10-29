"""Check the Stellar Blade profile and, optionally, scan a local game PE without launching it.

python tools/tests/stellar_blade_compatibility.py --exe path/to/SB-Win64-Shipping.exe
Only Python's standard library is required. No game bytes are written or distributed.
"""

import argparse
import configparser
import hashlib
import json
from pathlib import Path
import re
import struct


ROOT = Path(__file__).resolve().parents[2]
PROFILE = ROOT / "assets/CustomGameConfigs/Stellar Blade"


def ordered_sections(path):
    result = {}
    current = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if line.startswith("["):
            current = result.setdefault(line[1:-1], [])
        elif line and not line.startswith(";"):
            current.append(line)
    return result


def check_profile():
    stock = ordered_sections(ROOT / "assets/VTableLayoutTemplates/VTableLayout_4_26_Template.ini")
    game = ordered_sections(PROFILE / "VTableLayout.ini")
    assert game.keys() == stock.keys(), "Profile must retain upstream's complete layout"
    for section, entries in game.items():
        if section == "AActor":
            assert [v for v in entries if not re.fullmatch(r"Unk\d+", v)] == stock[section]
            assert len(entries) == len(stock[section]) + 10
            # The extra game virtuals shift Tick by 0x50 bytes.
            assert entries.index("Tick") - stock[section].index("Tick") == 10
        else:
            assert entries == stock[section], f"Unexpected non-actor layout change: {section}"
        assert len(set(entries)) == len(entries), f"Duplicate virtual names in {section}"
    members = configparser.ConfigParser()
    members.read(PROFILE / "MemberVariableLayout.ini")
    assert int(members["FUObjectArray"]["UObjectCreateListeners"], 0) == 0x68
    assert int(members["FUObjectArray"]["UObjectDeleteListeners"], 0) == 0x78
    settings = configparser.ConfigParser()
    settings.read(PROFILE / "UE4SS-settings.ini")
    assert settings.getint("EngineVersionOverride", "MajorVersion") == 4
    assert settings.getint("EngineVersionOverride", "MinorVersion") == 26
    assert not settings.getboolean("EngineVersionOverride", "DebugBuild")
    assert not settings.getboolean("EngineVersionOverride", "Stats")
    assert settings.getboolean("Debug", "ConsoleEnabled")
    assert not settings.getboolean("Debug", "GuiConsoleEnabled")
    assert not settings.getboolean("Debug", "GuiConsoleVisible")
    return {"profile": "passed", "extra_actor_slots": 10}


def scan_executable(path):
    data = path.read_bytes()
    assert data[:2] == b"MZ", "Not a PE executable"
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0"
    machine, count = struct.unpack_from("<HH", data, pe + 4)
    assert machine == 0x8664, "Expected x64"
    optional_size = struct.unpack_from("<H", data, pe + 20)[0]
    optional = pe + 24
    assert struct.unpack_from("<H", data, optional)[0] == 0x20B
    image_base = struct.unpack_from("<Q", data, optional + 24)[0]
    sections = []
    for i in range(count):
        offset = optional + optional_size + 40 * i
        name = data[offset:offset + 8].rstrip(b"\0").decode("ascii")
        size, rva, raw_size, raw_offset = struct.unpack_from("<IIII", data, offset + 8)
        flags = struct.unpack_from("<I", data, offset + 36)[0]
        sections.append((name, rva, size, raw_offset, raw_size, flags))
    result = {"exe_sha256": hashlib.sha256(data).hexdigest(), "image_base": hex(image_base), "signatures": {}}
    # displacement offset / instruction length, matching each Lua resolver.
    for name, displacement in {"GUObjectArray": (2, 6), "GNatives": (3, 7), "FText_Constructor": None}.items():
        script = (PROFILE / "UE4SS_Signatures" / (name + ".lua")).read_text()
        pattern = re.search(r'return "([0-9A-Fa-f? ]+)"', script)[1].split()
        regex = re.compile(b"".join(b"." if "?" in token else re.escape(bytes.fromhex(token)) for token in pattern), re.DOTALL)
        matches = []
        for section, rva, size, raw, raw_size, flags in sections:
            if flags & 0x20000000:  # IMAGE_SCN_MEM_EXECUTE
                matches.extend((rva + m.start(), raw + m.start()) for m in regex.finditer(data[raw:raw + raw_size]))
        assert matches, f"{name}: no code match"
        targets = set()
        for match_rva, match_raw in matches:
            target = match_rva
            if displacement:
                disp_offset, instruction_size = displacement
                target += instruction_size + struct.unpack_from("<i", data, match_raw + disp_offset)[0]
            targets.add(target)
        # GNatives initialization is emitted in multiple translation units. All matches
        # must resolve to the same table; requiring one instruction match would reject it.
        assert len(targets) == 1, f"{name}: ambiguous targets: {sorted(targets)}"
        target = targets.pop()
        destination = next((s for s in sections if s[1] <= target < s[1] + max(s[2], s[4])), None)
        assert destination is not None, f"{name}: target is outside the image"
        if displacement:
            assert target % 8 == 0 and destination[5] & 0x80000000, f"{name}: expected aligned writable data"
        else:
            assert destination[5] & 0x20000000, "FText constructor must point into executable code"
        result["signatures"][name] = {"matches": len(matches), "first_match_rva": hex(matches[0][0]), "target_rva": hex(target), "section": destination[0]}
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = check_profile()
    if args.exe:
        report.update(scan_executable(args.exe))
    text = json.dumps(report, indent=2)
    print(text)
    if args.output:
        args.output.write_text(text + "\n")
