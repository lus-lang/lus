---
name: "tcp_socket:starttls"
module: network.tcp
kind: function
since: 2.0.0
stability: stable
origin: lus
receiver: tcp_socket
params:
  - name: options
    type: table
    optional: true
returns: tcp_socket
---

Starts TLS over a connected TCP socket, as the client or as the server, waits for the handshake to end, and returns the same socket, which is now a TLS socket.

Protocols such as SMTP, IMAP, PostgreSQL, and Redis open a plain connection and switch to TLS after an exchange of plain text. A program runs that exchange with `send` and `receive`, then calls `starttls` on both ends. The timeout of the socket bounds every wait of the handshake.

For the client role, `options` is the table of client options that [`network.tls`](/manual/api#network.tls) describes, without `timeout`. `servername` has no default here, so a socket that verifies the server must name it.

For the server role, `options` holds `server = true` and the certificate of the server: `cert` and `key`, PEM text of its certificate chain and of its private key, with `password` for an encrypted key, or `certs`, a list of tables with `cert`, `key`, and `password`, one for each name. The server picks the certificate whose DNS names, or whose common name when it lists none, match the name that the client sends through SNI, and the first certificate for a client that sends none or a name that none carries. `alpn` lists the protocols that the server accepts, in its order of preference, and the server chooses the first of them that the client offers. A server that serves TLS from its first byte calls `starttls` right after `accept`. The server reads the certificates once for each options table, so a server that passes the same table to every connection parses them once, and a new table loads new certificates. [`tcp_socket:tlsinfo`](/manual/api#tcp_socket:tlsinfo) of a server socket reports the name that the client asked for.

On success the call returns the socket, whose `send` and `receive` then carry plain text through TLS. The socket must hold no received byte that no `receive` returned yet, since such bytes came before TLS and would read as protected data. A socket that holds one raises `"starttls: the socket holds data received before TLS started"`, and a socket that already uses TLS raises `"the socket already uses TLS"`. A missing `servername` with verification, a server without a certificate, a certificate or a key that does not parse, and an unknown option raise a `bad argument` error. A failed handshake raises the errors that `network.tls` lists and closes the socket. The method needs no permission beyond the one that opened the connection.

```lus nocheck
pledge("network")
local sock <close> = network.tcp.connect("mail.example.com", 587)
sock:settimeout(10)
sock:receive("*l")
sock:send("EHLO client.example.com\r\n")
repeat
    local line = vector.tostring(sock:receive("*l"))
until line:sub(4, 4) == " "
sock:send("STARTTLS\r\n")
sock:receive("*l")
sock:starttls({ servername = "mail.example.com" })
print(sock:tlsinfo().servername)   --> mail.example.com
```

The following server side of the same exchange reads its certificate once and upgrades each connection after the `STARTTLS` command.

```lus nocheck
pledge("network", "fs:read=/etc/mail/*")
local function read(path)
    local f <close> = io.open(path)
    return f:read("a")
end
local tls = { server = true, cert = read("/etc/mail/cert.pem"), key = read("/etc/mail/key.pem") }
local server <close> = network.tcp.bind("0.0.0.0", 587)
while true do
    local conn = server:accept()
    coroutine.detach(coroutine.create(function()
        conn:send("220 mail.example.com ESMTP\r\n")
        -- read EHLO and STARTTLS here, then:
        conn:send("220 2.0.0 Ready to start TLS\r\n")
        conn:starttls(tls)
        -- the session continues over TLS
    end))
end
```
