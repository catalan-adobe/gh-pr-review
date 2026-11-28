### Round 3 · since round 2
1 fixed · 2 still open · 1 regressed · 1 new · 1 declined · 1 for later · open blocking: 4 (was 3)

### Strengths

- **`src/api.ts:120`** — The handler now rejects unsigned payloads early.

### Issues

The findings that are open now: earlier findings still open or regressed, then new ones, by severity.

#### 🚨 Critical (Must Fix Before Merge)

- **F1 · `a.ts:1`** — Still trusts the payload when the header is empty.
  - The fix checks the header's presence, not its value.

#### ⚠️ Important (Should Fix)

- **F5 · [e.ts:5]** — Retries are still unbounded on timeouts.
- **F2** · `b.ts:2` — The pool leak is back in the error path.
- **[d.ts:2]** — The new retry loop has no upper bound.

#### 💡 Minor (Nice to Have)

*(none found)*

<details><summary>Fixed since the last round (2)</summary>

- **F4** — The helper now closes the pool.
- **F3** — declined: "Kept on purpose until the v2 API ships" (@bob)

</details>

<details>
<summary>Later (1)</summary>

- **[f.ts:6]** — The old helper is slow; it can wait for the cache rework.

</details>

### Recommendations

- Share one retry helper.

### Assessment

**Ready to merge?** No

**Reasoning:** Two blockers remain.
