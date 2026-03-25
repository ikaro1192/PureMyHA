#!/usr/bin/env python3
"""Convert HPC .tix + .mix files to lcov format.

Usage: tix-to-lcov.py <tix_file> <mix_dir> <output_lcov>

Parses GHC HPC coverage data (.tix tick counts and .mix source positions)
and generates an lcov-compatible coverage report.

This replaces hpc-lcov for Cabal projects (hpc-lcov requires Stack).
"""
import os
import re
import sys
from collections import defaultdict


def parse_tix(path):
    """Parse a .tix file, returning list of (module_name, [tick_counts]).

    .tix format (Haskell Show syntax):
      Tix [ TixModule "pkg/Module" <hash> <count> [t0,t1,...], ... ]
    """
    with open(path) as f:
        content = f.read()

    modules = []
    for m in re.finditer(
        r'TixModule\s+"([^"]+)"\s+\d+\s+\d+\s+\[([^\]]*)\]', content
    ):
        name = m.group(1)
        ticks_str = m.group(2).strip()
        if ticks_str:
            ticks = [int(x.strip()) for x in ticks_str.split(",")]
        else:
            ticks = []
        modules.append((name, ticks))
    return modules


def find_mix_file(mix_dir, module_name):
    """Find the .mix file for a module within the mix directory.

    Module name in .tix is like "pkg-version-component/Module.Name".
    The .mix file is at <mix_dir>/<pkg-component>/<Module.Name>.mix
    """
    parts = module_name.split("/", 1)
    if len(parts) != 2:
        return None
    pkg, mod = parts

    # Try exact path first
    mix_path = os.path.join(mix_dir, pkg, mod + ".mix")
    if os.path.isfile(mix_path):
        return mix_path

    # Search all subdirectories for the .mix file
    for root, _dirs, files in os.walk(mix_dir):
        fname = mod + ".mix"
        if fname in files:
            return os.path.join(root, fname)

    return None


def parse_mix(path):
    """Parse a .mix file, returning (source_path, [(line, col1, line2, col2), ...]).

    .mix format (Haskell Show syntax):
      Mix "src/path.hs" <timestamp> <hash> <tabstop>
        [(HpcPos l1 c1 l2 c2, BoxLabel), ...]
    """
    with open(path) as f:
        content = f.read()

    # Extract source file path
    src_match = re.search(r'Mix\s+"([^"]+)"', content)
    if not src_match:
        return None, []
    source_path = src_match.group(1)

    # Extract all HpcPos entries
    positions = []
    for m in re.finditer(r"(\d+):(\d+)-(\d+):(\d+)", content):
        positions.append(
            (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
        )

    return source_path, positions


def generate_lcov(tix_modules, mix_dir):
    """Generate lcov content from parsed tix modules and mix directory."""
    # Collect per-file, per-line coverage data
    file_lines = defaultdict(lambda: defaultdict(int))

    for module_name, ticks in tix_modules:
        # Skip Main modules (executable entry points, not library code)
        if module_name.endswith("/Main"):
            continue

        mix_path = find_mix_file(mix_dir, module_name)
        if not mix_path:
            print(f"WARNING: No .mix file found for {module_name}", file=sys.stderr)
            continue

        source_path, positions = parse_mix(mix_path)
        if not source_path:
            print(f"WARNING: Could not parse {mix_path}", file=sys.stderr)
            continue

        if len(positions) != len(ticks):
            print(
                f"WARNING: {module_name}: {len(positions)} positions vs {len(ticks)} ticks",
                file=sys.stderr,
            )
            count = min(len(positions), len(ticks))
        else:
            count = len(ticks)

        for i in range(count):
            start_line = positions[i][0]
            end_line = positions[i][2]
            tick_count = ticks[i]
            # Mark all lines in the span
            for line in range(start_line, end_line + 1):
                file_lines[source_path][line] = max(
                    file_lines[source_path][line], tick_count
                )

    # Generate lcov output
    output = []
    for source_file in sorted(file_lines):
        lines = file_lines[source_file]
        output.append(f"SF:{source_file}")
        for line_no in sorted(lines):
            output.append(f"DA:{line_no},{lines[line_no]}")
        total = len(lines)
        hit = sum(1 for c in lines.values() if c > 0)
        output.append(f"LF:{total}")
        output.append(f"LH:{hit}")
        output.append("end_of_record")

    return "\n".join(output) + "\n"


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <tix_file> <mix_dir> <output_lcov>")
        sys.exit(1)

    tix_file, mix_dir, output_file = sys.argv[1], sys.argv[2], sys.argv[3]

    if not os.path.isfile(tix_file):
        print(f"ERROR: .tix file not found: {tix_file}", file=sys.stderr)
        sys.exit(1)
    if not os.path.isdir(mix_dir):
        print(f"ERROR: .mix directory not found: {mix_dir}", file=sys.stderr)
        sys.exit(1)

    tix_modules = parse_tix(tix_file)
    print(f"Parsed {len(tix_modules)} modules from {tix_file}")

    lcov = generate_lcov(tix_modules, mix_dir)

    with open(output_file, "w") as f:
        f.write(lcov)

    # Count source files and DA lines for diagnostics
    sf_count = lcov.count("SF:")
    da_count = lcov.count("\nDA:")
    print(f"Generated lcov report: {output_file} ({sf_count} files, {da_count} lines)")


if __name__ == "__main__":
    main()
