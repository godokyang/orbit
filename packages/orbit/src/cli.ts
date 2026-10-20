#!/usr/bin/env node
import { runCli } from '@orbit/cli'

process.exitCode = await runCli(process.argv.slice(2))
