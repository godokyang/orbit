import { readFileSync } from 'node:fs'
import { z } from 'zod'

/** Frozen task input for an unattended node. The host creates the Root itself. */
export const HeadlessSpecSchema = z.object({
  version: z.literal(1),
  action: z.enum(['start', 'resume']).default('start'),
  previousTask: z.string().min(1).optional(),
  instruction: z.string().min(1),
  project: z.string().min(1),
  externalRefs: z.array(z.string()).max(8).default([]),
  allowedModels: z.array(z.string()).default([]),
  model: z.object({ provider: z.string().min(1), model: z.string().min(1) }),
  policy: z.object({
    readRoots: z.array(z.string()).default([]),
    writePaths: z.array(z.string()).default([]),
    readLog: z.string().optional(),
    allowBash: z.boolean().default(false),
  }).optional(),
}).refine((spec) => spec.action !== 'resume' || spec.previousTask !== undefined, {
  message: 'resume requires previousTask',
})

export type HeadlessSpec = z.infer<typeof HeadlessSpecSchema>

export function readHeadlessSpec(path: string): HeadlessSpec {
  return HeadlessSpecSchema.parse(JSON.parse(readFileSync(path, 'utf8')))
}
