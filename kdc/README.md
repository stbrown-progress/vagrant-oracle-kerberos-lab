# KDC VM Access

Use SSH/SFTP with a fixed forwarded port on localhost. This avoids VM IP changes.

## WinSCP settings

- Host: `127.0.0.1`
- Port: `2222`
- User: `vagrant`
- Password: `vagrant`

## CLI example

```bash
sftp -P 2222 vagrant@127.0.0.1
```
