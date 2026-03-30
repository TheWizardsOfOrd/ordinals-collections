### Ordinals Collections

Curated on-chain data of Ordinals collections.

### Submitting a Collection

[**Open an issue**](../../issues/new?template=submit-collection.yml) with your collection details. Fill out the form and CI will automatically validate your submission. A maintainer will review and merge it.

### Data Format

Each entry includes:

- **name**: collection name
- **type**: `gallery` or `parent`
- **id** or **ids**: gallery uses a single `id`, parent/child uses an `ids` array
- **slug**: URL-friendly identifier for the collection

**Example**

```json
[
  {
    "name": "Quantum Cats",
    "type": "parent",
    "ids": ["0e383b8af3e7f8767bc9ec0a48fbf837d82b0d537f4dbc7a8853e6828112ea41i0"],
    "slug": "quantum_cats"
  },
  {
    "name": "The Wizards of Ord",
    "type": "gallery",
    "id": "b8a6c9e946f0beaa9cbb4d6cc9f9388ae71d0f93c0215b8a85595db69949e64ci0",
    "slug": "wizards"
  }
]
```

### Inclusion Criteria

- **Parent/child**: All children must share the same parent(s)
- **Galleries**: Inscription IDs must exactly match the collection data on the most popular ordinals marketplace at the time
- **Traits**: If included, should closely resemble marketplace trait data

### How to Create Galleries

- [ord/ord](https://github.com/ordinals/ord) — Ordinals reference client
- [The Wizards of Ord Inscriber](https://inscribe.dev) — Supports creating galleries directly from [Magic Eden collection JSON files](legacy/collections) ([demo](https://x.com/lifofifo/status/2021279780667036069))

### Legacy Data

The [`legacy/`](legacy/) directory contains collection data originally sourced from Magic Eden, including per-collection inscription lists and metadata. This can be useful as reference when submitting new entries.

### Credits

Joint initiative by **The Wizards of Ord**
