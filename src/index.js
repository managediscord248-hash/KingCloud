export default {
  async fetch(request, env) {
    if (request.method !== "GET") {
      return new Response("Method Not Allowed", { status: 405 });
    }

    const url = new URL(request.url);

    if (url.pathname !== "/az-panel.sh") {
      return new Response("Not Found", { status: 404 });
    }

    const githubURL =
      "https://api.github.com/repos/managediscord248-hash/KingCloud/contents/az-panel.sh?ref=main";

    const response = await fetch(githubURL, {
      headers: {
        "Accept": "application/vnd.github.raw+json",
        "Authorization": `Bearer ${env.GITHUB_TOKEN}`,
        "User-Agent": "KingCloud-Installer"
      }
    });

    if (!response.ok) {
      return new Response("Failed to fetch AZ Panel", {
        status: 502
      });
    }

    return new Response(response.body, {
      status: 200,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Cache-Control": "no-store"
      }
    });
  }
};
