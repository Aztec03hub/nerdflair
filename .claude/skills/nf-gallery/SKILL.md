---
name: nf-gallery
description: Render the nerdflair example gallery and save output for viewing
disable-model-invocation: true
allowed-tools: Bash
---

# Gallery

Run the nerdflair gallery script and save the ANSI output to a temp file for viewing.

```bash
bash scripts/screenshot.sh > /tmp/nerdflair-gallery.txt 2>&1
```

After running, tell the user to view it with:

```
cat /tmp/nerdflair-gallery.txt
```
