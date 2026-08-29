import net from "node:net";
import os from "node:os";
import path from "node:path";

export const SOCKET_PATH = path.join(
  os.homedir(),
  "Library/Application Support/mem-agent/memagent.sock",
);

let nextId = 1;

/**
 * One newline-delimited JSON request per connection. Times out rather than
 * hanging so tool calls fail cleanly when the daemon is down.
 */
export function callDaemon(method, params = {}, timeoutMs = 3000) {
  return new Promise((resolve, reject) => {
    const id = nextId++;
    const socket = net.createConnection(SOCKET_PATH);
    let buffer = "";
    let settled = false;

    const fail = (message) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(new Error(message));
    };

    const timer = setTimeout(
      () => fail(`daemon timed out after ${timeoutMs}ms (method: ${method})`),
      timeoutMs,
    );

    socket.on("error", (err) => {
      clearTimeout(timer);
      fail(
        err.code === "ENOENT" || err.code === "ECONNREFUSED"
          ? `memagent daemon is not running (no socket at ${SOCKET_PATH}). Start it with \`memagent install\` or \`memagent run\`.`
          : `socket error: ${err.message}`,
      );
    });

    socket.on("connect", () => {
      socket.write(JSON.stringify({ id, method, params }) + "\n");
    });

    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      const nl = buffer.indexOf("\n");
      if (nl === -1) return;
      clearTimeout(timer);
      if (settled) return;
      settled = true;
      socket.end();
      try {
        const obj = JSON.parse(buffer.slice(0, nl));
        if (obj.error) {
          reject(new Error(`daemon error [${obj.error.code}]: ${obj.error.message}`));
        } else {
          resolve(obj.result);
        }
      } catch (err) {
        reject(new Error(`bad response from daemon: ${err.message}`));
      }
    });
  });
}
