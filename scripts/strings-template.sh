#!/bin/bash
# Prints every interface string of the app as a Localizable.strings template ("key" = "English text";), for
# translating: save it as Support/<lang>.lproj/Localizable.strings and replace the right-hand sides. Keys left out
# show in English.
# Inserted values become format specifiers, as the app passes them: %lld for numbers, %@ for text. Keep them (and
# their order) in the translation.
set -euo pipefail
cd "$(dirname "$0")/.."
numbers='page \+ 1|pageCount|folders|placed|hidden|appCount|count|fileCount|extra'
grep -rhoE 'L\("[^"]+", *"([^"\\]|\\.)*"\)' Sources/LaunchMat \
    | sed -E 's/^L\(("[^"]+"), *("([^"\\]|\\.)*")\)$/\1 = \2;/' \
    | sed -E "s/\\\\\\(($numbers)\\)/%lld/g; s/\\\\\\([^)]*\\)/%@/g" \
    | sort -u
