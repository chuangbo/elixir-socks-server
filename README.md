# Socks

A EXPERIMENTAL socks5 server in Elixir. [WIP]

It's my personal practice project of learning Elixir. Use at your own risks.

## Examples

```sh
$ # Start the server
$ mix run --no-halt
$ # resolve hostname from local
$ curl -v --proxy 'socks5://localhost' google.com
$ # resolve hostname from remote
$ curl -v --proxy 'socks5h://localhost' google.com
```

## FIXME

**What I havn't figured out yet**

- ~~Too many nested cases?~~
- ~~How to run it properly?~~
- ~~How to use Application / Task / Supervisor? How to spawn two forwarding processes for each client properly?~~
- ~~How to handle errors properly?~~
- ~~How to close connection properly?~~
- Specs?
- Tests?
- Connection pool?
- Timeout?
- Proxy to itself?
- GenServer?
- ???

## TODO

- Full protocal support?
- Socks4?
- Shadowsocks?
- tunnel? (localtunnel or ngrok)
