#!/bin/zsh
# Publishes the code to the public GitHub repository: only the program (app, engine, release
# scripts), README, pictures and the licence. The author's notes (CLAUDE.md), the diary
# (progress/), design drafts and recordings stay on this Mac. The public history is its own:
# commits by the GitHub account with its hidden e-mail.
#   release/publish.sh "What changed"
set -e
cd "$(dirname "$0")/.."
REPO=MAD-in95/MadStudio
AUTHOR=(-c user.name=MAD-in95 -c user.email=282940965+MAD-in95@users.noreply.github.com)
PUB=release/build/public
MSG=${1:-Update}

if [[ ! -d $PUB/.git ]]; then
    mkdir -p $PUB
    git clone -q https://github.com/$REPO.git $PUB 2>/dev/null || git -C $PUB init -q -b main
    git -C $PUB remote get-url origin >/dev/null 2>&1 || git -C $PUB remote add origin https://github.com/$REPO.git
fi
git -C $PUB rm -rq --ignore-unmatch .
git archive HEAD -- app engine release docs README.md LICENSE .gitignore | tar -x -C $PUB
git -C $PUB add -A
if git -C $PUB diff --cached --quiet; then
    echo "Нечего публиковать: на GitHub уже последняя версия"
else
    git -C $PUB $AUTHOR commit -qm "$MSG

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
    git -C $PUB push -q -u origin main
    echo "Опубликовано: https://github.com/$REPO"
fi
