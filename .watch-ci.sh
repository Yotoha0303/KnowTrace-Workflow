set -u
RUN=37307352954
gh run watch "$RUN" --exit-status >/dev/null 2>&1 || true
echo "===== 运行结束 ====="
gh run view "$RUN" --json status,conclusion --jq '"status=\(.status) conclusion=\(.conclusion)"'
echo "--- 各 job ---"
gh run view "$RUN" --json jobs --jq '.jobs[] | "\(.conclusion)\t\(.name)"'
echo "--- e2e 各步 ---"
gh run view "$RUN" --json jobs --jq '.jobs[] | select(.name|test("End-to-end")) | .steps[] | "\(.conclusion)\t\(.number). \(.name)"'
