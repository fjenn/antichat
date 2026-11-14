#!/bin/zsh
# AT-287 AC1 (M4.T09 step 2): does Finder Get Info ("More Info" → Description) show a saved picture's details?
#   tools/media/check-getinfo.sh <saved.png> [<prompt>]
# Re-imports the file into Spotlight (`mdimport`), then reads kMDItemDescription (+ kMDItemCreator for the log).
# Exit 0 iff the description holds `model `, `seed ` and `steps ` and, when <prompt> is given, the prompt itself.
# (DigitalSourceType is not indexed by Spotlight: MediaProvenanceWriterTests/testPNGFields asserts it via ImageIO.)
set -u
file=${1:?usage: check-getinfo.sh <saved.png> [<prompt>]}
prompt=${2:-}
[[ -f $file ]] || { print -u2 "check-getinfo: no file $file"; exit 2; }
mdimport "$file" 2>/dev/null
desc=""
for _ in {1..20}; do
  desc=$(mdls -raw -name kMDItemDescription "$file" 2>/dev/null)
  [[ -n $desc && $desc != "(null)" ]] && break
  sleep 0.5
done
# A file outside an indexed location (build/, tmp) has no stored record: read what the Spotlight importer extracts
# for it (the same Image.mdimporter values Get Info shows for an indexed file).
if [[ -z $desc || $desc == "(null)" ]]; then
  desc=$(mdimport -t -d3 "$file" 2>&1 | python3 -I -c '
import re, sys
for line in sys.stdin:
    m = re.match(r"\s*kMDItemDescription = \"(.*)\";\s*$", line)
    if m:
        s = re.sub(r"\\U([0-9a-fA-F]{4})", lambda g: chr(int(g.group(1), 16)), m.group(1))
        print(s.encode("utf-16", "surrogatepass").decode("utf-16"))
        break')
  print "(read from the importer: the file is outside the Spotlight index)"
fi
creator=$(mdls -raw -name kMDItemCreator "$file" 2>/dev/null)
print "kMDItemDescription: $desc"
print "kMDItemCreator: $creator"
ok=1
for needle in "model " "seed " "steps "; do [[ $desc == *"$needle"* ]] || ok=0; done
[[ -n $prompt && $desc != *"$prompt"* ]] && ok=0
if (( ok )); then print "check-getinfo: PASS"; exit 0; fi
print -u2 "check-getinfo: FAIL (Get Info description lacks the details)"
exit 1
