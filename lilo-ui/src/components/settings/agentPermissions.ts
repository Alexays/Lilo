/** The host a user typed or pasted: "https://Shop.Example.com/cart" gives "shop.example.com"; "" when it names none. */
export function normalizeSite(input: string): string {
  const text = input.trim().toLowerCase();
  if (!text) return "";
  try {
    const host = new URL(text.includes("://") ? text : `https://${text}`).hostname.replace(/\.$/, "");
    return /^[a-z0-9.-]+$/.test(host) && host.includes(".") || host === "localhost" ? host : "";
  } catch {
    return "";
  }
}
