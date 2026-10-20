window.__ModuleLoader__.load({
  id: "@zeen/orbit",
  factory: (require) => {
    var module = { exports: {} };
    var exports = module.exports;
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.inject = void 0;
exports.apply = apply;
const { createElement, useEffect, useState } = require('react');
exports.inject = ['slots', 'uiConversation'];
async function request(sessionId, init) {
    try {
        const response = await fetch(`/orbit/api?session=${encodeURIComponent(sessionId)}`, init);
        if (!response.ok)
            return undefined;
        return (await response.json());
    }
    catch {
        return undefined;
    }
}
function action(sessionId, body) {
    return request(sessionId, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-orbit-api': '1' },
        body: JSON.stringify({ session: sessionId, ...body }),
    });
}
function OrbitPanel({ sessionId }) {
    const [data, setData] = useState(undefined);
    const [instruction, setInstruction] = useState('');
    const [showSettings, setShowSettings] = useState(false);
    const [allowedInput, setAllowedInput] = useState('');
    const [checkerInput, setCheckerInput] = useState('');
    const [jevInput, setJevInput] = useState('');
    useEffect(() => {
        let alive = true;
        const load = () => { void request(sessionId).then((next) => { if (alive && next !== undefined)
            setData(next); }); };
        load();
        const timer = setInterval(load, 2000);
        return () => { alive = false; clearInterval(timer); };
    }, [sessionId]);
    useEffect(() => {
        const config = data?.config;
        if (config === undefined)
            return;
        setAllowedInput(config.allowedModels.join(', '));
        setCheckerInput(config.checkerProvider.length > 0 ? `${config.checkerProvider}/${config.checkerModel}` : '');
        setJevInput(config.jevEndpoint ?? '');
    }, [data?.config]);
    if (data === undefined)
        return createElement('div', { style: { padding: '4px 12px', fontSize: 12, opacity: 0.65 } }, 'Orbit');
    const pending = data.pendingQuestions ?? [];
    const config = data.config;
    const events = (data.recentEvents ?? []).map((event) => event.type).join(', ') || 'none';
    return createElement('div', { style: { display: 'flex', flexDirection: 'column', gap: 2, padding: '4px 12px', fontSize: 12 } }, createElement('div', { style: { display: 'flex', gap: 8, alignItems: 'center' } }, createElement('strong', null, 'Orbit'), createElement('span', null, `${data.taskId ?? ''} · ${data.status ?? 'unknown'}${data.stopConfirmation?.confirmed ? ' stopped' : ''} · checks ${data.checksInFlight ?? 'none'} · findings ${data.openFindings?.length ?? 0} · questions ${pending.length}`), createElement('input', { value: instruction, placeholder: 'task instruction', onChange: (event) => setInstruction(event.target.value), style: { width: 140 } }), createElement('button', { onClick: () => { if (instruction.trim().length > 0)
            void action(sessionId, { action: 'prompt', message: `Call the orbit tool with action=start and instruction=${JSON.stringify(instruction.trim())}. Then reply OK.` }); } }, 'Start'), createElement('button', { onClick: () => { void action(sessionId, { action: 'prompt', message: 'Call the orbit tool with action=check now. Do not use other tools.' }); } }, 'Check'), createElement('button', { onClick: () => { void action(sessionId, { action: 'prompt', message: 'If the latest independent check says complete, call the orbit tool with action=complete now.' }); } }, 'Complete'), createElement('button', { onClick: () => setShowSettings((value) => !value) }, 'Settings'), createElement('button', { onClick: () => { void action(sessionId, { action: 'stop' }); } }, 'Stop'), pending[0] !== undefined ? createElement('button', {
        onClick: () => { void action(sessionId, { action: 'answer', question: pending[0].id, selected: [], custom: 'Continue.' }); },
    }, 'Answer') : null), createElement('div', { style: { opacity: 0.65 } }, config === undefined ? 'config: unavailable' : `models ${config.allowedModels.join(', ') || '(pool)'} · checker ${config.checkerProvider || '(default)'}/${config.checkerModel || '(default)'} · JEV ${config.jev ? 'on' : 'off'}`), createElement('div', { style: { opacity: 0.65 } }, `events: ${events}`), showSettings && config !== undefined
        ? createElement('div', { style: { opacity: 0.8 } }, createElement('div', null, createElement('label', null, 'allowed models '), createElement('input', { 'aria-label': 'Orbit allowed models', value: allowedInput, onChange: (event) => setAllowedInput(event.target.value), style: { width: 220 } })), createElement('div', null, createElement('label', null, 'checker provider/model '), createElement('input', { 'aria-label': 'Orbit checker route', value: checkerInput, onChange: (event) => setCheckerInput(event.target.value), style: { width: 200 } })), createElement('div', null, createElement('label', null, 'JEV endpoint '), createElement('input', { 'aria-label': 'Orbit JEV endpoint', value: jevInput, onChange: (event) => setJevInput(event.target.value), style: { width: 240 } })), createElement('button', {
            onClick: () => {
                const allowedModels = allowedInput.split(',').map((item) => item.trim()).filter((item) => item.length > 0);
                const [checkerProvider = '', checkerModel = ''] = checkerInput.trim().split('/');
                void action(sessionId, { action: 'settings', allowedModels, checkerProvider, checkerModel, jevEndpoint: jevInput.trim() });
            },
        }, 'Save'))
        : null);
}
function apply(ctx) {
    ctx.slots.register({ name: 'conversation.input.dock', id: 'orbit-panel' }, OrbitPanel);
}

    return module.exports;
  },
});
