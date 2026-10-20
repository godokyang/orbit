window.__ModuleLoader__.load({
	id: "@zeen/orbit",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		//#region src/client/index.ts
		const inject = ["slots"];
		async function call(sessionId, init) {
			try {
				const response = await fetch(`/orbit/api?session=${encodeURIComponent(sessionId)}`, init);
				if (!response.ok) return void 0;
				return await response.json();
			} catch {
				return;
			}
		}
		function action(sessionId, body) {
			return call(sessionId, {
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
			(0, react.useEffect)(() => {
				let alive = true;
				const load = () => {
					call(sessionId).then((next) => {
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
				opacity: .6
			} }, "Orbit");
			const pending = data.pendingQuestions ?? [];
			const status = `${data.status ?? "unknown"}${data.stopConfirmation?.confirmed ? " (stopped)" : ""}`;
			return (0, react.createElement)("div", { style: {
				display: "flex",
				gap: 8,
				alignItems: "center",
				padding: "4px 12px",
				fontSize: 12
			} }, (0, react.createElement)("strong", null, "Orbit"), (0, react.createElement)("span", null, `${data.taskId ?? ""} · ${status} · checks ${data.checksInFlight ?? "none"} · findings ${data.openFindings?.length ?? 0} · questions ${pending.length}`), (0, react.createElement)("button", { onClick: () => {
				action(sessionId, { action: "stop" });
			} }, "Stop"), pending[0] !== void 0 ? (0, react.createElement)("button", { onClick: () => {
				action(sessionId, {
					action: "answer",
					question: pending[0].id,
					selected: [],
					custom: "Continue."
				});
			} }, "Answer") : null);
		}
		function apply(ctx) {
			ctx.slots.register({
				name: "conversation.input.dock",
				key: "orbit"
			}, OrbitPanel);
		}
		//#endregion
		exports.OrbitPanel = OrbitPanel;
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

//# sourceMappingURL=client.js.map