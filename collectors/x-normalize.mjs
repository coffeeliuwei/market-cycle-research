function asText(value) {
  if (typeof value === 'string') return value;
  if (!value || typeof value !== 'object') return '';
  return [
    value.text,
    value.fullText,
    value.title,
    value.description,
    value.article?.title,
    value.article?.text,
    value.article?.description,
    value.quotedTweet?.text,
    value.quotedTweet?.fullText,
    value.retweetedTweet?.text,
    value.retweetedTweet?.fullText,
  ].filter((item) => typeof item === 'string').join(' ');
}

export function normalizeTwitterPayload(payload, limit = 10) {
  let items = [];
  if (Array.isArray(payload)) items = payload;
  else if (Array.isArray(payload?.data)) items = payload.data;
  else if (Array.isArray(payload?.items)) items = payload.items;
  else if (Array.isArray(payload?.tweets)) items = payload.tweets;
  return items.slice(0, limit);
}

export function filterTimelineItems(items, query, limit = 10) {
  const assetTerms = [...String(query || '').matchAll(/\$([A-Za-z0-9_]+)/g)].map(m=>m[1].toLowerCase());
  const baseTerms = assetTerms.length ? assetTerms : String(query || '')
    .toLocaleLowerCase()
    .match(/[\p{L}\p{N}_-]{2,}/gu) || [];
  const aliases = {
    bitcoin: ['btc', 'xbt'],
    ethereum: ['eth'],
    solana: ['sol'],
    cryptocurrency: ['crypto'],
  };
  const uniqueTerms = [...new Set(baseTerms.flatMap((term) => [term, ...(aliases[term] || [])]))];
  if (!uniqueTerms.length) return [];
  return items.filter((item) => {
    const haystack = asText(item).toLocaleLowerCase();
    const words = new Set(haystack.match(/[\p{L}\p{N}_-]{2,}/gu) || []);
    return uniqueTerms.some((term) => term.length <= 4 ? words.has(term) : haystack.includes(term));
  }).slice(0, limit);
}
