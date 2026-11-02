#!/usr/bin/env python3
"""Add LC_DYLD_ENVIRONMENT load commands to an unsigned thin arm64 Mach-O executable, in place.

Usage: scripts/add-dyld-environment.py <executable> NAME=VALUE...

dyld reads them only from the main executable, and honors them under the hardened runtime: the
copy of Lilo that runs on the WebKit fork uses them to load the frameworks in Contents/Frameworks.
"""
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_ENVIRONMENT = 0x27


def main(path, variables):
    with open(path, "r+b") as file:
        data = bytearray(file.read())
        magic, _, _, _, ncmds, sizeofcmds, _, _ = struct.unpack_from("<8I", data, 0)
        if magic != MH_MAGIC_64:
            sys.exit(f"{path}: not a thin 64-bit Mach-O")

        # The new commands go in the padding between the load commands and the first section.
        first_section = len(data)
        offset = 32
        for _ in range(ncmds):
            cmd, cmdsize = struct.unpack_from("<2I", data, offset)
            if cmd == LC_CODE_SIGNATURE:
                sys.exit(f"{path}: remove the signature first")
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack_from("<I", data, offset + 64)[0]
                for index in range(nsects):
                    section_offset = struct.unpack_from("<I", data, offset + 72 + index * 80 + 48)[0]
                    if section_offset:
                        first_section = min(first_section, section_offset)
            offset += cmdsize

        commands = b""
        for variable in variables:
            name = variable.encode() + b"\0"
            cmdsize = (12 + len(name) + 7) & ~7
            commands += struct.pack("<3I", LC_DYLD_ENVIRONMENT, cmdsize, 12) + name.ljust(cmdsize - 12, b"\0")
        # Signing adds LC_CODE_SIGNATURE (16 bytes) after them.
        end = 32 + sizeofcmds
        if end + len(commands) + 16 > first_section:
            sys.exit(f"{path}: {first_section - end} bytes of header padding, {len(commands) + 16} needed")

        data[end:end + len(commands)] = commands
        struct.pack_into("<2I", data, 16, ncmds + len(variables), sizeofcmds + len(commands))
        file.seek(0)
        file.write(data)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2:])
