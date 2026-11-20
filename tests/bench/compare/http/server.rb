# HTTP server benchmark: answers GET / with a small JSON document. The
# standard library has TCPServer, so this is a small HTTP/1.1 loop with
# one thread per keep-alive connection.
require "socket"
require "json"

port = (ARGV[0] || 8080).to_i
server = TCPServer.new("127.0.0.1", port)
server.listen(1024)

def handle(client, lock, counter_ref)
  loop do
    line = client.gets("\r\n") or break
    method, path, _ = line.split(" ", 3)
    length = 0
    close = false
    while (header = client.gets("\r\n"))
      break if header == "\r\n"
      name, value = header.split(":", 2)
      case name.downcase
      when "content-length" then length = value.to_i
      when "connection" then close = value.strip.casecmp?("close")
      end
    end
    client.read(length) if length > 0
    if method == "GET" && path == "/"
      n = lock.synchronize { counter_ref[0] += 1 }
      body = JSON.generate({ message: "hello", n: n })
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
    else
      client.write("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 10\r\n\r\nnot found\n")
    end
    break if close
  end
rescue IOError, SystemCallError
ensure
  client.close
end

counter_ref = [0]
lock = Mutex.new
loop do
  client = server.accept
  Thread.new(client) { |c| handle(c, lock, counter_ref) }
end
