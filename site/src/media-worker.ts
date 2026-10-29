interface Env {
  ASSETS: { fetch: (request: Request) => Promise<Response> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (
      !new URL(request.url).pathname.endsWith(".mp4") ||
      !["GET", "HEAD"].includes(request.method)
    ) {
      return env.ASSETS.fetch(request);
    }

    const requestedRange = request.headers.get("Range");
    const requestHeaders = new Headers(request.headers);
    requestHeaders.delete("Range");
    requestHeaders.delete("If-Range");

    const full = await env.ASSETS.fetch(
      new Request(request, { headers: requestHeaders })
    );

    if (full.status !== 200) {
      return full;
    }

    const headers = new Headers(full.headers);
    headers.set("Accept-Ranges", "bytes");
    const complete = () => new Response(full.body, { headers, status: 200 });

    const range = requestedRange
      ?.trim()
      .match(/^bytes=(?<start>\d*)-(?<end>\d*)$/u)?.groups;

    const validator = request.headers.get("If-Range");

    if (request.method === "HEAD" || !range || !(range.start || range.end)) {
      return complete();
    }

    if (
      validator &&
      validator !== full.headers.get("ETag") &&
      validator !== full.headers.get("Last-Modified")
    ) {
      return complete();
    }

    if (
      ![range.start, range.end].every(
        (value) => !value || Number.isSafeInteger(Number(value))
      )
    ) {
      return complete();
    }

    const bytes = await full.arrayBuffer();
    const size = bytes.byteLength;

    const start = range.start
      ? Number(range.start)
      : Math.max(0, size - Number(range.end));

    const end =
      range.start && range.end
        ? Math.min(Number(range.end), size - 1)
        : size - 1;

    if (start >= size || start > end) {
      headers.set("Content-Range", `bytes */${size}`);
      headers.set("Content-Length", "0");

      return new Response(null, { headers, status: 416 });
    }

    headers.set("Content-Range", `bytes ${start}-${end}/${size}`);
    headers.set("Content-Length", String(end - start + 1));

    return new Response(bytes.slice(start, end + 1), { headers, status: 206 });
  },
};
