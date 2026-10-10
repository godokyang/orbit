// OMP 18.8 task.tools names eval-kernel tools; native member permissions live
// in the durable work unit. Catch the observed builtin-as-eval mistake before
// child creation. Do not infer custom tool targets or enlarge their support.
const nativeTools = new Set(['read', 'write', 'edit', 'grep', 'glob', 'bash', 'hub', 'yield', 'task', 'eval']);

export function validateNativeTaskTools(input) {
  const items = Array.isArray(input?.tasks) && input.tasks.length ? input.tasks : [input];
  for (const item of items) {
    if (!Array.isArray(item?.tools)) continue;
    const mistaken = item.tools.filter(name => nativeTools.has(name));
    if (!mistaken.length) continue;
    return { block: true, reason: `Orbit native task preflight: task.tools mounts named eval-kernel tools, not native tool permissions (${mistaken.join(', ')}). Remove tools from this task call and use the native member tools already constrained by the durable work-unit allowed_tools/allowed_paths/allowed_commands. Retry the corrected native task call; do not switch to an unregistered eval agent or wrap native tools in custom eval tools.` };
  }
  return { ok: true };
}

// A nested operation was silently treated as the default declare, so a
// purported finish could create another unit and never accept its real result.
export function workUnitOperationError(args) {
  if (args?.action !== 'work-unit') return null;
  const unit = args.work_unit;
  if (unit?.operation === undefined && !((!args.operation || args.operation === 'declare') && unit?.id !== undefined)) return null;
  return 'Orbit work-unit operation belongs at the top level beside action/task, never inside work_unit. For finish use {action:"work-unit", operation:"finish", task:<task_directory>, work_unit:{id, status, result, verification}}; read also needs top-level operation:"read" and work_unit:{id}; declare uses work_unit:{spec:{...}}. Repair the call rather than supplying a new spec to a finish.';
}
