#!/usr/bin/env python2
"""Remove the stale Avatar entry from db.xml."""
import re

DB_XML = "/home/great/bw-build/game/res/fantasydemo/scripts/db.xml"

with open(DB_XML, "r") as f:
    content = f.read()

# Remove ALL <Avatar>...</Avatar> blocks
pattern = r'\s*<Avatar>.*?</Avatar>'
matches = re.findall(pattern, content, re.DOTALL)
print "Found %d Avatar block(s)" % len(matches)
for m in matches:
    # Show the databaseID line for debugging
    for line in m.split('\n'):
        if 'databaseID' in line:
            print "  Avatar block has:", line.strip()
    print "Removing Avatar block"
    content = content.replace(m, "")

# Write back
with open(DB_XML, "w") as f:
    f.write(content)

print "db.xml cleaned up successfully"
print "Remaining Avatar blocks:", content.count("<Avatar>")
print "Remaining Account blocks:", content.count("<Account>")
