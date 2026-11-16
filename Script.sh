#!/bin/sh

# .git/hooks/pre-commit


if git diff --cached | grep -E "^\+[^+]" | grep -q "PASSWORD="; then

echo "ERROR: Possible password found in staged changes."

echo "Remove it or use an environment variable."

exit 1 # non-zero = block the commit

fi


exit 0 # zero = allow the commit
