import { ModuleKind, ScriptTarget, transpileModule } from "typescript";

import source from "../scripts/header.ts?raw";

export const GET = () =>
  new Response(
    transpileModule(source, {
      compilerOptions: {
        module: ModuleKind.ESNext,
        target: ScriptTarget.ES2022,
      },
    }).outputText,
    { headers: { "Content-Type": "text/javascript; charset=utf-8" } }
  );
