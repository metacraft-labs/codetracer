# build_tree_sitter_lib.py <output-lib-path> <grammar-dir> [<grammar-dir-2>* ..]

import os
import sys
from tree_sitter import Language  # type: ignore

# parent folder of gdb folder: src/ (of src/gdb/tracepoint.py)
# install dir, where libs/ is

def run():
    grammar_dirs = []
    if len(sys.argv) > 2:
        output_lib_path = sys.argv[1]
        for arg in sys.argv[2:]:
            grammar_dirs.append(arg)
    else:
        print('error: expected <output-lib-path> <grammar-dir> [<grammar-dir-2>* ..]')
        sys.exit(1)

    Language.build_library(
      # Store the library in the output_lib_path file
      output_lib_path,
      # Include one or more languages
      grammar_dirs)

      # [
        # os.path.join(src_dir, 'tree-sitter-trace'),

        # os.path.join(libs_dir, 'tree-sitter-c'),

        # os.path.join(libs_dir, 'tree-sitter-rust'),

        # os.path.join(libs_dir, 'tree-sitter-nim')
    # ]
# )

run()
