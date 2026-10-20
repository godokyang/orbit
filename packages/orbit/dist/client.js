window.__ModuleLoader__.load({
	id: "@zeen/orbit",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });
		let react = require("react");
		//#region src/client/index.ts
		const inject = ["slots"];
		function OrbitPanel() {
			return (0, react.createElement)("div", { style: {
				padding: "8px 12px",
				fontSize: 12
			} }, "Orbit · DSH panel");
		}
		function apply(ctx) {
			ctx.slots.register({
				name: "conversation.input.dock",
				key: "orbit"
			}, OrbitPanel);
		}
		//#endregion
		exports.apply = apply;
		exports.inject = inject;
		return module.exports;
	}
});

//# sourceMappingURL=client.js.map