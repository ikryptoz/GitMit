export async function fetchGithubUser(username) {
    try {
        const resp = await fetch(`https://api.github.com/users/${username}`);
        return await resp.json();
    } catch (e) {
        console.error("Failed to fetch user info", e);
        return null;
    }
}

export async function searchGithubUsers(query) {
    if (!query || query.length < 2) return [];
    try {
        const resp = await fetch(`https://api.github.com/search/users?q=${encodeURIComponent(query)}&per_page=5`);
        const data = await resp.json();
        return data.items || [];
    } catch (e) {
        console.error("Search failed:", e);
        return [];
    }
}
