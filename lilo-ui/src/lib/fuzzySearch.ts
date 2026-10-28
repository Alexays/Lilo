interface FuzzyMatch {
	score: number;
	highlights: number[]; // character indices that matched
}

const WORD_SEPARATOR = /[\s\-_./]/;

// Cheap in-order subsequence test over target[start, end) with a remaining-length
// early-exit; runs before any highlight allocation so non-matches cost no garbage.
function isSubsequence(query: string, target: string, start: number, end: number): boolean {
	let qi = 0;
	for (let ti = start; ti < end && qi < query.length; ti++) {
		if (end - ti < query.length - qi) return false;
		if (target[ti] === query[qi]) qi++;
	}
	return qi >= query.length;
}

// Scores `query` inside target[start, end): a verbatim occurrence (word start first)
// wins over the greedy leftmost subsequence, which would scatter it.
function matchRange(query: string, target: string, start: number, end: number): FuzzyMatch | null {
	const n = query.length;
	let at = -1;
	for (let i = target.indexOf(query, start); i >= 0 && i + n <= end; i = target.indexOf(query, i + 1)) {
		if (at < 0) at = i;
		if (i === start || WORD_SEPARATOR.test(target[i - 1])) {
			at = i;
			break;
		}
	}

	const highlights: number[] = new Array(n);
	if (at >= 0) {
		for (let qi = 0; qi < n; qi++) highlights[qi] = at + qi;
	} else {
		if (!isSubsequence(query, target, start, end)) return null;
		for (let ti = start, qi = 0; qi < n; ti++) {
			if (target[ti] === query[qi]) highlights[qi++] = ti;
		}
	}

	let score = 0;
	let consecutive = 0;
	for (let qi = 0; qi < n; qi++) {
		const ti = highlights[qi];
		const wordStart = ti === start || WORD_SEPARATOR.test(target[ti - 1]);
		consecutive = qi > 0 && highlights[qi - 1] === ti - 1 ? consecutive + 1 : 1;
		score += consecutive * 2;
		if (wordStart) score += 5;
		// A jump into the middle of a word costs more than the char earns, so a long query
		// scattered letter by letter across a title scores below the threshold.
		else if (qi > 0 && consecutive === 1) score -= 3;
		if (ti - start === qi) score += 3;
	}
	// Log-scaled so a long field still ranks a strong match above a weak short one.
	score -= Math.log2(end - start - n + 1) * 2;

	return { score, highlights };
}

// In-order match of lowercased `query` in lowercased `target`. With `split` >= 0, the fields
// before and after that separator score apart (best kept); the whole only for a spanning query.
export function fuzzyMatch(query: string, target: string, split = -1): FuzzyMatch | null {
	if (!query) return { score: 1, highlights: [] };

	if (!isSubsequence(query, target, 0, target.length)) return null;
	if (split < 0) return matchRange(query, target, 0, target.length);

	const first = matchRange(query, target, 0, split);
	const second = matchRange(query, target, split + 1, target.length);
	if (first && second) return first.score >= second.score ? first : second;
	if (first || second) return first ?? second;

	// A query spanning both fields needs each word to score in one of them: otherwise letters
	// picked across a long title and URL (the space landing on the separator) pass as a match.
	for (const word of query.split(/\s+/)) {
		if (!word) continue;
		const inFirst = matchRange(word, target, 0, split);
		const inSecond = matchRange(word, target, split + 1, target.length);
		if (Math.max(inFirst?.score ?? -Infinity, inSecond?.score ?? -Infinity) < 0) return null;
	}
	return matchRange(query, target, 0, target.length);
}

// Matches sorted by score, then `tiebreak`, then source order. `accessor` returns lowercased
// text; `splitAt` gives its field separator index (see fuzzyMatch). `boost` adds to the score of
// a match that passed `minScore`, so it reorders matches without admitting weak ones.
export function fuzzySearch<T>(
	items: T[],
	query: string,
	accessor: (item: T) => string,
	limit = 10,
	minScore = -Infinity,
	tiebreak?: (lhs: T, rhs: T) => number,
	splitAt?: (item: T) => number,
	boost?: (item: T) => number,
): (FuzzyMatch & { data: T })[] {
	if (!query.trim()) return [];

	const lowerQuery = query.toLowerCase();
	const results: (FuzzyMatch & { data: T })[] = [];

	for (let i = 0; i < items.length; i++) {
		const match = fuzzyMatch(lowerQuery, accessor(items[i]), splitAt ? splitAt(items[i]) : -1);
		if (match && match.score >= minScore) {
			if (boost) match.score += boost(items[i]);
			results.push({ ...match, data: items[i] });
		}
	}

	results.sort((a, b) => (b.score - a.score) || (tiebreak?.(a.data, b.data) ?? 0));
	return results.slice(0, limit);
}
