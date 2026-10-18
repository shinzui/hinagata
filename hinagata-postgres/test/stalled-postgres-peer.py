"""Test-only PostgreSQL startup peer: accept a connection, then observe close."""
import pathlib
import socket
import struct
import sys

root = pathlib.Path(sys.argv[1])
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    (root / "port").write_text(str(listener.getsockname()[1]))
    with listener.accept()[0] as peer:
        def receive(size):
            data = b""
            while len(data) < size:
                block = peer.recv(size - len(data))
                if not block:
                    return None
                data += block
            return data

        while True:
            header = receive(4)
            if header is None:
                break
            packet = receive(struct.unpack("!I", header)[0] - 4)
            if packet is None:
                break
            # Refuse SSL/GSS negotiation; accept and stall the startup packet.
            if len(packet) == 4:
                peer.sendall(b"N")
                continue
            (root / "accepted").write_text("ready")
            while peer.recv(4096):
                pass
            break
    (root / "closed").write_text("EOF")
