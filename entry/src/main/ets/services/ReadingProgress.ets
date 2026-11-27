import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * Reading progress and reader settings, persisted with `preferences`.
 *
 * One store, one key per file (`f:<path>`) holding a small JSON blob, plus a
 * global `fontSize`. Writes are debounced by the caller; this layer just does
 * the round trip and never throws into the UI.
 */
export class ReadingState {
  offset: number = 0;
  fontSize: number = 11;
  updatedAt: number = 0;
}

const STORE_NAME: string = 'watch_reading';
let store: preferences.Preferences | null = null;

async function getStore(ctx: common.UIAbilityContext): Promise<preferences.Preferences | null> {
  if (store !== null) {
    return store;
  }
  try {
    store = await preferences.getPreferences(ctx, { name: STORE_NAME });
    return store;
  } catch (e) {
    hilog.warn(0x0100, 'WatchProgress', 'open store failed: %{public}s', `${(e as Error).message}`);
    return null;
  }
}

export async function loadReading(ctx: common.UIAbilityContext, key: string): Promise<ReadingState> {
  const out: ReadingState = new ReadingState();
  const p: preferences.Preferences | null = await getStore(ctx);
  if (p === null) {
    return out;
  }
  try {
    const raw: preferences.ValueType = await p.get(`f:${key}`, '');
    if (typeof raw === 'string' && raw.length > 0) {
      const obj: ReadingState = JSON.parse(raw) as ReadingState;
      out.offset = typeof obj.offset === 'number' ? obj.offset : 0;
      out.fontSize = typeof obj.fontSize === 'number' ? obj.fontSize : 11;
      out.updatedAt = typeof obj.updatedAt === 'number' ? obj.updatedAt : 0;
    }
    const fsRaw: preferences.ValueType = await p.get('fontSize', 11);
    if (typeof fsRaw === 'number') {
      out.fontSize = fsRaw;
    }
  } catch (e) {
    hilog.warn(0x0100, 'WatchProgress', 'read failed: %{public}s', `${(e as Error).message}`);
  }
  return out;
}

export async function saveReading(ctx: common.UIAbilityContext, key: string, state: ReadingState): Promise<void> {
  const p: preferences.Preferences | null = await getStore(ctx);
  if (p === null) {
    return;
  }
  try {
    state.updatedAt = Date.now();
    await p.put(`f:${key}`, JSON.stringify(state));
    await p.put('fontSize', state.fontSize);
    await p.flush();
  } catch (e) {
    hilog.warn(0x0100, 'WatchProgress', 'write failed: %{public}s', `${(e as Error).message}`);
  }
}
