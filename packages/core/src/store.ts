import { readdir, readFile, rename } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { isAbsolute, join } from 'node:path'
import { atomicWriteJson, appendLineDurable, ensureDir, readJsonFile } from './durable.js'
import { OrbitError } from './errors.js'
import { Mutex } from './mutex.js'
import type {
  CheckRecord,
  CoverageFile,
  DisputesFile,
  FindingsFile,
  MembersFile,
  TaskEvent,
  TaskState,
  WorkUnitsFile,
} from './types.js'

export interface TaskFiles {
  state: TaskState
  members: MembersFile
  workUnits: WorkUnitsFile
  findings: FindingsFile
  disputes: DisputesFile
  coverage: CoverageFile
}

type Clock = () => Date

/**
 * Single durable write entry for one task directory. All mutations are
 * serialized in-process and every file is replaced atomically.
 */
export class TaskStore {
  readonly dir: string
  private readonly mutex = new Mutex()
  private readonly clock: Clock
  private lastSeq = 0

  private constructor(dir: string, clock: Clock) {
    this.dir = dir
    this.clock = clock
  }

  static tasksRoot(projectRoot: string): string {
    return join(projectRoot, '.orbit', 'tasks')
  }

  static async create(projectRoot: string, id: string, files: TaskFiles, clock: Clock = () => new Date()): Promise<TaskStore> {
    const tasksDir = TaskStore.tasksRoot(projectRoot)
    await ensureDir(tasksDir)
    const finalDir = join(tasksDir, id)
    if (existsSync(finalDir)) {
      throw new OrbitError('duplicate', `task directory already exists: ${finalDir}`)
    }
    const tempDir = join(tasksDir, `.tmp-${id}`)
    await ensureDir(tempDir)
    await atomicWriteJson(join(tempDir, 'state.json'), files.state)
    await atomicWriteJson(join(tempDir, 'members.json'), files.members)
    await atomicWriteJson(join(tempDir, 'work-units.json'), files.workUnits)
    await atomicWriteJson(join(tempDir, 'findings.json'), files.findings)
    await atomicWriteJson(join(tempDir, 'disputes.json'), files.disputes)
    await atomicWriteJson(join(tempDir, 'requirement-coverage.json'), files.coverage)
    await ensureDir(join(tempDir, 'checks'))
    const createdAt = files.state.createdAt
    await appendLineDurable(
      join(tempDir, 'events.jsonl'),
      JSON.stringify({ seq: 1, at: createdAt, type: 'task/created', data: { taskId: id } }),
    )
    await atomicWriteJson(join(tempDir, 'state.json'), { ...files.state, eventSeq: 1 })
    await ensureDir(tasksDir)
    // The destination does not exist yet (checked above), so rename is the
    // publish point: the task is either absent or complete on disk.
    await rename(tempDir, finalDir)
    const store = new TaskStore(finalDir, clock)
    store.lastSeq = 1
    const state = await store.readState()
    if (state.eventSeq !== 1) await store.writeState({ ...state, eventSeq: 1 })
    return store
  }

  static async open(taskDir: string, clock: Clock = () => new Date()): Promise<TaskStore> {
    if (!existsSync(join(taskDir, 'state.json'))) {
      throw new OrbitError('not_found', `not a task directory: ${taskDir}`)
    }
    const store = new TaskStore(taskDir, clock)
    const events = await store.events()
    store.lastSeq = events.length === 0 ? 0 : (events.at(-1)?.seq ?? 0)
    return store
  }

  now(): string {
    return this.clock().toISOString()
  }

  path(name: string): string {
    return join(this.dir, name)
  }

  async readState(): Promise<TaskState> {
    return readJsonFile<TaskState>(this.path('state.json'))
  }

  async writeState(state: TaskState): Promise<void> {
    await atomicWriteJson(this.path('state.json'), state)
  }

  async updateState(mutator: (state: TaskState) => void | TaskState): Promise<TaskState> {
    return this.mutex.run(async () => {
      const state = await this.readState()
      const draft = structuredClone(state)
      const next = mutator(draft) ?? draft
      next.updatedAt = this.now()
      await this.writeState(next)
      return next
    })
  }

  async members(): Promise<MembersFile> {
    return readJsonFile<MembersFile>(this.path('members.json'))
  }

