interface Env {
  ASSETS: { fetch: (request: Request) => Promise<Response> };
}

const byteRange = (header: string, length: number): [number, number] | null => {
  const match = /^bytes=(?<start>\d*)-(?<end>\d*)$/u.exec(header);

  if (!match?.groups || length < 1) {
    return null;
  }

  const { start: rawStart, end: rawEnd } = match.groups;

  if (!rawStart) {
    const suffix = Number(rawEnd);

    return Number.isSafeInteger(suffix) && suffix > 0
      ? [Math.max(0, length - suffix), length]
      : null;
  }

  const start = Number(rawStart);
  const end = rawEnd ? Number(rawEnd) : length - 1;

  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(end) ||
    start >= length ||
    end < start
  ) {
    return null;
  }

  return [start, Math.min(end, length - 1) + 1];
};

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const path = new URL(request.url).pathname;

    if (
      !/^\/release-media\/\d+\.\d+\.\d+\/[a-z0-9-]+\.mp4$/u.test(path) ||
      !["GET", "HEAD"].includes(request.method)
    ) {
      return env.ASSETS.fetch(request);
    }

    const sourceHeaders = new Headers(request.headers);
    sourceHeaders.delete("Range");

    const source = await env.ASSETS.fetch(
      new Request(request, { headers: sourceHeaders })
    );

    if (source.status !== 200) {
      return source;
    }

    const headers = new Headers(source.headers);
    headers.set("Accept-Ranges", "bytes");
    const requested = request.headers.get("Range");
    const ifRange = request.headers.get("If-Range");

    if (
      !requested ||
      request.method === "HEAD" ||
      (ifRange &&
        ifRange !== headers.get("ETag") &&
        ifRange !== headers.get("Last-Modified"))
    ) {
      return new Response(source.body, { headers, status: 200 });
    }

    // Static assets ignore Range. These small release films need real partial responses for native seeking.
    const body = await source.arrayBuffer();
    const range = byteRange(requested, body.byteLength);

    if (!range) {
      headers.set("Content-Range", `bytes */${body.byteLength}`);
      headers.set("Content-Length", "0");

      return new Response(null, { headers, status: 416 });
    }

    const [start, end] = range;
    headers.set(
      "Content-Range",
      `bytes ${start}-${end - 1}/${body.byteLength}`
    );
    headers.set("Content-Length", String(end - start));

    return new Response(body.slice(start, end), { headers, status: 206 });
  },
};
