import { constants } from 'node:fs'
import { open, mkdir, readFile, rename, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { OrbitError } from './errors.js'

const FILE_MODE = 0o600
const DIR_MODE = 0o700

export async function ensureDir(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: DIR_MODE })
}

async function fsyncDir(path: string): Promise<void> {
  let handle
  try {
    handle = await open(path, constants.O_RDONLY)
    await handle.sync()
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code
    // Not every platform/filesystem permits fsync on a directory fd. The file
    // itself has already been fsynced; ignore only the known unsupported cases.
    if (code !== 'EINVAL' && code !== 'ENOTSUP' && code !== 'EISDIR' && code !== 'EBADF') throw error
  } finally {
    await handle?.close()
  }
}

/**
 * Write a file atomically: write + fsync a sibling temp file, rename it over
 * the destination, then fsync the directory. Readers see either the old or the
 * new complete file, never a partial write.
 */
export async function atomicWriteFile(path: string, data: string, mode = FILE_MODE): Promise<void> {
  const directory = dirname(path)
  await ensureDir(directory)
  const temp = join(directory, `.${randomUUID()}.tmp`)
  let handle
  try {
    handle = await open(temp, 'wx', mode)
    await handle.writeFile(data, 'utf8')
    await handle.sync()
  } finally {
    await handle?.close()
  }
  try {
    await rename(temp, path)
  } catch (error) {
    await rm(temp, { force: true })
    throw error
  }
  await fsyncDir(directory)
}

export async function atomicWriteJson(path: string, value: unknown, mode = FILE_MODE): Promise<void> {
  await atomicWriteFile(path, `${JSON.stringify(value, null, 2)}\n`, mode)
}

export async function appendLineDurable(path: string, line: string, mode = FILE_MODE): Promise<void> {
  await ensureDir(dirname(path))
  const handle = await open(path, 'a', mode)
  try {
    await handle.writeFile(`${line}\n`, 'utf8')
    await handle.sync()
  } finally {
    await handle.close()
  }
}

export async function readJsonFile<T>(path: string): Promise<T> {
  let text: string
  try {
    text = await readFile(path, 'utf8')
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      throw new OrbitError('not_found', `missing file: ${path}`)
    }
    throw new OrbitError('io_error', `cannot read ${path}: ${(error as Error).message}`)
  }
  try {
    return JSON.parse(text) as T
  } catch (error) {
    throw new OrbitError('io_error', `invalid JSON in ${path}: ${(error as Error).message}`)
  }
}