  async updateMembers(mutator: (file: MembersFile) => void): Promise<MembersFile> {
    return this.mutex.run(async () => {
      const file = await this.members()
      mutator(file)
      await atomicWriteJson(this.path('members.json'), file)
      return file
    })
  }

  async workUnits(): Promise<WorkUnitsFile> {
    return readJsonFile<WorkUnitsFile>(this.path('work-units.json'))
  }

  async updateWorkUnits(mutator: (file: WorkUnitsFile) => void): Promise<WorkUnitsFile> {
    return this.mutex.run(async () => {
      const file = await this.workUnits()
      mutator(file)
      await atomicWriteJson(this.path('work-units.json'), file)
      return file
    })
  }

  async findings(): Promise<FindingsFile> {
    return readJsonFile<FindingsFile>(this.path('findings.json'))
  }

  async updateFindings(mutator: (file: FindingsFile) => void): Promise<FindingsFile> {
    return this.mutex.run(async () => {
      const file = await this.findings()
      mutator(file)
      await atomicWriteJson(this.path('findings.json'), file)
      return file
    })
  }

  async disputes(): Promise<DisputesFile> {
    return readJsonFile<DisputesFile>(this.path('disputes.json'))
  }

  async updateDisputes(mutator: (file: DisputesFile) => void): Promise<DisputesFile> {
    return this.mutex.run(async () => {
      const file = await this.disputes()
      mutator(file)
      await atomicWriteJson(this.path('disputes.json'), file)
      return file
    })
  }

  async coverage(): Promise<CoverageFile> {
    return readJsonFile<CoverageFile>(this.path('requirement-coverage.json'))
  }

  async updateCoverage(mutator: (file: CoverageFile) => void): Promise<CoverageFile> {
    return this.mutex.run(async () => {
      const file = await this.coverage()
      mutator(file)
      await atomicWriteJson(this.path('requirement-coverage.json'), file)
      return file
    })
  }

  /** Write one evidence artifact under the task directory (no traversal). */
  async writeArchive(relativePath: string, value: unknown): Promise<string> {
    if (relativePath.length === 0 || isAbsolute(relativePath) || relativePath.split('/').includes('..')) {
      throw new OrbitError('invalid_input', `archive path must stay inside the task: ${relativePath}`)
    }
    const target = join(this.dir, relativePath)
    await this.mutex.run(async () => {
      await atomicWriteJson(target, value)
    })
    return target
  }

  async readCheck(number: number): Promise<CheckRecord> {
    return readJsonFile<CheckRecord>(this.path(join('checks', `${number}.json`)))
  }

  async writeCheck(check: CheckRecord): Promise<void> {
    await this.mutex.run(async () => {
      await atomicWriteJson(this.path(join('checks', `${check.number}.json`)), check)
    })
  }

  async listChecks(): Promise<CheckRecord[]> {
    const dir = this.path('checks')
    if (!existsSync(dir)) return []
    const names = await readdir(dir)
    const numbers = names
      .filter((name) => /^\d+\.json$/.test(name))
      .map((name) => Number.parseInt(name, 10))
      .sort((a, b) => a - b)
    return Promise.all(numbers.map((number) => this.readCheck(number)))
  }

  async appendEvent(type: string, data?: unknown): Promise<TaskEvent> {
    return this.mutex.run(async () => {
      const seq = this.lastSeq + 1
      const event: TaskEvent = { seq, at: this.now(), type, ...(data === undefined ? {} : { data }) }
      await appendLineDurable(this.path('events.jsonl'), JSON.stringify(event))
      this.lastSeq = seq
      const state = await this.readState()
      if (state.eventSeq !== seq) {
        state.eventSeq = seq
        state.updatedAt = event.at
        await this.writeState(state)
      }
      return event
    })
  }

  async events(): Promise<TaskEvent[]> {
    const file = this.path('events.jsonl')
    if (!existsSync(file)) return []
    const text = await readFile(file, 'utf8')
    return text
      .split('\n')
      .filter((line) => line.trim().length > 0)
      .map((line) => {
        try {
          return JSON.parse(line) as TaskEvent
        } catch (error) {
          throw new OrbitError('io_error', `corrupt event log at ${file}: ${(error as Error).message}`)
        }
      })
  }
}
