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

Starts TLS over a connected TCP socket as the client, waits for the handshake to end, and returns the same socket, which is now a TLS socket.

Protocols such as SMTP, IMAP, PostgreSQL, and Redis open a plain connection and switch to TLS after an exchange of plain text. A program runs that exchange with `send` and `receive`, then calls `starttls`. `options` is the table of client options that [`network.tls`](/manual/api#network.tls) describes, without `timeout`, since the timeout of the socket bounds the handshake. `servername` has no default here, so a socket that verifies the server must name it.

On success the call returns the socket, whose `send` and `receive` then carry plain text through TLS. The socket must hold no received byte that no `receive` returned yet, since such bytes came before TLS and would read as protected data. A socket that holds one raises `"starttls: the socket holds data received before TLS started"`, and a socket that already uses TLS raises `"the socket already uses TLS"`. A missing `servername` with verification raises a `bad argument` error. A failed handshake raises the errors that `network.tls` lists and closes the socket. The method needs no permission beyond the one that opened the connection.

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
