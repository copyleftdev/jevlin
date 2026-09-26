#!/usr/bin/env python3
"""Assert that invalid public schemas fail compilation for the intended reason."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
cases = {
    "score_one": ('_ = @sizeOf(j.Score(1));', 'Score requires 2..10 levels'),
    "score_eleven": ('_ = @sizeOf(j.Score(11));', 'Score requires 2..10 levels'),
    "choice_256": ('_ = @sizeOf(j.Choice(enum {' + ','.join(f'o{i}' for i in range(256)) + '}));', 'Choice requires 1..255 options'),
    "empty_batch": ('_ = @sizeOf(j.Answers(struct {}));', 'A batch requires 1..128 questions'),
    "non_enum": ('_ = @sizeOf(j.Choice(u32));', 'Choice requires an exhaustive enum'),
}
with tempfile.TemporaryDirectory(prefix="jevlin-compile-") as directory:
    temp = pathlib.Path(directory)
    for name, (body, diagnostic) in cases.items():
        source = temp / f'{name}.zig'
        source.write_text('const j = @import("jevlin");\ncomptime {' + body + '}\n')
        run = subprocess.run([sys.argv[1], 'test', '--dep', 'jevlin', f'-Mroot={source}',
                              f'-Mjevlin={root / "src/root.zig"}', '--global-cache-dir', str(temp / 'cache')],
                             capture_output=True, text=True, timeout=60)
        if run.returncode == 0 or diagnostic not in run.stderr:
            sys.exit(f'{name}: wrong compilation result\n{run.stderr}')
        print(f'{name}: rejected as expected')
