window.__ModuleLoader__.load({
	id: "@zeen/orbit",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		//#region src/client/index.ts
		const inject = ["slots", "uiConversation"];
		async function request(sessionId, init) {
			try {
				const response = await fetch(`/orbit/api?session=${encodeURIComponent(sessionId)}`, init);
				if (!response.ok) return void 0;
				return await response.json();
			} catch {
				return;
			}
		}
		function action(sessionId, body) {
			return request(sessionId, {
				method: "POST",
				headers: {
					"content-type": "application/json",
					"x-orbit-api": "1"
				},
				body: JSON.stringify({
					session: sessionId,
					...body
				})
			});
		}
		function OrbitPanel({ sessionId }) {
			const [data, setData] = (0, react.useState)(void 0);
			const [instruction, setInstruction] = (0, react.useState)("");
			(0, react.useEffect)(() => {
				let alive = true;
				const load = () => {
					request(sessionId).then((next) => {
						if (alive && next !== void 0) setData(next);
					});
				};
				load();
				const timer = setInterval(load, 2e3);
				return () => {
					alive = false;
					clearInterval(timer);
				};
			}, [sessionId]);
			if (data === void 0) return (0, react.createElement)("div", { style: {
				padding: "4px 12px",
				fontSize: 12,
				opacity: .65
			} }, "Orbit");
			const pending = data.pendingQuestions ?? [];
			const config = data.config;
			const events = (data.recentEvents ?? []).map((event) => event.type).join(", ") || "none";
			return (0, react.createElement)("div", { style: {
				display: "flex",
				flexDirection: "column",
				gap: 2,
				padding: "4px 12px",
				fontSize: 12
			} }, (0, react.createElement)("div", { style: {
				display: "flex",
				gap: 8,
				alignItems: "center"
			} }, (0, react.createElement)("strong", null, "Orbit"), (0, react.createElement)("span", null, `${data.taskId ?? ""} · ${data.status ?? "unknown"}${data.stopConfirmation?.confirmed ? " stopped" : ""} · checks ${data.checksInFlight ?? "none"} · findings ${data.openFindings?.length ?? 0} · questions ${pending.length}`), (0, react.createElement)("input", {
				value: instruction,
				placeholder: "task instruction",
				onChange: (event) => setInstruction(event.target.value),
				style: { width: 140 }
			}), (0, react.createElement)("button", { onClick: () => {
				if (instruction.trim().length > 0) action(sessionId, {
					action: "prompt",
					message: `Call the orbit tool with action=start and instruction=${JSON.stringify(instruction.trim())}. Then reply OK.`
				});
			} }, "Start"), (0, react.createElement)("button", { onClick: () => {
				action(sessionId, {
					action: "prompt",
					message: "Call the orbit tool with action=check now. Do not use other tools."
				});
			} }, "Check"), (0, react.createElement)("button", { onClick: () => {
				action(sessionId, {
					action: "prompt",
					message: "If the latest independent check says complete, call the orbit tool with action=complete now."
				});
			} }, "Complete"), (0, react.createElement)("button", { onClick: () => {
				action(sessionId, { action: "stop" });
			} }, "Stop"), pending[0] !== void 0 ? (0, react.createElement)("button", { onClick: () => {
				action(sessionId, {
					action: "answer",
					question: pending[0].id,
					selected: [],
					custom: "Continue."
				});
			} }, "Answer") : null), (0, react.createElement)("div", { style: { opacity: .65 } }, config === void 0 ? "config: unavailable" : `models ${config.allowedModels.join(", ") || "(pool)"} · checker ${config.checkerProvider || "(default)"}/${config.checkerModel || "(default)"} · JEV ${config.jev ? "on" : "off"}`), (0, react.createElement)("div", { style: { opacity: .65 } }, `events: ${events}`));
		}
		function apply(ctx) {
			ctx.slots.register({
				name: "conversation.input.dock",
				id: "orbit-panel"
			}, OrbitPanel);
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

//# sourceMappingURL=client.js.map