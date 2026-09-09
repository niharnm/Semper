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

After changed pages are live, preview and send their canonical URLs to
IndexNow:

```bash
python3 scripts/submit-indexnow.py --dry-run \
  https://www.semper.systems/about.html
python3 scripts/submit-indexnow.py \
  https://www.semper.systems/about.html
```

Omit positional URLs to submit every URL in `website/sitemap.xml`.

An HTTP 200 or 202 response confirms receipt, not crawling, indexing, ranking,
or recommendation. The sitemap remains submitted separately in Google Search
Console.

Source, contribution, guide, and issue links point to
`https://github.com/niharnm/Semper`.

## Hero CTA experiment

`website.hero-repository-cta-copy.v1` assigns visitors to one of two labels:

- `control`: `View the source`
- `treatment`: `Open Semper on GitHub`

The assignment is stored in `localStorage`, with `sessionStorage` as a
fallback. Force a variant for local testing without changing the stored
assignment:

```text
http://localhost:4173/website/?semper_ab=website.hero-repository-cta-copy.v1:control
http://localhost:4173/website/?semper_ab=website.hero-repository-cta-copy.v1:treatment
```

The page dispatches `semper:experiment` events on `window`. Event details
contain anonymous subject and session IDs, the experiment and variant, and
either `experiment_exposure` or `experiment_outcome`. Events stay in the
browser; the site does not send them over the network, so this repository does
not yet aggregate results or select a winner.

Run the dependency-free tests from the repository root:

```bash
node --test website/ab-testing.test.js
```

## Product availability and comparisons

The homepage distinguishes the published Sound release from development
modules. When a packaged release changes, update the download context,
`SoftwareApplication.softwareVersion`, FAQ text and schema, `about.html`,
`llms.txt`, and the modified pages in `sitemap.xml` together. A merged feature
PR alone is not evidence of availability in the download.

The comparison table links to primary feature documentation. Its dated
feature descriptions are separate from the performance section. Do not use
feature counts, missing measurements, or an observational sample as a ranking.

For benchmark publication, consume the reviewed evidence from
`scripts/benchmarks/evidence/` only after that work is integrated. Schema v1
uses `status` and `comparison_eligible`: `unmeasured` has no metrics;
`observational` is not eligible for comparisons. Keep the current unmeasured
presentation until controlled evidence is approved. Add immutable report and
raw-data links, exact build and workload details, units, repetitions, and
variation with any published result. Do not automatically render arbitrary
JSON values as scores.

Verification:

```bash
python3 scripts/check-website.py
python3 scripts/test_website_tools.py
node --test website/ab-testing.test.js
```

Check the homepage at desktop and narrow mobile widths. Exercise module
scope disclosures by keyboard, scroll the comparison table to its final
column, try the Sound sliders and mute buttons, and inspect reduced motion.
