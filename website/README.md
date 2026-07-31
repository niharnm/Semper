# Semper landing page

This is a static site with no package or build dependency.

From the repository root:

```bash
python3 -m http.server 4173
```

Then open `http://localhost:4173/website/`.

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
