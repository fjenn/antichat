#!/bin/zsh
# Merge an agent branch into main via the integration worktree, resolving append-only doc conflicts by union.
# Usage: merge-agent-branch.sh <branch>
set -e
B=$1; IW=~/AntiChat/.claude/worktrees/integration-m0
cd $IW
git merge --no-edit main >/dev/null 2>&1 || true
if ! git merge --no-ff --no-edit "$B" >/dev/null 2>&1; then
  python3 - <<'PY'
import re,json,subprocess
files=subprocess.check_output(["git","diff","--name-only","--diff-filter=U"]).decode().split()
left=[]
for f in files:
    if f.endswith(".json"):
        try:
            o=json.loads(subprocess.check_output(["git","show",f":2:{f}"])); t=json.loads(subprocess.check_output(["git","show",f":3:{f}"]))
            if isinstance(o,list) and isinstance(t,list):
                by={json.dumps(x.get("id") if isinstance(x,dict) else x):x for x in o}
                for x in t:
                    k=json.dumps(x.get("id") if isinstance(x,dict) else x)
                    if k not in by or str((x.get("status") if isinstance(x,dict) else "")).lower() not in ("","pending","open","planned"): by[k]=x
                json.dump(list(by.values()),open(f,"w"),indent=2); continue
            if isinstance(o,dict) and isinstance(t,dict):
                def deep(a,b):
                    if isinstance(a,dict) and isinstance(b,dict):
                        r=dict(a)
                        for k,v in b.items(): r[k]=deep(a[k],v) if k in a else v
                        return r
                    if isinstance(a,list) and isinstance(b,list):
                        seen={json.dumps(x,sort_keys=True) for x in a}
                        return a+[x for x in b if json.dumps(x,sort_keys=True) not in seen]
                    return b
                json.dump(deep(o,t),open(f,"w"),indent=2); continue
        except Exception: pass
        left.append(f); continue
    if f.endswith(".md"):
        s=open(f).read()
        s=re.sub(r"<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n", lambda m: m.group(1)+m.group(2), s, flags=re.S)
        open(f,"w").write(s); continue
    left.append(f)
print("UNRESOLVED:"," ".join(left) if left else "none")
PY
fi
