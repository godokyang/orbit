import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskService } from '../src/service.js'
import { isOrbitError } from '../src/errors.js'

const dirs: string[] = []
afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

async function service(): Promise<TaskService> {
  const projectRoot = await mkdtemp(join(tmpdir(), 'orbit-question-'))
  dirs.push(projectRoot)
  const started = await TaskService.start({ projectRoot, rootSessionId: 'root-1', instruction: 'work' })
  return started.service
}

describe('member questions', () => {
  it('records one pending question per member/external id and answers it', async () => {
    const task = await service()
    const first = await task.askQuestion({
      memberId: 'member-1',
      externalId: 'q1',
      question: 'Which option?',
      options: [{ label: 'alpha' }, { label: 'beta' }],
    })
    const duplicate = await task.askQuestion({ memberId: 'member-1', externalId: 'q1', question: 'Which option?' })
    expect(duplicate.id).toBe(first.id)
    expect(first.status).toBe('pending')

    const answered = await task.answerQuestion(first.id, { selected: ['beta'] })
    expect(answered).toMatchObject({ status: 'answered', answer: { selected: ['beta'] } })
    const status = await task.status()
    expect(status.questions.find((question) => question.id === first.id)?.status).toBe('answered')
  })

  it('rejects a label that was not offered', async () => {
    const task = await service()
    const question = await task.askQuestion({
      memberId: 'member-1',
      externalId: 'q1',
      question: 'Which option?',
      options: [{ label: 'alpha' }],
    })
    await expect(task.answerQuestion(question.id, { selected: ['gamma'] })).rejects.toSatisfy(
      (error) => isOrbitError(error) && error.code === 'invalid_input',
    )
  })

  it('cancels pending questions on demand', async () => {
    const task = await service()
    await task.askQuestion({ memberId: 'member-1', externalId: 'q1', question: 'one' })
    await task.askQuestion({ memberId: 'member-2', externalId: 'q2', question: 'two' })
    expect(await task.cancelPendingQuestions('member-1')).toBe(1)
    const status = await task.status()
    expect(status.questions.map((question) => question.status)).toEqual(['cancelled', 'pending'])
  })
})
