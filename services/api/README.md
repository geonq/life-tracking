# API security and adapter boundary

This local API is read-only and serves explicitly labeled `Demo data` fixtures only. It has no authentication, persistence, connector credentials, or personal data and must not be exposed beyond a trusted local development environment. Production adapters must live behind the API boundary, obtain credentials from a server-side vault, normalize into the shared Zod contracts, and preserve source/provenance, timestamps, freshness, quality, and the constrained connector-state enum. Never infer live quota or health/finance values from these fixtures.
