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
    const etag = headers.get("ETag");
    const length = Number(headers.get("Content-Length"));

    // RFC 9110: anything but a single byte range is ignored, and a weak validator never matches If-Range.
    if (
      !requested ||
      !/^bytes=\d*-\d*$/u.test(requested) ||
      request.method === "HEAD" ||
      !source.body ||
      !Number.isSafeInteger(length) ||
      (ifRange &&
        (ifRange.startsWith("W/") || ifRange !== etag) &&
        ifRange !== headers.get("Last-Modified"))
    ) {
      return new Response(source.body, { headers, status: 200 });
    }

    const range = byteRange(requested, length);

    if (!range) {
      headers.set("Content-Range", `bytes */${length}`);
      headers.set("Content-Length", "0");

      return new Response(null, { headers, status: 416 });
    }

    // Static assets ignore Range: stream the requested bytes through instead of buffering the film.
    const [start, end] = range;
    let offset = 0;
    const body = source.body.pipeThrough(
      new TransformStream<Uint8Array, Uint8Array>({
        transform(chunk, controller) {
          const from = Math.max(start - offset, 0);
          const to = Math.min(end - offset, chunk.byteLength);
          offset += chunk.byteLength;
          if (from < to) {
            controller.enqueue(chunk.subarray(from, to));
          }
          if (offset >= end) {
            controller.terminate();
          }
        },
      })
    );
    headers.set("Content-Range", `bytes ${start}-${end - 1}/${length}`);
    headers.set("Content-Length", String(end - start));

    return new Response(body, { headers, status: 206 });
  },
};
