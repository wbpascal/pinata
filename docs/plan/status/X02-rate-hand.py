# Hand ratings of X02 (read by X02-rate.py; plain Python, executed in its namespace).
# OVERRIDE[(item, § number or heading text)] = (rating, reason, what would raise it)
# CAPS: (item, regex on the § number, highest rating allowed, reason, what would raise it)
# Part 2: Login, WM, shared library, DB servers. Part 3 adds the zone documents.

OVERRIDE.update({
    # capture-validation §2.1: 1 365 packets (batch 1) parsed with no resync; the long form appears exactly for
    # bodies >= 256 bytes; batch 2 decodes all seven captures with 0 issues, links included (§7.1).
    ('S02', '1.7'): ('high', 'receive framing: every captured stream (client and server links) parses with no resync '
                     '(capture-validation §2.1, §7.1); buffer growth and error paths are code only', ''),
    ('S02', '1.8'): ('high', 'frame builder: short / long header of every captured Login and WM send matches '
                     '(capture-validation §2.1); pool exhaustion paths are code only', ''),
    # capture-validation §2.4: Login sent no heartbeat in any capture (the client polls 0x0C1B every 10 s).
    ('L01', '1.6'): ('medium', 'the 30 s / close rule is read in code and seen on the WM and the zone only; the Login '
                     'copy never fired in a capture (capture-validation §2.4)', 'scenario: sit on the login screen '
                     'before the world list (no 0x0C1B poll) for 60 s'),
})

CAPS += [
    # Procedures without source in any backup: the capture of the caller's packet does not show the body.
    ('D06', r'^[2-7](\.|$)', 'medium', 'procedure body inferred from the binds and the caller (no source in a backup); '
     'a captured request shows the call, not what the database does', 'DB setup + capture of the answer (part 9), or the '
     'original procedure source'),
]
