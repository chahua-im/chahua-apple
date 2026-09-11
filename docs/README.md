# Backend API Documentation

you can fetch the backend API documentation from the following URL:
```
https://wchat.codetector.org/_api/api-docs/openapi.json
```
use
```bash
curl "https://wchat.codetector.org/_api/api-docs/openapi.json" -o openapi.json
```

## Architecture

- [Realtime messaging architecture](arch/realtime-messaging.md)
- [Outbound queue architecture](arch/outbound-queue.md) — main-app blocked-tail composition, native image preparation/uploads, FIFO delivery and durable revocation boundaries.
