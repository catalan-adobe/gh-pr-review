### Approach

**What it does:** Reads each review round back from its hidden marker.

#### Important context

- The marker is written by the tool, never by the model.
- `lib/records.jq:300` reads it back.
- A review without a marker is rebuilt from its Markdown.
- Rounds by outsiders are not counted.

**Approach:** Sound

### Issues

#### 🚨 Critical (Must Fix Before Merge)

*(none found)*

#### ⚠️ Important (Should Fix)

*(none found)*

#### 💡 Minor (Nice to Have)

*(none found)*

<details><summary>Fixed since the last round (2)</summary>

- **F1 · `a.js:1`** — Fixed.
- **F2** — Fixed too.

</details>

### Assessment

**Ready to merge?** Yes
