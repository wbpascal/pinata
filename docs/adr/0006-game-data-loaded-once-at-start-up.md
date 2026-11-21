# Game data is loaded once at start-up and never reloaded

A node parses its data directory when it starts: SHN tables (client data tables and server-only ones) and the CSV server data tables. Each table is stored write-once in `persistent_term` as a map from key to row, plus the secondary indexes its schema declares. One boundary, `GameData`, owns loading and exposes look-up functions; no part reads `persistent_term` directly. A node loads the union of the tables its parts declare, before any part accepts a connection, so in single-node mode all three parts share one copy. Changing data means restarting the node.

We chose start-up loading over build-time generated modules because generated modules tie a release to one data set and make an administrator recompile to change a drop rate. We chose `persistent_term` over ETS because reads are copy-free from every process, there is no owner process, and named ETS tables are already banned (ADR 0002). Its cost is that replacing an entry forces a global garbage collection; that is why there is no hot reload. The original server has none either.

Every table has a schema module: a struct with `@enforce_keys`, column names and types, the key, and references to other tables. It is written in the milestone that first uses the table; a table without a schema is not loaded, which also keeps memory down. The loader checks the schema against the file header and every row. A structural mismatch (column, type, duplicate key) always stops the start-up, with all problems reported together.

References between tables are checked at load too, strict by default. The setting `data.strict_references = false` turns dangling references into warnings (table, row key, column) so an original data set can be brought in before it is cleaned. Because a node may therefore run with dangling references, following a reference always returns a tagged result, in strict mode as well.

Text columns stay raw bytes in the client's legacy code page and are never converted to UTF-8 at load: the client must get the original bytes back. Code that logs or compares such text converts at that point.

Geometry (`BlockInfo/`, `AreaBMP/`) is not loaded with the tables. A field map's process starts with its Zone node, but its geometry is read when the first player enters, held as one binary per map, and kept until the node stops; the node only checks at start that the file exists; loading all of it would cost up to 190 MB for an offline player who visits three maps.

## Consequences

- A typo in a data file stops the node at start, not a player hours later. In return, every data change costs a restart; hot reloading is a separate investigation ([issue 23](https://github.com/wbpascal/pinata/issues/23)).
- The loader computes the MD5 of each of the 49 checksummed client data tables from the raw file. The 14 `View/` tables are hashed and never parsed. Whether a client mismatch is enforced is not decided here.
- In multi-node mode every node hashes its whole data directory, and WorldManager refuses a Zone node whose digest differs. Single-node mode skips this.
- Text from data tables is not valid UTF-8 in general. The technical documentation must say so where it describes game data, because printing or pattern-matching it as a string looks like corruption.
- Loader and schema tests run against the original data set in `Files/`, imported into a temporary data directory per test run; hand-written fixtures cover error cases only. The test suite therefore needs the repo's `Files/` folder.
- Parse time and decoded memory size were not measured when this was decided; the first milestone that loads tables measures both.
