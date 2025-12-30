# Test Client VM Access

Use SSH/SFTP with a fixed forwarded port on localhost. This avoids VM IP changes.

## WinSCP settings

- Host: `127.0.0.1`
- Port: `2224`
- User: `vagrant`
- Password: `vagrant`

## CLI example

```bash
sftp -P 2224 vagrant@127.0.0.1
```
