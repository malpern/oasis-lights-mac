# Contributing

Contributions are welcome, especially protocol evidence for additional Oasis
products, incoming state reports, effects, and generalized setup.

Please keep evidence boundaries explicit:

- Label behavior as observed, decoded, inferred, or unverified.
- Do not publish credentials, account or node identifiers, Mesh keys,
  proof-of-possession values, Matter setup data, or personal routines.
- Do not submit vendor binaries or decompiled vendor source.
- Do not probe destructive management commands.
- Add a focused regression test for every newly supported payload shape.

Run the protocol tests before opening a pull request:

```sh
python3 -m unittest discover -s Research -p 'test_*.py'
```

