# Semper landing page

This is a static site with no package or build dependency.

From the repository root:

```bash
python3 -m http.server 4173
```

Then open `http://localhost:4173/website/`.

Run the dependency-free smoke check after changing links, assets, or sections:

```bash
python3 scripts/check-website.py
```

Source, contribution, guide, and issue links point to
`https://github.com/niharnm/Semper`.
