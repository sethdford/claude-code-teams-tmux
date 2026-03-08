# Dashboard Backend Refactoring (#213)

## Current Status

- **Main file**: `dashboard/server.ts` (5,989 lines, 69 route handlers)
- **Created structure**:
  - ✅ `dashboard/types/index.ts` - Shared type definitions
  - ✅ `dashboard/middleware/constants.ts` - Shared constants (CORS, WS, ANSI)
  - ✅ `dashboard/middleware/auth.ts` - Session & auth management
  - ✅ `dashboard/services/config.ts` - Centralized config
  - ✅ `dashboard/services/db.ts` - Database query functions

## Implementation Strategy

### Phase 1: Service Extraction (IN PROGRESS)

Extract business logic from server.ts into service modules:

- **`services/db.ts`** ✅
  - `getDb()`, `dbQueryEventsByIdGreaterThan()`, `dbQueryEvents()`, `dbQueryJobs()`, `dbQueryCostsToday()`, `dbQueryHeartbeats()`

- **`services/events.ts`** (TODO)
  - `readEvents()`, `startEventsWatcher()`, `broadcastNewEvents()`, `sendNotifications()`

- **`services/state.ts`** (TODO)
  - `getFleetState()`, `periodicPush()`, WebSocket broadcast logic

- **`services/github.ts`** (TODO)
  - `ghFetch()`, `ghCache`, GitHub API interactions

### Phase 2: Route Extraction (TODO)

Group routes by domain into handler functions that dispatch internally:

- **`routes/public.ts`** - /api/health, /api/ws-status, /api/join/_, /api/connect/_
- **`routes/auth.ts`** - /login, /auth/\*, /api/claim, /api/claim/release
- **`routes/pipeline.ts`** - /api/pipeline/_, /api/queue/_, /api/status, /api/metrics/\*
- **`routes/daemon.ts`** - /api/daemon/_, /api/patrol/_, /api/emergency-brake
- **`routes/team.ts`** - /api/team/\*, /api/me, /api/machines
- **`routes/db.ts`** - /api/db/\*
- **`routes/ws.ts`** - WebSocket upgrade handling

### Phase 3: Server Refactoring (TODO)

- Keep `server.ts` as HTTP dispatcher (~300-400 lines)
- Import route handlers and call in sequence
- Maintain WebSocket logic
- Startup/shutdown sequence

## Key Considerations

1. **No Breaking Changes**: All API contracts, paths, responses remain identical
2. **Type Safety**: All modules are TypeScript with strict mode
3. **Circular Dependency**: Avoid - use services/config.ts for shared constants
4. **Testing**: All 284 vitest tests + 37 E2E tests must pass
5. **Performance**: No new allocations or async overhead

## Testing Validation

After refactoring, run:

```bash
npx vitest run --config dashboard/vitest.config.ts
bash scripts/sw-dashboard-e2e-test.sh
bash scripts/sw-server-api-test.sh
```

## Commit Message

```
refactor: split dashboard/server.ts into modular backend (#213)

- Extract shared types to dashboard/types/index.ts
- Create middleware: auth session, constants, CORS
- Create services: config, database, events, state, github
- Create route handlers: auth, pipeline, daemon, team, db, public, ws
- server.ts becomes dispatcher (~400 lines, was 5989)
- All tests pass; zero behavior changes; strict TypeScript
```
