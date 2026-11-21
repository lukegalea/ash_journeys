# Rules for working with AshJourneys

- A journey's steps reference declared symbols, such as surface ids, Ash actions and A2UI row-action ids. Never write a CSS selector or a URL in a journey.
- Narration (`say`, `note`, `title`, `goal`, `outcome`) is authored prose held as gettext msgids. Never generate it from the steps.
- Documentation, help and agent answers read only approved runs (`priv/journeys/`). Never render from a declaration or a raw run.
- A run that passed only after a retry is flaky. It is never approved and never counts as evidence.
- This package never runs a browser and never records evidence itself. Hosts implement the evidence and figure-store behaviours.
