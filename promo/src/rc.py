# 和测试模式的手边通话：python3 rc.py <socket> '<json>'
import socket, json, sys
def call(path, o, timeout=10):
    s = socket.socket(socket.AF_UNIX); s.settimeout(timeout); s.connect(path)
    s.sendall((json.dumps(o) + "\n").encode()); b = b""
    while not b.endswith(b"\n"): b += s.recv(65536)
    return json.loads(b)
if __name__ == "__main__": print(call(sys.argv[1], json.loads(sys.argv[2])))
