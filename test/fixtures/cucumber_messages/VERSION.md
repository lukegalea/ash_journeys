# Cucumber Messages JSON schema

The schema every message of `mix ash_journeys.export.messages` is validated against, in tests.

- Source: the npm package `@cucumber/messages` 35.0.0 (published 2026-11-12), file `messages.schema.json`.
  Protocol version 35.0.0 (the package version is the protocol version).
- Tarball integrity: `sha512-lubB5srgXxXwz9uVIJXdk4dm+CdKj7qfrGNHqFvlBtt4wrUb9413KBOJUpdUWTasJmQe9pYAa2rYNIl3yfW4Ag==`
- `messages.schema.json` sha256: `f38d9465faaa2920290f6d659fd88f8aa02e3789473a97a08625aab49d285d62`
- Dialect: JSON Schema draft 2020-12; the root is an Envelope, each message type is a `$defs` entry.
- Licence: MIT, Copyright (c) 2018 Cucumber Ltd and contributors (`LICENSE` beside this file).

To move the pin, replace both files from the new release, update this page and
`AshJourneys.Messages.protocol_version/0`; a test fails when the three disagree.
