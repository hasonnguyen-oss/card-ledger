#!/usr/bin/env python3
"""Scrape PriceCharting for every priced item in data.json and write prices.json.

This runs in GitHub Actions, where outbound network access works. The weekly
Claude routine cannot reach PriceCharting from its sandbox (all egress is
blocked), so it reads the prices.json this produces instead of scraping.

Output shape:

    {
      "generatedAt": "2026-09-21",
      "source": "PriceCharting",
      "items": {
        "<id>": {
          "headline": 174.46,            # ungraded/loose market price
          "market": 175.0,               # mean of the 3 most recent sales, else headline
          "basis": "mean3" | "headline",
          "samples": [{date, price, title, venue}, ...],
          "venues": ["TCGPlayer"],       # distinct venues across those samples
          "url": "https://..."
        },
        "<id>": {"error": "..."}         # anything that could not be priced
      }
    }

Items are never silently dropped: every id in data.json with a priceUrl gets
either a price or an explicit error.
"""

import datetime
import json
import os
import random
import re
import sys
import time
import urllib.error
import urllib.request

UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)
TIMEOUT = 30
RETRIES = 3
DELAY = (1.5, 3.0)  # polite pause between products

# <td class="date">2026-09-21</td> ... <span class="js-price">$173.00</span>
ROW_RE = re.compile(
    r'<tr id="(?P<vid>[a-z]+)-[^"]*">(?P<body>.*?)</tr>',
    re.S,
)
DATE_RE = re.compile(r'<td class="date">\s*([0-9]{4}-[0-9]{2}-[0-9]{2})\s*</td>')
PRICE_RE = re.compile(r'<span class="js-price">\s*\$([0-9][0-9,]*\.?[0-9]*)\s*</span>')
TITLE_RE = re.compile(r'<td class="title">(.*?)</td>', re.S)
BRACKET_RE = re.compile(r'\[([A-Za-z]+)\]')
USED_PRICE_RE = re.compile(
    r'id="used_price">\s*<span class="price js-price">\s*\$([0-9][0-9,]*\.?[0-9]*)\s*</span>',
    re.S,
)


def money(text):
    return float(text.replace(",", ""))


def strip_tags(html):
    text = re.sub(r"<[^>]+>", " ", html)
    text = (
        text.replace("&amp;", "&")
        .replace("&#43;", "+")
        .replace("&quot;", '"')
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
    )
    return re.sub(r"\s+", " ", text).strip()


def fetch(url):
    last = None
    for attempt in range(RETRIES):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.read().decode("utf-8", errors="replace")
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as exc:
            last = exc
            if attempt < RETRIES - 1:
                time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"fetch failed after {RETRIES} tries: {last}")


def ungraded_block(html):
    """Isolate the Ungraded completed-sales tab, so graded rows never leak in."""
    start = html.find('completed-auctions-used" style=')
    if start < 0:
        start = html.find('id="completed-auctions-used"')
    if start < 0:
        return ""
    # Stop at the next completed-auctions tab, whatever it is.
    nxt = html.find('id="completed-auctions-', start + 10)
    return html[start:nxt] if nxt > 0 else html[start:]


def parse(html, url, bucket):
    """Price one product page.

    Holdings (`lots`) want precision, so they use the mean of the 3 most recent
    completed sales. The watchlist uses PriceCharting's headline figure, which is
    its own blend of recent sales - that is the existing methodology and keeping
    it means this week's numbers stay comparable with previous weeks'.
    """
    out = {"url": url, "bucket": bucket}

    m = USED_PRICE_RE.search(html)
    if m:
        out["headline"] = money(m.group(1))

    samples = []
    for row in ROW_RE.finditer(ungraded_block(html)):
        body = row.group("body")
        d = DATE_RE.search(body)
        p = PRICE_RE.search(body)
        if not (d and p):
            continue
        t = TITLE_RE.search(body)
        title = strip_tags(t.group(1)) if t else ""
        venue = row.group("vid")
        b = BRACKET_RE.search(title)
        if b:
            venue = b.group(1)
        elif venue:
            venue = {"tcgplayer": "TCGPlayer", "ebay": "eBay"}.get(venue, venue)
        samples.append(
            {"date": d.group(1), "price": money(p.group(1)), "title": title, "venue": venue}
        )

    # Rows render newest-first, but sort defensively rather than trusting order.
    samples.sort(key=lambda s: s["date"], reverse=True)
    top = samples[:3]

    if len(top) == 3:
        out["mean3"] = round(sum(s["price"] for s in top) / 3, 2)

    if bucket == "lots" and "mean3" in out:
        out["market"], out["basis"] = out["mean3"], "mean3"
    elif "headline" in out:
        out["market"], out["basis"] = out["headline"], "headline"
    elif "mean3" in out:
        out["market"], out["basis"] = out["mean3"], "mean3"
    else:
        raise RuntimeError("no sales rows and no headline price found")

    out["samples"] = top
    out["venues"] = sorted({s["venue"] for s in top if s.get("venue")})
    out["salesAvailable"] = len(samples)
    return out


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(root, "data.json"), encoding="utf-8") as fh:
        data = json.load(fh)

    today = datetime.date.today().isoformat()
    work, skipped = [], {}
    for bucket in ("lots", "watch"):
        for row in data.get(bucket) or []:
            url = row.get("priceUrl")
            if bucket == "lots" and row.get("status") == "sold":
                skipped[row["id"]] = "sold"
            elif (row.get("releaseDate") or "") > today:
                skipped[row["id"]] = f"unreleased (releases {row['releaseDate']})"
            elif not url:
                skipped[row["id"]] = "no priceUrl recorded"
            elif "/search-products" in url:
                # A search URL is not a product page, so there is no stable
                # sales table to read. Needs a real product URL to be priced.
                skipped[row["id"]] = "priceUrl is a search URL, not a product page"
            else:
                work.append((row["id"], url, bucket))

    print(f"pricing {len(work)} items", flush=True)
    items, failures = {}, 0
    for i, (item_id, url, bucket) in enumerate(work, 1):
        try:
            items[item_id] = parse(fetch(url), url, bucket)
            got = items[item_id]
            print(f"  [{i}/{len(work)}] {item_id}: ${got['market']} ({got['basis']})", flush=True)
        except Exception as exc:  # noqa: BLE001 - one bad page must not sink the run
            items[item_id] = {"error": str(exc), "url": url}
            failures += 1
            print(f"  [{i}/{len(work)}] {item_id}: ERROR {exc}", flush=True)
        if i < len(work):
            time.sleep(random.uniform(*DELAY))

    priced = len(work) - failures
    # A total wipeout means the scraper broke or PriceCharting changed shape.
    # Better to fail loudly than to publish an empty file the routine would trust.
    if work and priced == 0:
        sys.exit("every item failed to price - refusing to write prices.json")

    payload = {
        "generatedAt": today,
        "source": "PriceCharting",
        "method": (
            "Mean of the 3 most recent completed ungraded sales where available, "
            "else the headline ungraded price. Venue recorded per sample."
        ),
        "priced": priced,
        "failed": failures,
        "skipped": skipped,
        "items": items,
    }
    out_path = os.path.join(root, "prices.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=1, sort_keys=True)
        fh.write("\n")
    print(f"wrote prices.json: {priced} priced, {failures} failed", flush=True)


if __name__ == "__main__":
    main()
