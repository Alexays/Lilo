import js from "@eslint/js";
import globals from "globals";
import svelte from "eslint-plugin-svelte";
import tseslint from "typescript-eslint";

export default tseslint.config(
	{
		ignores: [
			"dist/**",
			"node_modules/**",
		],
	},
	js.configs.recommended,
	...tseslint.configs.recommended,
	...svelte.configs["flat/recommended"],
	{
		files: ["**/*.{js,ts,svelte}"],
		languageOptions: {
			globals: {
				...globals.browser,
				...globals.node,
			},
			parserOptions: {
				extraFileExtensions: [".svelte"],
			},
		},
	},
	{
		files: ["**/*.svelte", "**/*.svelte.ts"],
		languageOptions: {
			parserOptions: {
				parser: tseslint.parser,
			},
		},
	},
	{
		files: ["**/*.{ts,svelte}"],
		rules: {
			"no-undef": "off",
		},
	},
	{
		// Store modules keep plain Maps and Sets on purpose: caches, and raw state replaced whole on each write.
		files: ["**/*.svelte.ts"],
		rules: {
			"svelte/prefer-svelte-reactivity": "off",
		},
	},
	{
		rules: {
			"@typescript-eslint/no-unused-vars": [
				"warn",
				{
					argsIgnorePattern: "^_",
					varsIgnorePattern: "^_",
				},
			],
			"no-console": [
				"warn",
				{
					allow: ["warn", "error"],
				},
			],
		},
	},
);
